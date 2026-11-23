import Foundation

/// Where FleetMate lets the New Sessions choice or the usage switch start an
/// agent other than its default: work folders only, because each agent's
/// account may see only work.
///
/// A folder is allowed when it is the work root (`~/Developer/AzDevOps`) or
/// inside it, or inside a repository the agent-apps registry offers to agent
/// sessions, and only when that registry is schema 1 and belongs to the work
/// zone. It is never allowed inside a denied folder: `~/Developer/Personal`
/// and any the `agentDeniedFolders` default lists on this Mac. Every path is
/// canonicalized (symlinks, `~`, `.` and `..` resolved) and compared by whole
/// path components, ignoring case as the default APFS volume does. A folder
/// that cannot be canonicalized is denied.
public enum AgentFolderPolicy {
    /// The registry's `app.zone` for work repositories.
    public static let workZone = "ecu"
    /// The user default listing more folders where no other agent may start.
    public static let deniedFoldersKey = "agentDeniedFolders"

    /// The running app's answer, with its registry and this Mac's denied folders.
    public static func allowsCurrent(_ folder: URL) -> Bool {
        allows(folder, registry: AgentAppsRepoRegistry.loadCurrent(),
               denied: UserDefaults.standard.stringArray(forKey: deniedFoldersKey) ?? [])
    }

    public static func allows(_ folder: URL, home: String = NSHomeDirectory(),
                              registry: AgentAppsRepoRegistry?, denied: [String]) -> Bool {
        guard let path = canonicalComponents(folder.path, home: home) else { return false }
        let deniedRoots = [home + "/Developer/Personal"] + denied
        for root in deniedRoots {
            // A denied root that does not exist still denies by its plain resolved path.
            let components = canonicalComponents(root, home: home) ?? resolvedComponents(root, home: home)
            if isInside(path, components) { return false }
        }
        var allowed = [home + "/Developer/AzDevOps"]
        if let registry, registry.zone == workZone { allowed += registry.agentPaths }
        return allowed.contains { root in
            canonicalComponents(root, home: home).map { isInside(path, $0) } ?? false
        }
    }

    static func isInside(_ path: [String], _ root: [String]) -> Bool {
        !root.isEmpty && path.count >= root.count && Array(path.prefix(root.count)) == root
    }

    /// The path's components, lower-cased, from the file system's canonical
    /// path; nil when the file system cannot give one (it does not exist).
    static func canonicalComponents(_ path: String, home: String) -> [String]? {
        let url = URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL
        guard let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else { return nil }
        return URL(fileURLWithPath: canonical).resolvingSymlinksInPath().standardizedFileURL
            .pathComponents.map { $0.lowercased() }
    }

    static func resolvedComponents(_ path: String, home: String) -> [String] {
        URL(fileURLWithPath: expand(path, home: home)).resolvingSymlinksInPath().standardizedFileURL
            .pathComponents.map { $0.lowercased() }
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
