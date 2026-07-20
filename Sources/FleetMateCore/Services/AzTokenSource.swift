import Foundation

/// Mints short-lived Entra access tokens for a target API audience off the
/// operator's own `az` session — the same trust anchor `fleetmate login`
/// establishes. This is the SSO/az model applied to arbitrary resource APIs
/// (ReportMate, Snipe-IT, …): the token is the operator's delegated identity,
/// validated and role-authorized by the API server-side, so no shared secret
/// ever leaves this machine.
///
/// NOTE: this is a *local* `az account get-access-token` — deliberately NOT the
/// `ElevationSession` container path. ElevationSession runs as a domain managed
/// identity (for privileged Graph/Intune elevation); resource tokens for
/// ReportMate/Snipe must carry the *operator's* identity + role assignment
/// (e.g. rchristiansen / ReportMate.Admin), which is exactly the local az
/// session's token.
public actor AzTokenSource {
    public static let shared = AzTokenSource()

    private var cache: [String: (token: String, expiry: Date)] = [:]
    private let azPath: String

    public init(azPath: String? = nil) {
        self.azPath = azPath ?? AzTokenSource.locateAz()
    }

    /// A delegated access token for `resource` (an app/client id GUID or an
    /// `api://…` identifier URI). Cached until shortly before expiry.
    public func token(forResource resource: String) async throws -> String {
        if let c = cache[resource], Date() < c.expiry { return c.token }
        let r = run(["account", "get-access-token", "--resource", resource, "--query", "accessToken", "-o", "tsv"])
        guard r.code == 0 else {
            throw AzTokenError.acquisitionFailed(resource, (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let token = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AzTokenError.acquisitionFailed(resource, "az returned an empty token") }
        // az tokens live ~60-75 min; refresh a little early.
        cache[resource] = (token, Date().addingTimeInterval(50 * 60))
        return token
    }

    static func locateAz() -> String {
        for c in ["/opt/homebrew/bin/az", "/usr/local/bin/az"] where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "az"
    }

    private func run(_ args: [String]) -> (out: String, err: String, code: Int32) {
        let p = Process()
        if azPath == "az" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["az"] + args
        } else {
            p.executableURL = URL(fileURLWithPath: azPath)
            p.arguments = args
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + [env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ("", "could not launch az: \(error.localizedDescription)", -1) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self), p.terminationStatus)
    }
}

public enum AzTokenError: Error, CustomStringConvertible {
    case acquisitionFailed(String, String)
    public var description: String {
        switch self {
        case .acquisitionFailed(let resource, let msg):
            return "Could not acquire an Entra token for \(resource) — run `fleetmate login` (Azure sign-in required). \(msg)"
        }
    }
}
