import Foundation

/// FleetMate's own copy of a repository's main branch, kept apart from any
/// clone the person works in. Their checkout may be on a branch, behind, or
/// missing; this one is always the remote's `main` and nothing else — a
/// shallow clone that every sync resets to `origin/main` exactly.
public actor RepoMirror {
    public nonisolated let name: String
    public let remoteURL: String
    public let branch: String
    /// Only these folders are checked out, when given — the Handbook's pages
    /// without its site build, the hub's agents/ without the rest.
    public let paths: [String]
    public nonisolated let localURL: URL
    public private(set) var lastSynced: Date?
    public private(set) var lastError: String?

    public init(name: String, remoteURL: String, branch: String = "main", paths: [String] = [], root: URL? = nil) {
        self.name = name
        self.remoteURL = remoteURL
        self.branch = branch
        self.paths = paths
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate/mirrors", isDirectory: true)
        self.localURL = base.appendingPathComponent(name, isDirectory: true)
    }

    /// Whether a usable copy exists, synced or not.
    public var isCloned: Bool {
        FileManager.default.fileExists(atPath: localURL.appendingPathComponent(".git").path)
    }

    /// Bring the copy to the remote's latest `main`. A token, when given, is
    /// sent as a request header for this call only. Returns the commit now checked out.
    @discardableResult
    public func sync(bearerToken: String?) async throws -> String {
        let auth: [String] = []
        // Never prompt: a GUI app has no terminal to answer on.
        var env = ProcessInfo.processInfo.environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"]) { _, new in new }
        // The token rides in git's environment config for this call only:
        // not on the command line, where `ps` would show it, and never in
        // the repository's config file.
        if let bearerToken, !bearerToken.isEmpty {
            env["GIT_CONFIG_COUNT"] = "2"
            env["GIT_CONFIG_KEY_0"] = "http.extraHeader"
            env["GIT_CONFIG_VALUE_0"] = "Authorization: Bearer \(bearerToken)"
            // The token is the sign-in; keep credential helpers out of it.
            env["GIT_CONFIG_KEY_1"] = "credential.helper"
            env["GIT_CONFIG_VALUE_1"] = ""
        }

        if !isCloned {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: localURL)
            let sparse = paths.isEmpty ? [] : ["--filter=blob:none", "--sparse"]
            try await git(auth + ["clone", "--depth", "1", "--single-branch", "--branch", branch] + sparse
                          + [remoteURL, localURL.path], in: nil, env: env)
            if !paths.isEmpty {
                try await git(["sparse-checkout", "set"] + paths, in: localURL, env: env)
            }
        } else {
            try await git(auth + ["fetch", "--depth", "1", "origin", branch], in: localURL, env: env)
            try await git(["reset", "--hard", "FETCH_HEAD"], in: localURL, env: env)
            try await git(["clean", "-fdx"], in: localURL, env: env)
        }
        let head = try await git(["rev-parse", "--short", "HEAD"], in: localURL, env: env)
        lastSynced = Date()
        lastError = nil
        return head
    }

    public func recordFailure(_ message: String) { lastError = message }

    @discardableResult
    private func git(_ args: [String], in dir: URL?, env: [String: String]) async throws -> String {
        var full = args
        if let dir { full = ["-C", dir.path] + args }
        let result = await ProcessRunner.run("/usr/bin/git", full, environment: env)
        guard result.exitCode == 0 else {
            // Never echo the arguments: they can carry the token.
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"Bearer [^\s"']+"#, with: "Bearer ***", options: .regularExpression)
            throw RepoMirrorError.gitFailed(command: args.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? "git",
                                            reason: reason)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RepoMirrorError: Error, LocalizedError {
    case gitFailed(command: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .gitFailed(let command, let reason): return "git \(command) failed: \(reason)"
        }
    }
}
