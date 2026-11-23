import Foundation

/// Merges the Agent's repository list (Settings › Repositories › Agent Folders) with
/// the checkouts tracked in Settings › Repositories. Nothing is removed: the
/// Agent's own entries keep their order, clone URLs included, and each tracked
/// checkout not yet listed is added after them, written with `~`.
public enum AgentRepoList {
    public static func merged(agent: [String], tracked: [String], home: String = NSHomeDirectory()) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for entry in agent + tracked.map({ tilde($0, home: home) }) {
            let key = entry.contains("://") ? entry : normalized(entry, home: home)
            if seen.insert(key).inserted { result.append(entry) }
        }
        return result
    }

    /// The Agent's entries that are folders on this Mac, expanded, for linking
    /// into the repository registry. Clone URLs are left out.
    public static func localPaths(_ agent: [String], home: String = NSHomeDirectory()) -> [String] {
        agent.filter { !$0.contains("://") }.map { normalized($0, home: home) }
    }

    public static func normalized(_ path: String, home: String = NSHomeDirectory()) -> String {
        let expanded = TerminalWorkspaceStore.expand(path, home: home)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func tilde(_ path: String, home: String) -> String {
        let path = normalized(path, home: home)
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
