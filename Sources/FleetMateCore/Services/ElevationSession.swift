import Foundation
import CryptoKit

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
    ///
    /// The exec container cannot service concurrent commands: every exec opens a
    /// pseudo-terminal on the same session, and two commands running at once
    /// interleave their output on that shared stream, corrupting both payloads
    /// (an `az rest` JSON response comes back spliced with another command's
    /// bytes and fails to decode). Callers legitimately fan out — the app fires
    /// several Graph/Intune fetches at launch — so we serialize per domain
    /// through a process-wide gate. Different domains hit different containers
    /// and still run concurrently.
    public func exec(_ domain: GraphDomain, command: String, ttlHours: Int? = nil) async throws -> (out: String, code: Int32) {
        await ElevationSessionGate.shared.acquire(domain)
        do {
            let result = try await runExec(domain, command: command, ttlHours: ttlHours)
            await ElevationSessionGate.shared.release(domain)
            return result
        } catch {
            await ElevationSessionGate.shared.release(domain)
            throw error
        }
    }

    /// The ACI exec pty→websocket bridge drops bytes intermittently under load,
    /// so a captured payload can arrive short even with no concurrency (a single
    /// large `az rest` page fails this way ~100% of the time; even a 20 KB
    /// payload fails a fraction of runs). Every exec therefore carries an
    /// in-container checksum of its true stdout, computed before the bytes hit
    /// the pty; the client verifies what it received and re-runs on any
    /// mismatch. Small results (login probes, single-device lookups) usually
    /// pass first try; large ones may take a couple of attempts.
    static let maxExecAttempts = 6

    private func runExec(_ domain: GraphDomain, command: String, ttlHours: Int? = nil) async throws -> (out: String, code: Int32) {
        try await ensureSession(domain, ttlHours: ttlHours ?? ElevationSession.defaultTtlHours)
        let name = ElevationSession.sessionName(for: domain)

        let account = try await runAz(["account", "show", "--query", "id", "-o", "tsv"])
        let sub = account.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.code == 0, !sub.isEmpty else {
            throw ElevationError.execHandshakeFailed("Not logged in to az (run az login). \(account.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let uri = "https://management.azure.com/subscriptions/\(sub)/resourceGroups/\(ElevationSession.sessionsResourceGroup)/providers/Microsoft.ContainerInstance/containerGroups/\(name)/containers/\(name)/exec?api-version=\(ElevationSession.execApiVersion)"
        let body = "{\"command\":\"/bin/bash\",\"terminalSize\":{\"rows\":24,\"cols\":500}}"

        var lastError: Error = ElevationError.execHandshakeFailed("no exec attempts were made")
        for _ in 0..<ElevationSession.maxExecAttempts {
            do {
                // Each attempt needs a fresh exec websocket.
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
            } catch let error as ElevationError where error.isCaptureFailure {
                lastError = error // pty mangled the stream — re-run the exec
            }
        }
        throw lastError
    }

    private func runWebSocket(url: URL, password: String, command: String) async throws -> (out: String, code: Int32) {
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        try await ws.send(.string(password))
        try await ws.send(.string("stty -echo\n"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        try await ws.send(.string(ElevationSession.wrap(command)))

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
            // The END marker is short and last; a cheap substring check avoids
            // re-stripping the whole (potentially 100s of KB) buffer each frame.
            if raw.range(of: "<<<AZE_END:") != nil {
                let stripped = ElevationSession.stripAnsi(raw)
                if ElevationSession.endMarker.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
                    break
                }
            }
        }

        let text = ElevationSession.stripAnsi(raw).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let parsed = ElevationSession.parseMarkers(text) else {
            throw ElevationError.noOutputMarkers(text)
        }
        // Verify the payload survived the pty intact: compare the length and MD5
        // the container computed on the true stdout against what we received.
        let bytes = Data(parsed.out.utf8)
        let digest = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == parsed.expectedLen, digest == parsed.expectedMd5 else {
            throw ElevationError.corruptedOutput(expected: parsed.expectedLen, actual: bytes.count)
        }
        return (parsed.out, parsed.code)
    }

    // MARK: - Helpers

    static let endMarker = try! NSRegularExpression(pattern: "<<<AZE_END:[0-9]+:[0-9]+:[0-9a-f]+>>>")

    /// Wrap a command so the container reports its stdout together with the exact
    /// byte length and MD5 of that stdout, computed *before* the bytes traverse
    /// the lossy exec pty. Those let the client detect a mangled payload and
    /// re-run. stderr is captured to a temp file and folded into the output only
    /// on failure, so a normal payload stays clean (and stray warnings no longer
    /// interleave with the JSON we care about). `md5sum`, `wc`, `printf`, and
    /// `cat` are all coreutils present in the elevation image.
    static func wrap(_ command: String) -> String {
        "__o=$( ( \(command) ) 2>/tmp/aze_err ); __c=$?; "
            + "if [ \"$__c\" -ne 0 ]; then __o=\"$__o$(cat /tmp/aze_err 2>/dev/null)\"; fi; "
            + "__n=$(printf %s \"$__o\" | wc -c | tr -d ' '); "
            + "__m=$(printf %s \"$__o\" | md5sum | cut -d' ' -f1); "
            + "printf '\\n<<<AZE_BEGIN>>>\\n%s\\n<<<AZE_END:%s:%s:%s>>>\\n' \"$__o\" \"$__c\" \"$__n\" \"$__m\"; exit\n"
    }

    static func stripAnsi(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;?]*[a-zA-Z]") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// Extract the command output between the BEGIN/END sentinels, the exit code,
    /// and the integrity trailer (expected byte length + MD5) the container
    /// stamped on the true stdout. The output is returned verbatim — no trimming
    /// — so the client's checksum is taken over exactly the printed bytes.
    static func parseMarkers(_ text: String) -> (out: String, code: Int32, expectedLen: Int, expectedMd5: String)? {
        guard let re = try? NSRegularExpression(pattern: "<<<AZE_BEGIN>>>\\n(.*)\\n<<<AZE_END:(\\d+):(\\d+):([0-9a-f]+)>>>", options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let outRange = Range(m.range(at: 1), in: text),
              let codeRange = Range(m.range(at: 2), in: text),
              let lenRange = Range(m.range(at: 3), in: text),
              let md5Range = Range(m.range(at: 4), in: text) else { return nil }
        let out = String(text[outRange])
        let code = Int32(text[codeRange]) ?? 0
        let len = Int(text[lenRange]) ?? -1
        let md5 = String(text[md5Range])
        return (out, code, len, md5)
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

/// Process-wide, per-domain serialization for elevation exec calls.
///
/// The elevation session container multiplexes every exec onto one pseudo-
/// terminal, so concurrent commands against the same domain corrupt each
/// other's output. A single `ElevationSession` actor is not enough to prevent
/// this — the app builds several `ElevationSession` instances (each
/// `GraphService` owns its own transport), and they all target the same shared
/// containers. This gate lives above every instance so one command runs per
/// domain at a time across the whole process. It is a fair FIFO semaphore:
/// ownership passes directly to the next waiter on release, so a domain never
/// goes idle while callers are queued.
actor ElevationSessionGate {
    static let shared = ElevationSessionGate()

    private var busy: Set<GraphDomain> = []
    private var waiters: [GraphDomain: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ domain: GraphDomain) async {
        if !busy.contains(domain) {
            busy.insert(domain)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[domain, default: []].append(continuation)
        }
    }

    func release(_ domain: GraphDomain) {
        if var queue = waiters[domain], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[domain] = queue.isEmpty ? nil : queue
            next.resume() // stays busy; ownership handed to the next waiter
        } else {
            busy.remove(domain)
        }
    }
}

public enum ElevationError: Error, CustomStringConvertible {
    case identityResolutionFailed(GraphDomain)
    case createFailed(String)
    case execHandshakeFailed(String)
    case noOutputMarkers(String)
    case corruptedOutput(expected: Int, actual: Int)
    case azLaunchFailed(String)

    /// A capture that the pty mangled — worth re-running the exec. Handshake and
    /// identity failures are not retriable here; they surface to the caller.
    var isCaptureFailure: Bool {
        switch self {
        case .noOutputMarkers, .corruptedOutput: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .identityResolutionFailed(let d): return "Could not resolve managed identity for domain \(d.rawValue)"
        case .createFailed(let m): return "Failed to create elevation session: \(m)"
        case .execHandshakeFailed(let m): return "Exec handshake failed: \(m)"
        case .noOutputMarkers(let t): return "Could not find output markers in session output:\n\(t)"
        case .corruptedOutput(let expected, let actual): return "Elevation output truncated by the exec bridge (expected \(expected) bytes, got \(actual))"
        case .azLaunchFailed(let m): return "Could not launch az: \(m)"
        }
    }
}
