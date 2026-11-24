import Foundation

/// The folders whose agent sessions are FleetMate's, for the Detached
/// section: the repositories the Repos workspace shows, each with its
/// worktrees, and FleetMate's own agent workspace.
///
/// A session counts when it works in a repository's own folder or in one of
/// its worktrees (`.worktrees/<name>`, or Claude Code's
/// `.claude/worktrees/<name>`), not anywhere beneath it: a repository that
/// holds other projects in subfolders would otherwise claim every session
/// started in them. The agent workspace counts only exactly, as FleetMate's
/// own sessions start there and nothing else belongs to it.
public struct AgentLaneScope: Equatable, Sendable {
    /// Normalized repository folders.
    public private(set) var repositories: Set<String>
    /// Normalized folders that count only exactly.
    public private(set) var exact: Set<String>
    /// Normalized folders whose lanes run on another machine, by its name:
    /// a session there counts, and one on this side in the same folder does not.
    public private(set) var remote: [String: Set<String>] = [:]
    /// The same for folders that are not repositories: only the folder itself.
    public private(set) var remoteExact: [String: Set<String>] = [:]
    /// The machine lanes run on by default, so a session it reports counts
    /// the same as one with no host.
    public private(set) var hub: String?

    /// The folders under a repository whose children are its worktrees.
    public static let worktreeFolders = [".worktrees", ".claude/worktrees"]

    public init(repositories: some Sequence<String> = [String](), exact: some Sequence<String> = [String]()) {
        self.repositories = Set(repositories.map(Self.normalized).filter { !$0.isEmpty })
        self.exact = Set(exact.map(Self.normalized).filter { !$0.isEmpty })
    }

    /// The repositories the Repos workspace lists, from its sessions'
    /// folders, plus the agent workspace.
    public init(baseline: TerminalWorkspace?, workspaceRoot: String?) {
        let folders = (baseline?.sections ?? []).flatMap(\.sessions).compactMap(\.directory)
        self.init(repositories: folders, exact: workspaceRoot.map { [$0] } ?? [])
    }

    /// The folders the rendered registry gives the app, plus the agent
    /// workspace. Entries on another host count only for sessions there.
    public init(registry: AgentAppsRepoRegistry, hub: String?, workspaceRoot: String?) {
        let entries = registry.sections.flatMap(\.repos).filter(\.agents)
        func isLocal(_ repo: AgentAppsRepoRegistry.Repo) -> Bool {
            guard let host = repo.host else { return true }
            return hub.map { $0 == host } ?? (repo.kind != "folder")
        }
        // A repository counts with its worktrees; a plain folder (such as the
        // root that holds many repositories) counts only as itself, or it
        // would claim every session beneath it.
        func isFolder(_ repo: AgentAppsRepoRegistry.Repo) -> Bool { repo.kind == "folder" }
        let local = entries.filter(isLocal)
        self.init(repositories: local.filter { !isFolder($0) }.map(\.path),
                  exact: local.filter(isFolder).map(\.path) + (workspaceRoot.map { [$0] } ?? []))
        self.hub = hub
        for repo in entries where !isLocal(repo) {
            guard let host = repo.host else { continue }
            if isFolder(repo) {
                remoteExact[host, default: []].insert(Self.normalized(repo.path))
            } else {
                remote[host, default: []].insert(Self.normalized(repo.path))
            }
        }
    }

    public var isEmpty: Bool { repositories.isEmpty && exact.isEmpty && remote.isEmpty && remoteExact.isEmpty }

    /// Whether a session working in `directory` on `host` (nil for this
    /// side) is FleetMate's.
    public func contains(directory: String?, host: String?) -> Bool {
        if let host, host != hub {
            guard let directory, !directory.isEmpty else { return false }
            let path = Self.normalized(directory)
            if remoteExact[host]?.contains(path) == true { return true }
            guard let folders = remote[host] else { return false }
            return folders.contains(path) || folders.contains { Self.isWorktree(path, of: $0) }
        }
        return contains(directory: directory)
    }

    /// Whether a session working in `directory` is FleetMate's.
    public func contains(directory: String?) -> Bool {
        guard let directory, !directory.isEmpty else { return false }
        let path = Self.normalized(directory)
        if exact.contains(path) || repositories.contains(path) { return true }
        return repositories.contains { Self.isWorktree(path, of: $0) }
    }

    /// Whether `path` is a worktree of `repository`, or inside one.
    static func isWorktree(_ path: String, of repository: String) -> Bool {
        worktreeFolders.contains { folder in
            let parent = repository == "/" ? "/" + folder + "/" : repository + "/" + folder + "/"
            return path.hasPrefix(parent) && path.count > parent.count
        }
    }

    /// A folder as compared: `~` expanded, symlinks resolved, no trailing
    /// slash, in lower case as the default Mac volume compares names.
    public static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let url = URL(fileURLWithPath: TerminalWorkspaceStore.expand(trimmed)).standardizedFileURL.resolvingSymlinksInPath()
        var out = url.path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out.lowercased()
    }
}

/// Where the Claude lane wrapper records the background session behind each
/// lane: one file per lane, named after the lane's session name, holding the
/// session's id (often only its first eight characters). FleetMate reads it
/// so a row holds the session it attaches whatever that session is named.
public enum ClaudeLaneIDFile {
    /// The wrapper's state folder; `CLAUDE_LANE_STATE_DIR` overrides it.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let dir = environment["CLAUDE_LANE_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: TerminalWorkspaceStore.expand(dir), isDirectory: true)
        }
        return home.appendingPathComponent(".local/state/claude-lanes", isDirectory: true)
    }

    /// The file for a lane's session name, with every character outside
    /// `A-Za-z0-9._-` replaced by `_`, as the wrapper names it.
    public static func url(lane: String, in directory: URL) -> URL? {
        guard !lane.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let key = String(String.UnicodeScalarView(lane.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        guard key != ".", key != ".." else { return nil }
        return directory.appendingPathComponent(key)
    }
}
