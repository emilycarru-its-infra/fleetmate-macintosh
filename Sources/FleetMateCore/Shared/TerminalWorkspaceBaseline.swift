import Foundation

/// The workspace FleetMate keeps from the repositories the person tracks:
/// one section per host (Azure DevOps, GitHub, other), a session per
/// repository labelled `Project/Repo` or `owner/repo`, ordered by project or
/// owner, kept in step as repositories are tracked, hidden or removed. Nothing about any organization is built in; it is all
/// read from the registry the Repos tab and `fleetmate repos` share.
public enum TerminalWorkspaceBaseline {
    /// The generated workspace's name, and the mark that it came from Repos.
    public static let name = "Repos"
    public static let source = "repos"

    /// Tracked checkouts are always all included: tracking is how the person
    /// says which repositories they work in. When none is tracked, every
    /// registered checkout is a candidate, and with this many or fewer they
    /// all go in.
    public static let includeAllUpTo = 8
    /// Beyond that, an untracked checkout counts as active when its HEAD
    /// moved (a commit, checkout, merge, pull or rebase) within this many days.
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
        /// Marked tracked in the registry.
        public var tracked: Bool

        public init(provider: RepoProvider, scope: String, displayName: String, path: String,
                    lastActivity: Date?, tracked: Bool = false) {
            self.provider = provider
            self.scope = scope
            self.displayName = displayName
            self.path = path
            self.lastActivity = lastActivity
            self.tracked = tracked
        }
    }

    /// The checkouts that go in: every one when all are tracked or there are
    /// few, otherwise the active ones, or the most recent few when none is.
    public static func activeCheckouts(_ checkouts: [Checkout], now: Date = Date()) -> [Checkout] {
        guard checkouts.count > includeAllUpTo, !checkouts.allSatisfy(\.tracked) else { return checkouts }
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
    /// Its sessions store no command: each runs the default agent from
    /// Settings › Agent as it is when the session starts.
    public static func make(from checkouts: [Checkout], now: Date = Date()) -> TerminalWorkspace? {
        let chosen = activeCheckouts(checkouts, now: now)
        guard !chosen.isEmpty else { return nil }
        var workspace = TerminalWorkspace(name: name, show: true, sections: [])
        workspace.source = source
        workspace.sessionsFollowDefault = true
        add(chosen, to: &workspace)
        workspace.generated = chosen.map { normalized($0.path) }.sorted()
        return workspace
    }

    /// What `sync` changed.
    public struct Change: Equatable, Sendable {
        public var added: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// Bring the Repos workspace in step with the checkouts, the way the
    /// person left it otherwise. A checkout never placed before is added to
    /// its host's section. A session FleetMate placed whose repository is no
    /// longer tracked, is hidden or is gone is taken out. Everything else
    /// stays as arranged: renamed, moved, reordered and re-pointed sessions,
    /// sessions the person added, and the absence of one they removed.
    /// `defaultCommand` is the default agent now, used only to recognize a
    /// command baked into a session by an older build (`migrateCommands`).
    @discardableResult
    public static func sync(_ workspace: inout TerminalWorkspace, with checkouts: [Checkout],
                            defaultCommand: String? = nil, now: Date = Date()) -> Change {
        migrateNames(&workspace)
        migrateCommands(&workspace, defaultCommand: defaultCommand)
        let wanted = activeCheckouts(checkouts, now: now)
        let wantedPaths = Set(wanted.map { normalized($0.path) })
        // A workspace from before `generated` existed: what it holds was placed.
        var placed = Set(workspace.generated
            ?? workspace.sections.flatMap(\.sessions).compactMap(\.directory).map(normalized))
        var change = Change()

        let stale = placed.subtracting(wantedPaths)
        var emptied = Set<Int>()
        for index in workspace.sections.indices {
            let before = workspace.sections[index].sessions.count
            workspace.sections[index].sessions.removeAll { session in
                // One the person added stays, whatever becomes of its repository.
                guard session.id == nil, let directory = session.directory.map(normalized),
                      stale.contains(directory) else { return false }
                change.removed.append(directory)
                return true
            }
            if before > 0, workspace.sections[index].sessions.isEmpty { emptied.insert(index) }
        }
        // Take out sections this removal emptied, never one the person left empty.
        for index in emptied.sorted(by: >) { workspace.sections.remove(at: index) }
        placed.subtract(stale)

        let present = Set(workspace.sections.flatMap(\.sessions).compactMap(\.directory).map(normalized))
        let fresh = wanted.filter { !placed.contains(normalized($0.path)) && !present.contains(normalized($0.path)) }
        add(fresh, to: &workspace)
        change.added = fresh.map { normalized($0.path) }
        placed.formUnion(change.added)
        // A folder the person already had in the workspace counts as placed too.
        placed.formUnion(present.intersection(wantedPaths))
        workspace.generated = placed.sorted()
        return change
    }

    /// Sessions written before `label` existed carried the repository's
    /// name as their own, which would hold back the program's title. Where
    /// it is still exactly the generated `Project/Repo`, it becomes the label.
    static func migrateNames(_ workspace: inout TerminalWorkspace) {
        guard workspace.generated == nil else { return }
        for s in workspace.sections.indices {
            for i in workspace.sections[s].sessions.indices {
                let session = workspace.sections[s].sessions[i]
                guard session.label == nil, let name = session.name, name.contains("/"),
                      let directory = session.directory,
                      name.split(separator: "/").last.map(String.init)?.lowercased()
                        == (TerminalWorkspaceStore.expand(directory) as NSString).lastPathComponent.lowercased()
                else { continue }
                workspace.sections[s].sessions[i].label = name
                workspace.sections[s].sessions[i].name = nil
            }
        }
    }

    /// The commands an older build could have baked into a generated
    /// session: every agent Settings › Agent offers, and the shell.
    public static let bakedCommands: Set<String> = ["", "claude", "codex", "claude-remote", "codex-remote"]

    /// Older builds wrote the default agent into each generated session, so
    /// changing it in Settings never reached them. Once per workspace, a
    /// session FleetMate placed (its folder is in `generated`) whose command
    /// is still one that build could have written (`bakedCommands` or the
    /// default now) drops it and follows the default from then on. A command
    /// the person wrote in by hand stays.
    static func migrateCommands(_ workspace: inout TerminalWorkspace, defaultCommand: String?) {
        guard workspace.sessionsFollowDefault != true else { return }
        let placed = Set(workspace.generated
            ?? workspace.sections.flatMap(\.sessions).compactMap(\.directory).map(normalized))
        var baked = bakedCommands
        if let defaultCommand { baked.insert(defaultCommand.trimmingCharacters(in: .whitespaces)) }
        for s in workspace.sections.indices {
            for i in workspace.sections[s].sessions.indices {
                let session = workspace.sections[s].sessions[i]
                guard session.id == nil, let directory = session.directory, placed.contains(normalized(directory)),
                      let command = session.command,
                      baked.contains(command.trimmingCharacters(in: .whitespaces)) else { continue }
                workspace.sections[s].sessions[i].command = nil
            }
        }
        workspace.sessionsFollowDefault = true
    }

    /// Add the checkouts not already in `workspace` (matched by folder) to
    /// their host's section, leaving every existing session and section as
    /// the person arranged it. Returns how many were added.
    @discardableResult
    public static func addMissing(_ checkouts: [Checkout], to workspace: inout TerminalWorkspace,
                                  now: Date = Date()) -> Int {
        let present = Set(workspace.sections.flatMap(\.sessions).compactMap(\.directory).map(normalized))
        let missing = activeCheckouts(checkouts, now: now).filter { !present.contains(normalized($0.path)) }
        add(missing, to: &workspace)
        return missing.count
    }

    /// Each session stores no command, so it runs the default when it starts.
    private static func add(_ checkouts: [Checkout], to workspace: inout TerminalWorkspace) {
        let ordered = checkouts.sorted {
            ($0.provider.order, $0.scope.lowercased(), $0.displayName.lowercased())
                < ($1.provider.order, $1.scope.lowercased(), $1.displayName.lowercased())
        }
        for checkout in ordered {
            let title = sectionTitle(checkout.provider)
            let session = TerminalWorkspace.Session(label: checkout.displayName,
                                                    directory: TerminalWorkspaceStore.abbreviate(checkout.path))
            if let index = workspace.sections.firstIndex(where: { $0.name == title }) {
                workspace.sections[index].sessions.append(session)
            } else {
                workspace.sections.append(.init(name: title, sessions: [session]))
            }
        }
    }

    /// A folder as compared: home expanded, no trailing slash, any case.
    public static func normalized(_ path: String) -> String {
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
                            lastActivity: lastActivity(ofCheckout: path), tracked: entry.tracked)
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

extension TerminalWorkspaceBaseline {
    /// A row of the session list that stands for a Repos workspace session,
    /// as it is to be written back.
    public struct Row: Equatable, Sendable {
        /// The session's id when the person added it, else nil.
        public var id: String?
        /// Its folder, as stored (`~` for the home folder).
        public var directory: String
        public var label: String?
        public var section: String
        /// The name the person gave it; empty follows the automatic name.
        public var name: String
        public var pinned: Bool
        /// The command it runs; nil follows the default agent.
        public var command: String?

        public init(id: String? = nil, directory: String, label: String? = nil, section: String,
                    name: String = "", pinned: Bool = false, command: String? = nil) {
            self.id = id
            self.directory = directory
            self.label = label
            self.section = section
            self.name = name
            self.pinned = pinned
            self.command = command
        }

        public var key: String { id ?? normalized(directory) }
    }

    /// Write the session list's rows back to the Repos workspace: their
    /// names, pins, commands, sections and order, so the next sync keeps
    /// what the person arranged. An added row (one with an id, such as a
    /// duplicate) not in the workspace yet goes in where it sits; a
    /// generated row whose session is gone stays out. A session with no row was
    /// removed and is left out. Sessions written by hand with no folder stay
    /// in their section. Everything else an entry carries, such as `resume`,
    /// is kept.
    public static func write(_ rows: [Row], sections order: [String], collapsed: Set<String>,
                             to workspace: inout TerminalWorkspace) {
        var entries: [String: TerminalWorkspace.Session] = [:]
        for entry in workspace.sections.flatMap(\.sessions) {
            guard let key = entry.rowKey, entries[key] == nil else { continue }
            entries[key] = entry
        }
        var rebuilt: [TerminalWorkspace.Section] = []
        for name in order {
            let fromRows: [TerminalWorkspace.Session] = rows.filter { $0.section == name }.compactMap { row in
                // Only an added row is new here; a generated one whose
                // session sync took out stays out.
                guard var entry = entries[row.key]
                    ?? row.id.map({ TerminalWorkspace.Session(label: row.label, directory: row.directory, id: $0) })
                else { return nil }
                let custom = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                entry.name = custom.isEmpty ? nil : custom
                entry.pinned = row.pinned ? true : nil
                entry.command = row.command
                return entry
            }
            let unlisted = workspace.sections.first { $0.name == name }?.sessions.filter { $0.directory == nil } ?? []
            guard !fromRows.isEmpty || !unlisted.isEmpty else { continue }
            rebuilt.append(.init(name: name, collapsed: collapsed.contains(name) ? true : nil,
                                 sessions: fromRows + unlisted))
        }
        workspace.sections = rebuilt
    }
}

extension TerminalWorkspaceFile {
    /// Keep the Repos workspace in step with the checkouts: written the first
    /// time there is something checked out (an existing file without one,
    /// even an empty one, gets it too), then synced. Nothing is written once
    /// the person deleted it. Returns whether the file changed.
    @discardableResult
    public mutating func syncBaseline(with checkouts: [TerminalWorkspaceBaseline.Checkout], defaultCommand: String? = nil,
                                      now: Date = Date()) -> Bool {
        if let index = baselineIndex {
            let before = workspaces[index]
            TerminalWorkspaceBaseline.sync(&workspaces[index], with: checkouts, defaultCommand: defaultCommand, now: now)
            return workspaces[index] != before
        }
        guard generateFromRepos != false,
              let baseline = TerminalWorkspaceBaseline.make(from: checkouts, now: now) else { return false }
        workspaces.insert(baseline, at: 0)
        return true
    }

    /// The Repos workspace, when there is one.
    public var baseline: TerminalWorkspace? { baselineIndex.map { workspaces[$0] } }
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
