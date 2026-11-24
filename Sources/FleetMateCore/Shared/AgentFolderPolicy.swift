import Foundation

/// Where the app lets the New Sessions choice or the usage switch start an
/// agent other than its default: work folders only, because each agent's
/// account may see only work.
///
/// A folder is allowed when it is the work root (`~/Developer/AzDevOps`) or
/// inside it, or inside a repository the agent-apps registry offers to agent
/// sessions, and only when that registry is schema 1 and belongs to the work
/// zone. It is never allowed inside, or above, a denied folder:
/// `~/Developer/Personal`, any the `agentDeniedFolders` default lists on
/// this Mac, and the registry's repositories hidden from agents. Every path
/// is canonicalized (symlinks, `~`, `.` and `..` resolved, the on-disk
/// spelling) and compared by whole path components, folding case only on a
/// volume that does not tell case apart. A folder that cannot be
/// canonicalized is denied.
public enum AgentFolderPolicy {
    /// The registry's `app.zone` for work repositories.
    public static let workZone = "ecu"
    /// The user default listing more folders where no other agent may start.
    public static let deniedFoldersKey = "agentDeniedFolders"

    /// What a work-zone registry says about agents.
    public struct WorkRegistry: Equatable, Sendable {
        /// Repositories offered to agent sessions.
        public var agentRepos: [String]
        /// Repositories hidden from agent sessions (`surfaces.agents: false`).
        public var hiddenRepos: [String]

        public init(agentRepos: [String], hiddenRepos: [String] = []) {
            self.agentRepos = agentRepos
            self.hiddenRepos = hiddenRepos
        }
    }

    /// The running app's answer, with its registry and this Mac's denied folders.
    public static func allowsCurrent(_ folder: URL) -> Bool {
        let home = NSHomeDirectory()
        let registry = Bundle.main.bundleIdentifier.flatMap { id in
            FileManager.default.contents(atPath: home + "/.config/agent-apps/repos/\(id).json")
        }.flatMap(workRegistry(from:))
        return allows(folder, home: home, registry: registry,
                      denied: UserDefaults.standard.stringArray(forKey: deniedFoldersKey) ?? [])
    }

    /// The registry's repositories, or nil unless it is schema 1 and in the
    /// work zone.
    public static func workRegistry(from data: Data) -> WorkRegistry? {
        struct Surfaces: Decodable { var agents: Bool? }
        struct Repo: Decodable { var path: String?; var surfaces: Surfaces? }
        struct Section: Decodable { var repos: [Repo]? }
        struct App: Decodable { var zone: String? }
        struct File: Decodable { var schema_version: Int?; var app: App?; var sections: [Section]? }
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              file.schema_version == 1, file.app?.zone == workZone else { return nil }
        var registry = WorkRegistry(agentRepos: [])
        for repo in (file.sections ?? []).flatMap({ $0.repos ?? [] }) {
            guard let path = repo.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if repo.surfaces?.agents ?? true { registry.agentRepos.append(path) } else { registry.hiddenRepos.append(path) }
        }
        return registry
    }

    public static func allows(_ folder: URL, home: String, registry: WorkRegistry?, denied: [String]) -> Bool {
        guard let path = canonicalComponents(folder.path, home: home) else { return false }
        let foldsCase = !volumeIsCaseSensitive(path)
        let deniedRoots = [home + "/Developer/Personal"] + denied + (registry?.hiddenRepos ?? [])
        for root in deniedRoots {
            // A denied root that does not exist still denies by its plain resolved path.
            let components = canonicalComponents(root, home: home) ?? resolvedComponents(root, home: home)
            // Inside a denied folder, or above one so the session could reach it.
            if isWithin(path, components, foldsCase) || isWithin(components, path, foldsCase) { return false }
        }
        return ([home + "/Developer/AzDevOps"] + (registry?.agentRepos ?? [])).contains { root in
            canonicalComponents(root, home: home).map { isWithin(path, $0, foldsCase) } ?? false
        }
    }

    /// Whether `path` is `root` or inside it, by whole components.
    static func isWithin(_ path: [String], _ root: [String], _ foldsCase: Bool) -> Bool {
        guard !root.isEmpty, path.count >= root.count else { return false }
        return zip(path, root).allSatisfy { a, b in
            a == b || (foldsCase && a.caseInsensitiveCompare(b) == .orderedSame)
        }
    }

    /// The path's components from the file system's canonical path (its
    /// on-disk spelling); nil when the file system cannot give one.
    static func canonicalComponents(_ path: String, home: String) -> [String]? {
        let url = URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL
        guard let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else { return nil }
        return URL(fileURLWithPath: canonical).resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    static func resolvedComponents(_ path: String, home: String) -> [String] {
        URL(fileURLWithPath: expand(path, home: home)).resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    /// Whether the volume holding `path` tells case apart; true when unknown,
    /// so nothing is matched by folding case unless the volume says so.
    static func volumeIsCaseSensitive(_ components: [String]) -> Bool {
        let url = URL(fileURLWithPath: NSString.path(withComponents: components))
        let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames ?? true
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
