import Foundation

/// The starting workspace FleetMate writes from the repositories the person
/// has checked out: one section per host (Azure DevOps, GitHub, other), a
/// session per repository named `Project/Repo` or `owner/repo`, ordered by
/// project or owner. Nothing about any organization is built in; it is all
/// read from the registry the Repos tab and `fleetmate repos` share.
public enum TerminalWorkspaceBaseline {
    /// The generated workspace's name, and the mark that it came from Repos.
    public static let name = "Repos"
    public static let source = "repos"

    /// With this many checkouts or fewer, every one is included: someone with
    /// a handful of repositories wants all of them a click away.
    public static let includeAllUpTo = 8
    /// Beyond that, a checkout counts as active when its HEAD moved (a commit,
    /// checkout, merge, pull or rebase) within this many days.
    public static let activeWithinDays = 14

    /// One checkout as the baseline needs it.
    public struct Checkout: Equatable, Sendable {
        public var provider: RepoProvider
        /// The project for Azure DevOps, the owner for GitHub, the host otherwise.
        public var scope: String
        public var displayName: String
        public var path: String
        /// When HEAD last moved; nil when unknown.
        public var lastActivity: Date?

        public init(provider: RepoProvider, scope: String, displayName: String, path: String, lastActivity: Date?) {
            self.provider = provider
            self.scope = scope
            self.displayName = displayName
            self.path = path
            self.lastActivity = lastActivity
        }
    }

    /// The checkouts that go in: all of them when there are few, otherwise
    /// the active ones, or the most recent few when none is active.
    public static func activeCheckouts(_ checkouts: [Checkout], now: Date = Date()) -> [Checkout] {
        guard checkouts.count > includeAllUpTo else { return checkouts }
        let cutoff = now.addingTimeInterval(-Double(activeWithinDays) * 86_400)
        let active = checkouts.filter { ($0.lastActivity ?? .distantPast) >= cutoff }
        if !active.isEmpty { return active }
        return Array(checkouts.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(includeAllUpTo))
    }

    public static func sectionTitle(_ provider: RepoProvider) -> String {
        switch provider {
        case .azureDevOps: "Azure DevOps"
        case .gitHub: "GitHub"
        case .other: "Other"
        }
    }

    /// The baseline workspace, or nil when there is nothing checked out.
    public static func make(from checkouts: [Checkout], command: String, now: Date = Date()) -> TerminalWorkspace? {
        let chosen = activeCheckouts(checkouts, now: now)
        guard !chosen.isEmpty else { return nil }
        var workspace = TerminalWorkspace(name: name, show: true, sections: [])
        workspace.source = source
        add(chosen, to: &workspace, command: command)
        return workspace
    }

    /// Add the checkouts not already in `workspace` (matched by folder) to
    /// their host's section, leaving every existing session and section as
    /// the person arranged it. Returns how many were added.
    @discardableResult
    public static func addMissing(_ checkouts: [Checkout], to workspace: inout TerminalWorkspace,
                                  command: String, now: Date = Date()) -> Int {
        let present = Set(workspace.sections.flatMap(\.sessions).compactMap(\.directory).map(normalized))
        let missing = activeCheckouts(checkouts, now: now).filter { !present.contains(normalized($0.path)) }
        add(missing, to: &workspace, command: command)
        return missing.count
    }

    private static func add(_ checkouts: [Checkout], to workspace: inout TerminalWorkspace, command: String) {
        let ordered = checkouts.sorted {
            ($0.provider.order, $0.scope.lowercased(), $0.displayName.lowercased())
                < ($1.provider.order, $1.scope.lowercased(), $1.displayName.lowercased())
        }
        for checkout in ordered {
            let title = sectionTitle(checkout.provider)
            let session = TerminalWorkspace.Session(name: checkout.displayName, command: command,
                                                    directory: TerminalWorkspaceStore.abbreviate(checkout.path))
            if let index = workspace.sections.firstIndex(where: { $0.name == title }) {
                workspace.sections[index].sessions.append(session)
            } else {
                workspace.sections.append(.init(name: title, sessions: [session]))
            }
        }
    }

    private static func normalized(_ path: String) -> String {
        let expanded = TerminalWorkspaceStore.expand(path)
        return (expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded).lowercased()
    }

    /// When the checkout's HEAD last moved: the modification time of its
    /// HEAD reflog, which git appends on every commit, checkout, merge, pull
    /// and rebase. Follows a worktree's `.git` file to its git directory.
    public static func lastActivity(ofCheckout path: String) -> Date? {
        let fm = FileManager.default
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var gitDir = dotGit
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue,
           let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = target.hasPrefix("/") ? target : (path as NSString).appendingPathComponent(target)
        }
        for file in ["logs/HEAD", "HEAD"] {
            let attributes = try? fm.attributesOfItem(atPath: (gitDir as NSString).appendingPathComponent(file))
            if let date = attributes?[.modificationDate] as? Date { return date }
        }
        return nil
    }

    /// The registry's tracked checkouts that exist on disk (every registered
    /// one when none is marked tracked), with their activity read. Repos in
    /// `hidden` (registry ids, `RepoKey.id`) are left out: the person hid
    /// them from the Repos sidebar, so they stay out of the workspace too.
    public static func checkouts(from document: RepoRegistryDocument, excluding hidden: Set<String> = []) -> [Checkout] {
        let visible = document.entries.filter { !hidden.contains($0.key.id) }
        let tracked = visible.filter(\.tracked)
        let entries = tracked.isEmpty ? visible : tracked
        return entries.compactMap { entry in
            let path = RepoSettings.expand(entry.path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Checkout(provider: entry.key.provider, scope: entry.key.scope,
                            displayName: entry.key.displayName, path: path,
                            lastActivity: lastActivity(ofCheckout: path))
        }
    }
}

extension TerminalWorkspaceBaseline {
    /// The registry ids of the repos hidden from the Repos sidebar: those
    /// whose entry in `repos.json` carries `"hidden": true`. Read straight
    /// from the file so it matches whatever the sidebar wrote, whichever
    /// build wrote it. Empty when the file is missing or unreadable.
    public static func hiddenRepoIds(registryPath: String = RepoRegistryStore.defaultRegistryPath) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: registryPath) else { return [] }
        return hiddenRepoIds(inRegistry: data)
    }

    public static func hiddenRepoIds(inRegistry data: Data) -> Set<String> {
        struct Flag: Decodable { var hidden: Bool? }
        struct Registry: Decodable { var repos: [String: Flag]? }
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data) else { return [] }
        return Set((registry.repos ?? [:]).filter { $0.value.hidden == true }.keys)
    }
}

private extension RepoProvider {
    var order: Int {
        switch self {
        case .azureDevOps: 0
        case .gitHub: 1
        case .other: 2
        }
    }
}
