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
        // Entra device objects are directory data, but only DevOps-Devices
        // holds Device.ReadWrite.All — the identity MI can read them and not
        // disable or delete them, so the whole /devices collection goes to the
        // devices identity. Nested paths like /users/{id}/registeredDevices are
        // unaffected; they match on their own prefix below.
        if lower.contains("/v1.0/devices") || lower.contains("/beta/devices") {
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

/// Runs each request *inside* an elevation session as `az rest …`, so the
/// domain identity's token stays in Azure and only the JSON result comes back.
///
/// The whole elevation protocol (container lifecycle, exec handshake, websocket)
/// is reimplemented natively in `ElevationSession` — FleetMate has no dependency
/// on the external `~/bin/aze` script.
public struct AzeGraphTransport: GraphTransport {
    private let router: GraphDomainRouter
    private let ttlHours: Int?
    private let session: ElevationSession

    public init(router: GraphDomainRouter = GraphDomainRouter(), ttlHours: Int? = nil) {
        self.router = router
        self.ttlHours = ttlHours
        self.session = ElevationSession()
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
        var parts = ["az", "rest", "--method", request.method.rawValue, "--uri", shellSingleQuote(request.url)]
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
        let (out, code) = try await session.exec(domain, command: command, ttlHours: ttlHours)
        if code == 0 { return Data(out.utf8) }
        throw AzeError(exitCode: code, message: out)
    }
}
