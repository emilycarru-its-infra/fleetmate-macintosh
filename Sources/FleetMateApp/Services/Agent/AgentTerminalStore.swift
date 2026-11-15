import AppKit
import Combine
import AgentsMate
import FleetMateCore
import AgentsMateStatus

/// A command a terminal session can start with.
struct AgentLaunch: Hashable {
    /// Empty runs the person's login shell.
    var command: String
    /// Working directory; nil follows the selected repository or agent workspace.
    var directory: String?

    static let shell = AgentLaunch(command: "", directory: nil)
    /// What a session runs when neither the person nor a profile chose.
    static let defaultCommand = "codex"

    /// The commands offered in the new-session menu and in Settings.
    static let presets: [(label: String, command: String)] = [
        ("Shell", ""),
        ("Claude", "claude"),
        ("Codex", "codex"),
        ("Codex (workspace)", "codex --sandbox workspace-write --ask-for-approval on-request"),
        ("Claude (remote)", "claude-remote"),
        ("Codex (remote)", "codex-remote"),
    ]

    /// The presets whose command is installed on this Mac, so a person
    /// without the remote wrappers (or without an agent) is not offered them.
    /// Shell is always there.
    static var installedPresets: [(label: String, command: String)] {
        presets.filter { $0.command.isEmpty || isInstalled($0.command) }
    }

    /// Whether `command`'s program is in one of the folders a login shell
    /// puts on PATH. The app's own PATH lacks them, so look directly.
    static func isInstalled(_ command: String) -> Bool {
        guard let program = command.split(separator: " ").first.map(String.init) else { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return folders.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(program)") }
    }

    /// Whether `command` starts Codex or Claude Code.
    static func isAgent(_ command: String) -> Bool {
        guard let program = command.split(separator: " ").first else { return false }
        return ["codex", "claude"].contains((String(program) as NSString).lastPathComponent)
    }

    var label: String {
        let base = Self.presets.first { $0.command == command }?.label
            ?? command.split(separator: " ").first.map(String.init) ?? "Shell"
        guard let directory else { return base }
        return "\(base) · \((directory as NSString).lastPathComponent)"
    }
}

/// FleetMate's agent terminal: the AgentsMate lane store and dock, plus what
/// only FleetMate knows: the brief and context handed to each agent, the
/// Repos workspace generated from the repository registry, the workspaces
/// file shared with the CLI, and the agent CLI updater.
///
/// Every session is an AgentsMate lane. The person's own sessions are lanes
/// they can close; each Repos workspace entry is a lane too, which closing
/// stops but keeps while it is still in that workspace.
@MainActor
final class AgentTerminalStore: ObservableObject {
    /// The lanes, their terminals, the sidebar's sections and the dock.
    let lanes: AgentLaneStore
    let updater = AgentCliUpdateModel()
    let workspace = AgentWorkspace()
    let contextPath: String
    /// The FleetMate reference every agent gets, regenerated when the
    /// installed `fleetmate` CLI changes.
    let brief: AgentBriefStore
    var subscriptions = Set<AnyCancellable>()

    /// What ⌘T and an empty panel open. Kept current by the window.
    var defaultLaunch: AgentLaunch { resolveDefaultLaunch?() ?? .shell }
    var resolveDefaultLaunch: (() -> AgentLaunch)?
    /// What the agent is told about where the person is in FleetMate.
    var whereabouts: ((String) -> AgentWhereabouts)?
    /// Where a session starts when nothing chose a folder.
    var startDirectory: (() -> String)?
    /// Show the Repos tab, where a repository is cloned. Set by AppState.
    var showRepos: (() -> Void)?
    @Published private(set) var workspaceError: String?
    /// The View menu asked to save the open sessions; the panel asks for the name.
    @Published var savingWorkspaceRequested = false

    static let labels = AgentsModeLabels(listTitle: "Sessions", laneNoun: "session")
    /// The id of the Agent Inbox window scene.
    static let inboxWindowID = "agent-inbox"
    /// The backend a Repos row with no command of its own starts on: the
    /// default agent from Settings, read when it starts.
    static let followsDefaultID = "fleetmate.default"

