import Foundation

/// Elevation domain that an `aze` session maps to. Each domain is backed by a
/// distinct managed identity inside an ephemeral Azure Container Instance, so a
/// Graph/ARM call routed to it runs with that identity's permissions and the
/// token never leaves Azure.
public enum GraphDomain: String, Sendable {
    case devices
    case identity
    case systems
    case terraform
    case cloud
}

/// A single Microsoft Graph (or ARM) request, transport-agnostic.
public struct GraphRequest: Sendable {
    public enum Method: String, Sendable {
        case get, post, patch, delete, put
    }

    public let method: Method
    public let url: String
    /// Raw JSON request body, if any.
    public let body: Data?

    public init(method: Method, url: String, body: Data? = nil) {
        self.method = method
        self.url = url
        self.body = body
    }
}

/// Performs a Graph/ARM request and returns the raw JSON response body.
/// Implementations decide *how* the request authenticates and travels.
public protocol GraphTransport: Sendable {
    func send(_ request: GraphRequest) async throws -> Data
}

/// Maps a Graph/ARM URL to the elevation domain whose identity should run it.
public struct GraphDomainRouter: Sendable {
    public init() {}

    public func domain(for url: String) -> GraphDomain {
        let lower = url.lowercased()
        // Intune lives under deviceManagement / deviceAppManagement → DevOps-Devices.
        if lower.contains("/devicemanagement/") || lower.contains("/deviceappmanagement/") {
            return .devices
        }
        // Everything else we touch today (users, groups, directory devices,
        // memberOf) is directory data → DevOps-Identity.
        return .identity
    }
}

/// Error surfaced when an `aze` invocation fails. `exitCode` follows the aze
/// contract: 1 = precondition (not logged in / unknown domain), 125 = session
/// dropped before output markers, otherwise the inner command's exit code.
public struct AzeError: Error, Sendable, CustomStringConvertible {
    public let exitCode: Int32
    public let message: String

    public var description: String {
        "aze failed (exit \(exitCode)): \(message)"
    }

    /// A fresh or recycled session's entrypoint `az login --identity` does not
    /// always persist into the `aze run` exec shell — `az rest` then reports
    /// "Please run 'az login'". Detect that so we can log in and retry.
    var needsLogin: Bool {
        let lower = message.lowercased()
        return lower.contains("az login") || lower.contains("setup account")
    }
}

/// Runs each request *inside* an `aze` session as `az rest …`, so the domain
/// identity's token stays in Azure and only the JSON result comes back.
public struct AzeGraphTransport: GraphTransport {
    private let azePath: String
    private let router: GraphDomainRouter
    private let ttlHours: Int?

    public init(azePath: String? = nil, router: GraphDomainRouter = GraphDomainRouter(), ttlHours: Int? = nil) {
        self.azePath = azePath ?? AzeGraphTransport.locateAze()
        self.router = router
        self.ttlHours = ttlHours
    }

    /// Find `aze` on common install paths; fall back to PATH lookup via env.
    static func locateAze() -> String {
        let candidates = [
            "\(NSHomeDirectory())/bin/aze",
            "/usr/local/bin/aze",
            "/opt/homebrew/bin/aze",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "aze"
    }

    /// Logs the session's `az` in as its attached managed identity. Idempotent
    /// and cheap once the container is warm.
    static let loginCommand = "az login --identity --allow-no-subscriptions -o none"

    /// Pre-create and log in a domain's session so the ~30s container cold start
    /// is paid up front (e.g. at app launch) instead of on the first user action.
    /// Best-effort: a failure here just means the first real call pays the cost.
    @discardableResult
    public func warm(_ domain: GraphDomain) async -> Bool {
        do {
            _ = try await execute(domain: domain, command: AzeGraphTransport.loginCommand)
            return true
        } catch {
            return false
        }
    }

    public func send(_ request: GraphRequest) async throws -> Data {
        let domain = router.domain(for: request.url)
        let command = AzeGraphTransport.buildAzRestCommand(request)
        do {
            return try await execute(domain: domain, command: command)
        } catch let error as AzeError {
            if error.exitCode == 125 {
                // Session dropped mid-command — re-attach and try once more.
                return try await execute(domain: domain, command: command)
            }
            if error.needsLogin {
                // Warm the identity login in this session, then retry once.
                _ = try? await execute(domain: domain, command: AzeGraphTransport.loginCommand)
                return try await execute(domain: domain, command: command)
            }
            throw error
        }
    }

    /// Build the single-line `az rest` command. URL and body are single-quoted
    /// so the container shell does not expand `$top`, `$filter`, `$skiptoken`,
    /// `$ref`, etc.
    static func buildAzRestCommand(_ request: GraphRequest) -> String {
        var parts = ["az", "rest", "--method", request.method.rawValue, "--url", shellSingleQuote(request.url)]
        if let body = request.body, let json = String(data: body, encoding: .utf8) {
            parts += ["--headers", "Content-Type=application/json", "--body", shellSingleQuote(json)]
        }
        parts += ["-o", "json"]
        return parts.joined(separator: " ")
    }

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func execute(domain: GraphDomain, command: String) async throws -> Data {
        let azePath = self.azePath
        let ttlHours = self.ttlHours
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var azeArgs = ["run", domain.rawValue]
                if let ttl = ttlHours { azeArgs += ["--ttl", String(ttl)] }
                azeArgs += ["--", command]

                let process = Process()
                if azePath == "aze" {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["aze"] + azeArgs
                } else {
                    process.executableURL = URL(fileURLWithPath: azePath)
                    process.arguments = azeArgs
                }

                // A GUI-launched process inherits a thin environment; make sure
                // az / brew-python / aze are reachable.
                var env = ProcessInfo.processInfo.environment
                let extraPaths = ["\(NSHomeDirectory())/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = (extraPaths + (existingPath.isEmpty ? [] : [existingPath])).joined(separator: ":")
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AzeError(exitCode: -1, message: "could not launch aze: \(error.localizedDescription)"))
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if ProcessInfo.processInfo.environment["FLEETMATE_AZE_DEBUG"] != nil {
                    // Sizes + exit only — never the response body (may hold PII).
                    let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let dbg = "[aze-debug] aze run \(domain.rawValue) exit=\(process.terminationStatus) outBytes=\(outData.count) errBytes=\(errData.count) err=\(errText)\n"
                    FileHandle.standardError.write(Data(dbg.utf8))
                }

                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    // The inner command's real error lands on stdout (aze prints
                    // the session output there); stderr is aze's own chatter
                    // ("Re-attaching…"). Prefer stdout, keep stderr as context.
                    let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = [outText, errText].filter { !$0.isEmpty }.joined(separator: " | ")
                    continuation.resume(throwing: AzeError(exitCode: process.terminationStatus, message: message))
                }
            }
        }
    }
}
