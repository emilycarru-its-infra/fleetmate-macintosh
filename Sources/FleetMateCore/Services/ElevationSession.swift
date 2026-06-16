import Foundation

/// Native reimplementation of the `aze` elevation protocol, so FleetMate has no
/// dependency on the external `~/bin/aze` script. The container lifecycle and
/// the exec handshake go through the `az` CLI (which we deliberately keep); only
/// the raw exec websocket is driven natively here.
///
/// Security model is unchanged: this rides the operator's own `az login` on a
/// compliant device and their elevation operators-group membership. The app is
/// not a privilege — an unauthorized caller's `az` calls simply fail.
public actor ElevationSession {
    // Constants mirrored from the aze script.
    static let sessionsResourceGroup = "Entra"
    static let identityResourceGroup = "Entra"
    static let image = "elevationregistryecu.azurecr.io/elevation-session:latest"
    static let transcriptAccount = "elevationtranscripts"
    public static let defaultTtlHours = 8
    static let execApiVersion = "2023-05-01"

    private let azPath: String

    public init(azPath: String? = nil) {
        self.azPath = azPath ?? ElevationSession.locateAz()
    }

    static func locateAz() -> String {
        for candidate in ["/opt/homebrew/bin/az", "/usr/local/bin/az"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "az"
    }

    static func identityName(for domain: GraphDomain) -> String {
        switch domain {
        case .terraform: return "DevOps-Terraform"
        case .devices: return "DevOps-Devices"
        case .identity: return "DevOps-Identity"
        case .systems: return "DevOps-Systems"
        case .cloud: return "DevOps-Cloud"
        }
    }

    static func sessionName(for domain: GraphDomain) -> String {
        let user = String(NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }.prefix(20))
        return "aze-\(domain.rawValue)-\(user)"
    }

    // MARK: - Container lifecycle (via az)

    /// Ensure a running session container for the domain, creating it (cold
    /// start, ~30s) if absent.
    public func ensureSession(_ domain: GraphDomain, ttlHours: Int = ElevationSession.defaultTtlHours) async throws {
        let name = ElevationSession.sessionName(for: domain)

        let show = try await runAz(["container", "show", "--resource-group", ElevationSession.sessionsResourceGroup, "--name", name, "--query", "instanceView.state", "-o", "tsv"])
        let state = show.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "Running" { return }

        if !state.isEmpty {
            _ = try await runAz(["container", "delete", "--resource-group", ElevationSession.sessionsResourceGroup, "--name", name, "--yes", "-o", "none"])
        }

        // Resolve the user-assigned identity id + clientId in one round-trip.
        let idShow = try await runAz(["identity", "show", "--resource-group", ElevationSession.identityResourceGroup, "--name", ElevationSession.identityName(for: domain), "--query", "[id,clientId]", "-o", "tsv"])
        let parts = idShow.out.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).map(String.init)
        guard parts.count >= 2 else { throw ElevationError.identityResolutionFailed(domain) }
        let identityId = parts[0], clientId = parts[1]

        let sleepSeconds = ttlHours * 3600
        let commandLine = "/bin/bash -c 'az login --identity --client-id \(clientId) --allow-no-subscriptions -o none; sleep \(sleepSeconds)'"

        let create = try await runAz([
            "container", "create",
            "--resource-group", ElevationSession.sessionsResourceGroup,
            "--name", name,
            "--image", ElevationSession.image,
            "--assign-identity", identityId,
            "--acr-identity", identityId,
            "--os-type", "Linux",
            "--cpu", "1",
            "--memory", "1.5",
            "--restart-policy", "Never",
            "--command-line", commandLine,
            "--environment-variables", "ELEVATION_CLIENT_ID=\(clientId)", "ELEVATION_TRANSCRIPT_ACCOUNT=\(ElevationSession.transcriptAccount)",
            "--output", "none",
        ])
        guard create.code == 0 else { throw ElevationError.createFailed(create.err.isEmpty ? create.out : create.err) }

        // az container create has no --tags; tag in a follow-up call (best-effort).
        let idLookup = try? await runAz(["container", "show", "--resource-group", ElevationSession.sessionsResourceGroup, "--name", name, "--query", "id", "-o", "tsv"])
        if let containerId = idLookup?.out.trimmingCharacters(in: .whitespacesAndNewlines), !containerId.isEmpty {
            let expires = Int(Date().timeIntervalSince1970) + sleepSeconds
            _ = try? await runAz(["resource", "tag", "--ids", containerId, "--tags", "elevation=true", "domain=\(domain.rawValue)", "expires=\(expires)", "--output", "none"])
        }
    }

    // MARK: - Exec (handshake via az, raw websocket native)

    /// Run a single-line command inside the session and return its stdout +
    /// exit code, mirroring `aze run`.
    public func exec(_ domain: GraphDomain, command: String, ttlHours: Int? = nil) async throws -> (out: String, code: Int32) {
        try await ensureSession(domain, ttlHours: ttlHours ?? ElevationSession.defaultTtlHours)
        let name = ElevationSession.sessionName(for: domain)

        let account = try await runAz(["account", "show", "--query", "id", "-o", "tsv"])
        let sub = account.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.code == 0, !sub.isEmpty else {
            throw ElevationError.execHandshakeFailed("Not logged in to az (run az login). \(account.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let uri = "https://management.azure.com/subscriptions/\(sub)/resourceGroups/\(ElevationSession.sessionsResourceGroup)/providers/Microsoft.ContainerInstance/containerGroups/\(name)/containers/\(name)/exec?api-version=\(ElevationSession.execApiVersion)"
        let body = "{\"command\":\"/bin/bash\",\"terminalSize\":{\"rows\":24,\"cols\":500}}"

        let execResp = try await runAz(["rest", "--method", "post", "--uri", uri, "--body", body])
        guard execResp.code == 0,
              let data = execResp.out.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wsString = json["webSocketUri"] as? String,
              let wsURL = URL(string: wsString),
              let password = json["password"] as? String else {
            throw ElevationError.execHandshakeFailed(execResp.err.isEmpty ? execResp.out : execResp.err)
        }

        return try await runWebSocket(url: wsURL, password: password, command: command)
    }

    private func runWebSocket(url: URL, password: String, command: String) async throws -> (out: String, code: Int32) {
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        try await ws.send(.string(password))
        try await ws.send(.string("stty -echo\n"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        try await ws.send(.string("printf '\\n<<<AZE_BEGIN>>>\\n'; ( \(command) ); printf '\\n<<<AZE_END:%d>>>\\n' \"$?\"; exit\n"))

        let endMarker = try! NSRegularExpression(pattern: "<<<AZE_END:\\d+>>>")
        var raw = ""
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                break // closed or errored — fall through to parse what we have
            }
            switch message {
            case .string(let s): raw += s
            case .data(let d): raw += String(decoding: d, as: UTF8.self)
            @unknown default: break
            }
            let stripped = ElevationSession.stripAnsi(raw)
            if endMarker.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
                break
            }
        }

        let text = ElevationSession.stripAnsi(raw).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let parsed = ElevationSession.parseMarkers(text) else {
            throw ElevationError.noOutputMarkers(text)
        }
        return parsed
    }

    // MARK: - Helpers

    static func stripAnsi(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;?]*[a-zA-Z]") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// Extract the command output between the BEGIN/END sentinels and the exit code.
    static func parseMarkers(_ text: String) -> (out: String, code: Int32)? {
        guard let re = try? NSRegularExpression(pattern: "<<<AZE_BEGIN>>>\\n(.*)\\n?<<<AZE_END:(\\d+)>>>", options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let outRange = Range(m.range(at: 1), in: text),
              let codeRange = Range(m.range(at: 2), in: text) else { return nil }
        let out = String(text[outRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        let code = Int32(text[codeRange]) ?? 0
        return (out, code)
    }

    private func runAz(_ args: [String]) async throws -> (out: String, err: String, code: Int32) {
        let azPath = self.azPath
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String, Int32), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                if azPath == "az" {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["az"] + args
                } else {
                    process.executableURL = URL(fileURLWithPath: azPath)
                    process.arguments = args
                }
                var env = ProcessInfo.processInfo.environment
                let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                let existing = env["PATH"] ?? ""
                env["PATH"] = (extra + (existing.isEmpty ? [] : [existing])).joined(separator: ":")
                process.environment = env
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: ElevationError.azLaunchFailed(error.localizedDescription))
                    return
                }
                // Drain both pipes concurrently to avoid a deadlock when one
                // fills its buffer while we block reading the other.
                var errData = Data()
                let errGroup = DispatchGroup()
                errGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errGroup.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                errGroup.wait()
                process.waitUntilExit()
                cont.resume(returning: (
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    process.terminationStatus
                ))
            }
        }
    }
}

public enum ElevationError: Error, CustomStringConvertible {
    case identityResolutionFailed(GraphDomain)
    case createFailed(String)
    case execHandshakeFailed(String)
    case noOutputMarkers(String)
    case azLaunchFailed(String)

    public var description: String {
        switch self {
        case .identityResolutionFailed(let d): return "Could not resolve managed identity for domain \(d.rawValue)"
        case .createFailed(let m): return "Failed to create elevation session: \(m)"
        case .execHandshakeFailed(let m): return "Exec handshake failed: \(m)"
        case .noOutputMarkers(let t): return "Could not find output markers in session output:\n\(t)"
        case .azLaunchFailed(let m): return "Could not launch az: \(m)"
        }
    }
}