    /// What FleetMate knows about each Repos row, by lane id.
    private struct Row {
        var directory: String
        var entryId: String?
        var label: String?
        var followsDefault: Bool
    }
    private var rows: [AgentLane.ID: Row] = [:]
    private var restored = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate", isDirectory: true)
        // Owner-only: the brief and selection files describe the person's work.
        try? PrivateFile.ensureDirectory(dir.path)
        contextPath = dir.appendingPathComponent("agent-context.json").path
        brief = AgentBriefStore(directory: dir)
        // Clear the previous run before a session can open.
        try? FileManager.default.removeItem(at: brief.sessionDirectory)
        lanes = AgentLaneStore(
            configuration: .init(termProgram: "FleetMate",
                                 environment: [AgentBrief.contextVariable: contextPath],
                                 baseFontSize: Self.scaledBaseFontSize(),
                                 scrollback: 50_000,
                                 shortcuts: .all,
                                 defaultsPrefix: "agentTerminal.",
                                 highlightsOrphans: true,
                                 sessionFileDirectory: brief.sessionDirectory,
                                 cycleSkipsUnstarted: true,
                                 showsRowMetadata: true,
                                 notifies: !AppEdition.current.isTicketsOnly,
                                 summaryModel: "haiku",
                                 usageSources: [KeyValueUsageFileSource(
                                     url: FileManager.default.homeDirectoryForCurrentUser
                                         .appendingPathComponent(".claude/.statusline-usage-cache"),
                                     agent: "Claude"),
                                                CodexSessionUsageSource()]),
            backends: [CommandLaneBackend(id: Self.followsDefaultID, displayName: "Default Agent", command: "")],
            statusFeed: LaneStatusFeed(sources: [ClaudeAgentsStatusSource()].compactMap { $0 },
                                       presenceSources: [TmuxPresenceSource()]))
        lanes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        lanes.onNewLane = { [weak self] in self?.open(self?.defaultLaunch ?? .shell) }
        // A notification, the inbox or Jump to Unread brings the terminal up.
        lanes.onShowLane = { [weak self] _ in self?.lanes.showDock() }
        lanes.willStartLane = { [weak self] lane in self?.prepare(lane) ?? lane }
        lanes.willCloseLane = { [weak self] lane, attached in
            guard let self, let row = self.rows[lane.id] else { return .remove }
            // A running repository row stops and stays; an idle one goes.
            return attached && self.baselineKeys.contains(row.entryId ?? row.directory) ? .keepRow : .remove
        }
        lanes.didCloseLane = { [weak self] lane, decision in
            guard let self else { return }
            self.brief.removeSessionBrief(id: lane.id)
            if decision == .remove, self.rows.removeValue(forKey: lane.id) != nil { self.persistBaselineRows() }
        }
        // A rename, pin, move or reorder of a repository row goes back to the
        // Repos workspace, so the next sync keeps it.
        lanes.$layout.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistBaselineRows() }
            .store(in: &subscriptions)
        let brief = brief
        Task.detached(priority: .utility) { brief.refresh() }
        updater.start()
        // Follow the app's text size as it changes (Settings, View › Zoom).
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let size = Self.scaledBaseFontSize()
                if self?.lanes.configuration.baseFontSize != size { self?.lanes.configuration.baseFontSize = size }
            }
            .store(in: &subscriptions)
    }

    /// The fallback workspace is independent of any repository checkout.
    static func workspaceDirectory() -> String { AgentWorkspace().root.path }

    /// 12 pt at FleetMate's text size; ⌘+ / ⌘- in a terminal add to it.
    static func scaledBaseFontSize() -> CGFloat {
        let scale = UserDefaults.standard.object(forKey: AppFontScale.storageKey) as? Double ?? AppFontScale.default
        return (12 * CGFloat(AppFontScale.clamp(scale))).rounded()
    }

    // MARK: Backends

    /// The backend for a command, registered the first time it is used.
    /// Remote wrappers attach persistent lanes and get the folder as their
    /// argument; everything else runs in the folder and drops to a shell
    /// when it ends.
    func backendID(for command: String) -> String {
        let command = command.trimmingCharacters(in: .whitespaces)
        let id = "cmd:" + command
        if lanes.backend(id: id) == nil { lanes.register(makeBackend(id: id, command: command)) }
        return id
    }

    private func makeBackend(id: String, command: String) -> CommandLaneBackend {
        let program = command.split(separator: " ").first.map { (String($0) as NSString).lastPathComponent } ?? ""
        let name = AgentLaunch.presets.first { $0.command == command }?.label ?? (program.isEmpty ? "Shell" : program)
        if program.hasSuffix("-remote") {
            // A duplicate asks the wrapper for a second lane in the folder
            // (`-n 2`); the wrappers name it "<folder>-2", Codex's with "cx-".
            let prefix = program.hasPrefix("codex") ? "cx-" : ""
            return .tmuxLane(id: id, displayName: name, command: command,
                             statusAgent: program.hasPrefix("codex") ? "codex" : "claude",
                             variantFlag: "-n",
                             variantStatusName: { @Sendable lane in
                                 lane.variant.map { variant in
                                     let base = (lane.path as NSString).lastPathComponent.lowercased()
                                         .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-")
                                     return prefix + base + "-" + variant
                                 }
                             })
        }
        var line = command
        // FleetMate keeps the CLIs current, so Codex must not update itself mid-session.
        if program == "codex", updater.isEnabled { line = line.replacingOccurrences(of: "codex", with: "codex -c check_for_update_on_startup=false", options: .anchored) }
        var backend = CommandLaneBackend(id: id, displayName: name, command: line, returnsToShell: !command.isEmpty)
        backend.extraDirectories = [workspace.root.path, brief.sessionDirectory.path]
        return backend
    }

    /// Get a lane ready to start: settle a row that follows the default,
    /// write its brief, and hand it FleetMate's environment.
    private func prepare(_ lane: AgentLane) -> AgentLane {
        var lane = lane
        if lane.backendID == Self.followsDefaultID { lane.backendID = backendID(for: defaultLaunch.command) }
        brief.refresh()
        do {
            try workspace.prepare()
            workspaceError = nil
        } catch {
            workspaceError = "Could not prepare the agent workspace: \(error.localizedDescription)"
        }
        let directory = lane.path
        let place = whereabouts?(directory) ?? AgentWhereabouts(module: "FleetMate", workingDirectory: directory)
        let paths = brief.writeSessionBrief(id: lane.id, whereabouts: place)
        let command = (lanes.backend(id: lane.backendID) as? CommandLaneBackend)?.command ?? ""
        let program = command.split(separator: " ").first.map { (String($0) as NSString).lastPathComponent } ?? ""
        lane.promptFile = program == "codex" ? URL(fileURLWithPath: paths.codexValuePath)
            : program == "claude" ? URL(fileURLWithPath: paths.briefPath) : nil
        var env = [AgentBrief.briefVariable: paths.briefPath,
                   "FLEETMATE_WORKSPACE": workspace.root.path,
                   "FLEETMATE_INSTRUCTIONS": workspace.instructionsURL.path]
        if let file = lanes.sessionFile(for: lane.id) { env["FLEETMATE_SESSION"] = file.path }
        if updater.isEnabled {
            env["DISABLE_AUTOUPDATER"] = "1"
            if AgentLaunch.isAgent(command) { updater.updateIfStale() }
        }
        lane.environment = env
        // The person's own sessions report through AGENTSMATE_LANE.
        if !program.hasSuffix("-remote") { lane.statusMatch = .lane(lane.id) }
        return lane
    }

    // MARK: Sessions

    /// Open a session the person can close, beside the selected one's
    /// section. `show` false leaves the panel as it is, so a session started
    /// at launch waits behind the toolbar button.
    @discardableResult
    func open(_ launch: AgentLaunch, focus: Bool = true, show: Bool = true, start: Bool = true) -> AgentLane.ID {
        let directory = launch.directory.map { ($0 as NSString).expandingTildeInPath }
            ?? startDirectory?() ?? Self.workspaceDirectory()
        let section = lanes.selected.flatMap { rows[$0.id] == nil ? lanes.layout.section(of: $0.lane) : nil }
        let lane = AgentLane(id: UUID().uuidString, title: launch.label,
                             directory: URL(fileURLWithPath: directory, isDirectory: true),
                             backendID: backendID(for: launch.command), isClosable: true, section: section)
        lanes.add(lane, focus: focus, open: start)
        if show { lanes.showDock() }
        return lane.id
    }

    var isShowing: Bool { lanes.dockVisible && !lanes.lanes.isEmpty }
    var isVisible: Bool { lanes.dockVisible }
    var isMaximized: Bool {
        get { lanes.dockMaximized }
        set { lanes.dockMaximized = newValue }
    }
    var selected: AgentLaneSession? { lanes.selected }
    var hasOwnSessions: Bool { lanes.lanes.contains { rows[$0.id] == nil } }

    func show(defaultLaunch: AgentLaunch) {
        if lanes.selected == nil { open(defaultLaunch) } else { lanes.showDock() }
    }

    /// Show the panel in the mode it was last used in: split or full window.
    func expand(defaultLaunch: AgentLaunch) { show(defaultLaunch: defaultLaunch) }

    func hide() { lanes.hideDock() }

    func toggle(defaultLaunch: AgentLaunch) {
        if isShowing { hide() } else { expand(defaultLaunch: defaultLaunch) }
    }

    /// Whether a terminal has the keyboard in the key window.
    var hasKeyboardFocus: Bool { isShowing && NSApp.keyWindow?.firstResponder is AgentTerminalView }
    func adjustFont(by points: CGFloat) { lanes.adjustFont(by: points) }
    func resetFont() { lanes.resetFont() }

    /// Put `text` into a running agent's input without pressing Return,
    /// selecting that session. Returns false when no agent takes it; the
    /// caller copies the text instead.
    @discardableResult
    func insert(_ text: String) -> Bool {
        let order = [lanes.selected].compactMap { $0 } + lanes.displayOrder.compactMap { lanes.sessions[$0.id] }
        guard let session = order.first(where: { $0.programIsForeground && $0.view.acceptsBracketedPaste }) else { return false }
        lanes.open(session.id)
        lanes.showDock()
        return session.send(text)
    }

    func terminateAll() {
        saveRestore()
        lanes.detachAll()
        try? FileManager.default.removeItem(at: brief.sessionDirectory)
    }

    // MARK: Workspaces file

    @Published private(set) var workspaceFile = TerminalWorkspaceFile()
    @Published private(set) var workspaceFileError: String?

    func reloadWorkspaces() {
        do {
            let file = try TerminalWorkspaceStore.load()
            if file != workspaceFile { workspaceFile = file }
            workspaceFileError = nil
        } catch {
            workspaceFileError = "Could not read \(TerminalWorkspaceStore.abbreviate(TerminalWorkspaceStore.defaultPath)): \(error.localizedDescription)"
        }
    }

    private func writeWorkspaces(_ change: (inout TerminalWorkspaceFile) -> Void) {
        reloadWorkspaces()
        guard workspaceFileError == nil else { return }
        var file = workspaceFile
        change(&file)
        do {
            try TerminalWorkspaceStore.save(file)
            workspaceFile = file
        } catch {
            workspaceFileError = "Could not save the workspaces: \(error.localizedDescription)"
        }
    }

    private func command(of lane: AgentLane) -> String {
        if lane.backendID == Self.followsDefaultID { return defaultLaunch.command }
        return String(lane.backendID.dropFirst("cmd:".count))
    }

    private func entry(for lane: AgentLane, onlyCustomName: Bool = true) -> TerminalWorkspace.Session {
        let session = lanes.sessions[lane.id]
        let row = rows[lane.id]
        let directory = row?.directory ?? session?.currentDirectory ?? lane.path
        return TerminalWorkspace.Session(
            name: lanes.layout.names[lane.id], label: row?.label,
            command: row?.followsDefault == true ? nil : command(of: lane),
            directory: TerminalWorkspaceStore.abbreviate(directory),
            pinned: lanes.layout.pinned.contains(lane.id) ? true : nil,
            id: row?.entryId)
    }

    /// The sessions open now, by section, as a workspace named `name`.
    func snapshot(named name: String) -> TerminalWorkspace {
        let sections = lanes.groups.filter { !$0.isPinned }.map { group in
            TerminalWorkspace.Section(
                name: group.section ?? "Sessions",
                collapsed: group.section.map { lanes.layout.collapsed.contains($0) } == true ? true : nil,
                sessions: group.lanes.map { entry(for: $0) })
        }
        let pinned = lanes.groups.first { $0.isPinned }?.lanes ?? []
        var all = sections
        for lane in pinned {
            let name = lanes.layout.section(of: lane) ?? "Sessions"
            if let index = all.firstIndex(where: { $0.name == name }) { all[index].sessions.append(entry(for: lane)) }
            else { all.append(.init(name: name, sessions: [entry(for: lane)])) }
        }
        return TerminalWorkspace(name: name, show: true, fullWindow: isMaximized && isVisible ? true : nil, sections: all)
    }

    func saveWorkspace(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let workspace = snapshot(named: name)
        writeWorkspaces { $0.upsert(workspace) }
    }

    func deleteWorkspace(named name: String) { writeWorkspaces { $0.remove(named: name) } }
    func setOpenAtLaunch(_ name: String?) { writeWorkspaces { $0.openAtLaunch = name } }

    /// Open a workspace's sessions beside any already open; one open with the
    /// same name, command and folder is not opened twice.
    func open(workspace: TerminalWorkspace, show: Bool? = nil) {
        var first: AgentLane.ID?
        for section in workspace.sections {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let sectionName = name == "Sessions" ? nil : name
            if let sectionName {
                lanes.addSection(sectionName)
                if section.collapsed == true { lanes.layout.collapsed.insert(sectionName) }
            }
            for saved in section.sessions {
                let wanted = saved.command ?? (workspace.source == TerminalWorkspaceBaseline.source ? defaultLaunch.command : "")
                let directory = saved.directory.map { TerminalWorkspaceStore.expand($0) }
                let title = saved.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let already = lanes.lanes.contains { lane in
                    command(of: lane) == wanted && lanes.layout.names[lane.id] == title
                        && (directory == nil || LaneStatusMatch.normalizedPath(lane.path) == LaneStatusMatch.normalizedPath(directory!))
                }
                if already { continue }
                let id = open(AgentLaunch(command: wanted, directory: directory), focus: false, show: false, start: false)
                if let title, !title.isEmpty { lanes.rename(id, to: title) }
                lanes.move(id, to: sectionName)
                if saved.pinned == true { lanes.setPinned(id, true) }
                if first == nil { first = id }
            }
        }
        if first == nil && show == nil { return }
        if let first { lanes.open(first, focus: true) }
        if show ?? workspace.show ?? true {
            lanes.showDock()
            isMaximized = workspace.fullWindow ?? false
        }
    }

    // MARK: Restore at relaunch

    /// Reopen sessions at launch (Settings › Agent). Default on.
    var restoresSessions: Bool {
        UserDefaults.standard.object(forKey: AgentSettingsKey.restoreSessions) as? Bool ?? true
    }

    /// Put the sessions open when FleetMate last quit back in the list,
    /// waiting to start, with agents set to resume their conversation.
    func restoreLastSessions() {
        guard !AppEdition.current.isTicketsOnly, restoresSessions, !restored,
              let restore = workspaceFile.restore else { return }
        restored = true
        var first: AgentLane.ID?
        for section in restore.sections {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for saved in section.sessions {
                let command = saved.command ?? ""
                let directory = saved.directory.map { TerminalWorkspaceStore.expand($0) }
                // A repository row resumes when next chosen.
                if let directory, let (id, _) = rows.first(where: {
                    $0.value.directory == TerminalWorkspaceBaseline.normalized(directory) && $0.value.entryId == saved.id
                }) {
                    lanes.sessions[id]?.resumeOnStart = saved.resume == true
                    continue
                }
                let id = open(AgentLaunch(command: command, directory: directory), focus: false, show: false, start: false)
                if let title = saved.name, !title.isEmpty { lanes.rename(id, to: title) }
                lanes.move(id, to: name == "Sessions" ? nil : name)
                if saved.pinned == true { lanes.setPinned(id, true) }
                lanes.sessions[id]?.resumeOnStart = saved.resume == true
                if first == nil { first = id }
            }
        }
        // ⌃` brings the first one back, resuming, rather than a new session.
        if lanes.selected == nil, let first { lanes.selectedID = first }
    }

    /// Record the running sessions for the next launch.
    private func saveRestore() {
        guard !AppEdition.current.isTicketsOnly, restoresSessions else { return }
        let running = lanes.displayOrder.filter { lanes.sessions[$0.id]?.isAttached == true }
        var sections: [TerminalWorkspace.Section] = []
        for lane in running {
            let name = lanes.layout.section(of: lane) ?? "Sessions"
            var saved = entry(for: lane)
            saved.command = command(of: lane)
            saved.resume = AgentResume.command(saved.command ?? "") != nil ? true : nil
            if let index = sections.firstIndex(where: { $0.name == name }) { sections[index].sessions.append(saved) }
            else { sections.append(.init(name: name, sessions: [saved])) }
        }
        let restore = TerminalWorkspace(name: "Last Sessions", sections: sections)
        writeWorkspaces { $0.restore = sections.isEmpty ? nil : restore }
    }

    // MARK: Repos workspace

    /// The registry's checkouts the Repos tab knows and shows.
    private func repoCheckouts() -> [TerminalWorkspaceBaseline.Checkout] {
        let store = RepoRegistryStore()
        guard let document = try? store.load() else { return [] }
        return TerminalWorkspaceBaseline.checkouts(
            from: document, excluding: TerminalWorkspaceBaseline.hiddenRepoIds(registryPath: store.registryPath))
    }

    var hasRepoCheckouts: Bool { !repoCheckouts().isEmpty }

    /// The Repos workspace's sessions as rows know them: an added session
    /// by its id, the rest by folder as compared.
    private var baselineKeys: Set<String> {
        Set((workspaceFile.baseline?.sections ?? []).flatMap(\.sessions).compactMap(\.rowKey))
    }

    private static func rowID(directory: String, entryId: String?) -> AgentLane.ID {
        "repo:" + (entryId ?? directory)
    }

    /// Keep the Repos workspace in step with the tracked repositories and
    /// show it in the list: one section per host, one row per repository,
    /// each starting in its folder the first time it is chosen.
    func syncBaseline() {
        guard !AppEdition.current.isTicketsOnly else { return }
        reloadWorkspaces()
        guard workspaceFileError == nil else { return }
        var file = workspaceFile
        if file.syncBaseline(with: repoCheckouts(), defaultCommand: defaultLaunch.command) {
            do {
                try TerminalWorkspaceStore.save(file)
                workspaceFile = file
            } catch {
                workspaceFileError = "Could not save the workspaces: \(error.localizedDescription)"
            }
        }
        applyBaselineToList()
        watchRegistry()
    }

    /// Add a lane for every Repos workspace session not in the list yet and
    /// take out rows, not yet started, whose session left the workspace.
    private func applyBaselineToList() {
        let wanted = baselineKeys
        for (id, row) in rows where !wanted.contains(row.entryId ?? row.directory) && lanes.sessions[id]?.isStarted != true {
            rows.removeValue(forKey: id)
            lanes.close(id)
        }
        for section in workspaceFile.baseline?.sections ?? [] {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if section.collapsed == true, !lanes.layout.sections.contains(name) { lanes.layout.collapsed.insert(name) }
            lanes.addSection(name)
            for saved in section.sessions {
                guard let directory = saved.directory else { continue }
                let key = TerminalWorkspaceBaseline.normalized(directory)
                let id = Self.rowID(directory: key, entryId: saved.id)
                guard rows[id] == nil else { continue }
                let path = TerminalWorkspaceStore.expand(directory)
                rows[id] = Row(directory: key, entryId: saved.id, label: saved.label, followsDefault: saved.command == nil)
                let lane = AgentLane(id: id, title: saved.label ?? (path as NSString).lastPathComponent,
                                     directory: URL(fileURLWithPath: path, isDirectory: true),
                                     backendID: saved.command.map(backendID(for:)) ?? Self.followsDefaultID,
                                     isClosable: true, section: name)
                lanes.add(lane, focus: false, open: false)
                if let title = saved.name?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                   lanes.layout.names[id] == nil { lanes.rename(id, to: title) }
                if saved.pinned == true { lanes.setPinned(id, true) }
                lanes.sessions[id]?.resumeOnStart = saved.resume == true
            }
        }
    }

    /// Write the list's repository rows back to the Repos workspace: their
    /// names, pins, sections and order, and the absence of removed rows.
    private func persistBaselineRows() {
        guard workspaceFile.baselineIndex != nil, !rows.isEmpty || workspaceFile.baseline?.sessionCount ?? 0 > 0 else { return }
        let out = lanes.displayOrder.compactMap { lane -> TerminalWorkspaceBaseline.Row? in
            guard let row = rows[lane.id] else { return nil }
            return TerminalWorkspaceBaseline.Row(
                id: row.entryId, directory: TerminalWorkspaceStore.abbreviate(lane.path),
                label: row.label, section: lanes.layout.section(of: lane) ?? "Sessions",
                name: lanes.layout.names[lane.id] ?? "",
                pinned: lanes.layout.pinned.contains(lane.id),
                command: row.followsDefault ? nil : command(of: lane))
        }
        let order = lanes.sectionNames
        let collapsed = lanes.layout.collapsed
        writeWorkspaces { file in
            guard let index = file.baselineIndex else { return }
            TerminalWorkspaceBaseline.write(out, sections: order, collapsed: collapsed, to: &file.workspaces[index])
        }
    }

    private var registryWatch: Timer?
    private var registryModified: Date?

    /// Sync again whenever the repository registry changes.
    private func watchRegistry() {
        registryModified = registryModificationDate()
        guard registryWatch == nil else { return }
        registryWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let modified = self.registryModificationDate()
                if modified != self.registryModified { self.syncBaseline() }
            }
        }
    }

    private func registryModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: RepoRegistryStore.defaultRegistryPath))?[.modificationDate] as? Date
    }

    /// Rebuild the Repos workspace from the checkouts now, keeping its name
    /// and place; every other workspace is left alone.
    func regenerateBaselineWorkspace() {
        guard var baseline = TerminalWorkspaceBaseline.make(from: repoCheckouts()) else {
            workspaceFileError = "No repositories are checked out yet. Clone one in Development › Repos."
            return
        }
        writeWorkspaces { file in
            file.generateFromRepos = nil
            if let index = file.baselineIndex {
                baseline.name = file.workspaces[index].name
                file.workspaces[index] = baseline
            } else {
                file.workspaces.insert(baseline, at: 0)
            }
        }
        for (id, _) in rows where lanes.sessions[id]?.isStarted != true {
            rows.removeValue(forKey: id)
            lanes.close(id)
        }
        applyBaselineToList()
    }

    /// Add checkouts the Repos workspace lacks, keeping every edit to it.
    func addMissingReposToBaseline() {
        let checkouts = repoCheckouts()
        guard !checkouts.isEmpty else {
            workspaceFileError = "No repositories are checked out yet. Clone one in Development › Repos."
            return
        }
        writeWorkspaces { file in
            file.generateFromRepos = nil
            if let index = file.baselineIndex {
                TerminalWorkspaceBaseline.addMissing(checkouts, to: &file.workspaces[index])
            } else if let baseline = TerminalWorkspaceBaseline.make(from: checkouts) {
                file.workspaces.insert(baseline, at: 0)
            }
        }
        applyBaselineToList()
    }
}

/// UserDefaults keys for the person's own agent settings. Unset falls back to
/// the managed defaults in FleetMateConfig.
enum AgentSettingsKey {
    static let command = "agentCommand"
    static let autoStart = "agentAutoStart"
    static let repos = "agentRepos"
    static let panelHeight = "agentPanelHeight"
    /// The terminal was last open filling the window rather than split.
    static let lastFullWindow = "agentTerminalLastFullWindow"
    /// Session list filters, sort and search in the terminal's sidebar.
    /// The session list's width, dragged at its divider.
    static let listWidth = "agentTerminalListWidth"
    static let filterActive = "agentTerminalFilterActive"
    static let filterRunning = "agentTerminalFilterRunning"
    static let filterPaused = "agentTerminalFilterPaused"
    static let sortMode = "agentTerminalSortMode"
    /// Points the terminal's text is above or below the app's text size.
    static let fontOffset = "agentTerminalFontOffset"
    /// Keep codex and claude at their latest versions. Default on.
    static let keepClisCurrent = "agentKeepClisCurrent"
    /// Reopen the sessions open at quit, agents resuming. Default on.
    static let restoreSessions = "agentRestoreSessions"
}
