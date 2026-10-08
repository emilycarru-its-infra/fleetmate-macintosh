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
/// (e.g. a staff account / ReportMate.Admin), which is exactly the local az
/// session's token.
///
/// Each resource is fetched on its own: `az` runs off the actor, so a slow call
/// for one resource never holds up another, and every call gives up after
/// `timeout` instead of leaving its caller waiting on a stalled `az`.
public actor AzTokenSource {
    public static let shared = AzTokenSource()

    private var cache: [String: (token: String, expiry: Date)] = [:]
    /// One acquisition per resource at a time; concurrent callers share it.
    private var inFlight: [String: Task<String, Error>] = [:]
    private let azPath: String
    private let timeout: Duration
    private let runner: (@Sendable ([String]) async -> ProcessOutput)?

    public init(azPath: String? = nil) {
        self.init(azPath: azPath, timeout: .seconds(30), runner: nil)
    }

    /// `runner` stands in for `az` in tests.
    init(azPath: String? = nil, timeout: Duration, runner: (@Sendable ([String]) async -> ProcessOutput)?) {
        self.azPath = azPath ?? AzTokenSource.locateAz()
        self.timeout = timeout
        self.runner = runner
    }

    public func token(forResource resource: String) async throws -> String {
        try await token(key: resource, arguments: ["--resource", resource])
    }

    public func token(forScope scope: String) async throws -> String {
        try await token(key: scope, arguments: ["--scope", scope])
    }

    /// Drop cached tokens, so the next call asks `az` again.
    public func invalidate() {
        cache.removeAll()
    }

    private func token(key: String, arguments: [String]) async throws -> String {
        if let c = cache[key], Date() < c.expiry { return c.token }
        if let running = inFlight[key] { return try await running.value }

        let args = ["account", "get-access-token"] + arguments + ["--query", "accessToken", "-o", "tsv"]
        let run = runner ?? { [azPath] args in await ProcessRunner.run(azPath, args) }
        let limit = timeout
        let task = Task { try await AzTokenSource.acquire(key, args: args, run: run, timeout: limit) }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let token = try await task.value
        // az tokens live ~60-75 min; refresh a little early.
        cache[key] = (token, Date().addingTimeInterval(50 * 60))
        return token
    }

    private static func acquire(
        _ key: String,
        args: [String],
        run: @escaping @Sendable ([String]) async -> ProcessOutput,
        timeout: Duration
    ) async throws -> String {
        guard let r = await FirstOf.value(within: timeout, { await run(args) }) else {
            throw AzTokenError.acquisitionFailed(key, "az did not answer within \(timeout.components.seconds) seconds")
        }
        guard r.exitCode == 0 else {
            throw AzTokenError.acquisitionFailed(key, (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let token = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AzTokenError.acquisitionFailed(key, "az returned an empty token") }
        return token
    }

    static func locateAz() -> String {
        for c in ["/opt/homebrew/bin/az", "/usr/local/bin/az"] where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "az"
    }
}

/// The result of `operation`, or nil once `timeout` passes. The operation is
/// not cancelled (a child process cannot be), but the caller stops waiting.
enum FirstOf {
    static func value<T: Sendable>(within timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let gate = Gate<T>()
        return await withCheckedContinuation { continuation in
            gate.continuation = continuation
            Task { gate.resume(await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(nil)
            }
        }
    }

    /// Resumes its continuation exactly once, whichever side finishes first.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<T?, Never>?

        func resume(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
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
