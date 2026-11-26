import Foundation

/// Where a lane has to run. A repository the registry gives another host
/// belongs to that machine: its lanes start, resume and attach there, through
/// the remote lane wrappers, and never as a local agent on this Mac.
public enum LaneHostRouting {
    /// The machine to run a lane in `directory` on.
    public struct Route: Equatable, Sendable {
        /// The host's name, as `hosts.conf` lists it.
        public var host: String
        /// Whether it is the hub, which the wrappers use when a lane names no host.
        public var isHub: Bool

        /// What a lane records as its host: nothing for the hub.
        public var laneHost: String? { isHub ? nil : host }
    }

    /// The host `directory` runs on when it is not this Mac, or nil when it
    /// runs here, no registry names it, or its host is not one lanes can be
    /// sent to (not in `hosts.conf`, or a client). Every name comes from the
    /// registry and `hosts.conf`; none is built in.
    public static func route(directory: String, registry: AgentAppsRepoRegistry?, selfName: String,
                             hub: String?, laneHosts: Set<String>) -> Route? {
        guard let host = registry?.host(forDirectory: directory), host != selfName, laneHosts.contains(host) else { return nil }
        return Route(host: host, isHub: host == hub)
    }

    /// The remote wrapper for an agent command, which attaches or starts the
    /// lane on its host: `claude` becomes `claude-remote`, `codex`
    /// `codex-remote`, any arguments dropped as the wrapper takes the folder.
    /// A wrapper stays as it is. A shell or another program has none (nil).
    public static func remoteCommand(for command: String) -> String? {
        let program = command.split(separator: " ").first.map { (String($0) as NSString).lastPathComponent } ?? ""
        switch program {
        case "claude", "claude-remote": return "claude-remote"
        case "codex", "codex-remote": return "codex-remote"
        default: return nil
        }
    }
}

extension AgentAppsRepoRegistry {
    /// The host the lanes in `directory` run on: that of the listed
    /// repository it is, or a worktree of, the most specific match winning.
    /// Nil for a folder the file does not list, or one listed with no host.
    /// A plain folder (kind `folder`) matches only itself.
    public func host(forDirectory directory: String) -> String? {
        let folder = AgentLaneScope.normalized(directory)
        guard !folder.isEmpty else { return nil }
        var best: (length: Int, host: String?)?
        for repo in sections.flatMap(\.repos) {
            let root = AgentLaneScope.normalized(repo.path)
            guard !root.isEmpty else { continue }
            let matches = folder == root || (repo.kind != "folder" && AgentLaneScope.isWorktree(folder, of: root))
            if matches, root.count >= (best?.length ?? -1) { best = (root.count, repo.host) }
        }
        return best?.host
    }
}
