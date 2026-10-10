import AppKit
import SwiftTerm
import FleetMateCore

/// A command a terminal session can start with.
struct AgentLaunch: Hashable {
    /// Empty runs the person's login shell.
    var command: String
    /// Working directory; nil is the home folder.
    var directory: String?

    static let shell = AgentLaunch(command: "", directory: nil)
    /// What a session runs when neither the person nor a profile chose.
    static let defaultCommand = "codex"

    /// The commands offered in the new-session menu and in Settings.
    static let presets: [(label: String, command: String)] = [
        ("Shell", ""),
        ("Claude", "claude"),
        ("Codex", "codex"),
        ("Claude (remote)", "claude-remote"),
        ("Codex (remote)", "codex-remote"),
    ]

    var label: String {
        let base = Self.presets.first { $0.command == command }?.label
            ?? command.split(separator: " ").first.map(String.init) ?? "Shell"
        guard let directory else { return base }
        return "\(base) · \((directory as NSString).lastPathComponent)"
    }
}

/// Keys a terminal handles itself while it has focus, the way Terminal and
/// iTerm do, ahead of the app's menus.
enum TerminalShortcut {
    case newSession, closeSession, split, clear, next, previous, select(Int), maximize

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case (.command, "t"): self = .newSession
        case (.command, "w"): self = .closeSession
        case (.command, "d"): self = .split
        case (.command, "k"): self = .clear
        case ([.command, .shift], "\r"): self = .maximize
        case ([.command, .shift], "]"), ([.command, .shift], "}"), (.control, "\t"): self = .next
        case ([.command, .shift], "["), ([.command, .shift], "{"), ([.control, .shift], "\t"): self = .previous
        case (.command, _) where Int(key).map({ (1...9).contains($0) }) == true:
            self = .select(Int(key)! - 1)
        default:
            if event.keyCode == 48, flags.contains(.control) { // Tab
                self = flags.contains(.shift) ? .previous : .next
            } else {
                return nil
            }
        }
    }
}

/// SwiftTerm's view with the hooks a session list needs: output and bell
/// reported out, and terminal shortcuts caught while it has focus.
final class FleetMateTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onBell: (() -> Void)?
    var onShortcut: ((TerminalShortcut) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let shortcut = TerminalShortcut(event) {
            onShortcut?(shortcut)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clear the screen and scrollback, then ask the shell to redraw its prompt.
    func clearScreen() {
        feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        send([0x0c])
    }
}

/// One terminal: a pseudo-terminal running the session's command, with the
/// view that draws it. The view is created once and kept for the session's
/// life, so moving between tabs or hiding the panel never ends the process.
@MainActor
final class AgentTerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    enum Activity { case idle, busy, attention, exited }

    let id = UUID()
    let launch: AgentLaunch
    let view: FleetMateTerminalView
    /// What the program running in the session calls it: an agent's session
    /// name (Claude's /rename), or the shell's title.
    @Published private(set) var programTitle: String?
    /// The shell's working directory, followed as it changes.
    @Published private(set) var directory: String
    @Published private(set) var activity: Activity = .idle
    /// Take keyboard focus the next time the view is shown. Set for sessions
    /// the person opened; a session started at launch must not steal typing
    /// from whatever they are doing.
    @Published var wantsFocus = false
    /// Set by the store: whether this session is on screen, so a bell from a
    /// session out of sight flags it for attention.
    var isShown = false {
        didSet { if isShown, activity == .attention { activity = .idle } }
    }

    private var lastOutput = Date.distantPast
    private var poll: Timer?

    var title: String {
        if let programTitle, !programTitle.isEmpty { return programTitle }
        return launch.label
    }

    /// The directory with the home folder as ~.
    var shortDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }

    init(launch: AgentLaunch, contextPath: String, brief: AgentBriefStore) {
        self.launch = launch
        let start = launch.directory.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.directory = start
        self.view = FleetMateTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.onOutput = { [weak self] in
            Task { @MainActor in self?.noteOutput() }
        }
        view.onBell = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShown else { return }
                self.activity = .attention
            }
        }
        startProcess(contextPath: contextPath, brief: brief, directory: start)
        // Follow the shell's directory and let a busy session settle back to
        // idle once output stops.
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func startProcess(contextPath: String, brief: AgentBriefStore, directory: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var args = ["-l"]
        let command = launch.command.trimmingCharacters(in: .whitespaces)
        if !command.isEmpty {
            // Claude Code and Codex are handed the FleetMate brief on their
            // command line; anything else finds it through the environment.
            var line = AgentBrief.launchLine(command, briefPath: brief.briefPath,
                                             codexValuePath: brief.codexValuePath)
            // The remote wrappers take the folder to open as their argument.
            if let dir = launch.directory, command.hasSuffix("-remote") {
                line += " " + Self.quote(dir)
            }
            // An interactive login shell loads the person's PATH; when the
            // agent exits the pane drops to a shell instead of closing.
            args = ["-l", "-i", "-c", "\(line); exec \(Self.quote(shell)) -l"]
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM_PROGRAM"] = "FleetMate"
        // How an agent sees what the person is looking at in FleetMate.
        env[AgentBrief.contextVariable] = contextPath
        // What FleetMate is and every `fleetmate` command, for any agent.
        env[AgentBrief.briefVariable] = brief.briefPath
        let environment = env.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: shell, args: args, environment: environment,
                          execName: nil, currentDirectory: directory)
    }

    private func noteOutput() {
        lastOutput = Date()
        if activity == .idle { activity = .busy }
    }

    private func refresh() {
        guard activity != .exited else { return }
        if activity == .busy, Date().timeIntervalSince(lastOutput) > 2 { activity = .idle }
        if let pid = view.process?.shellPid, pid > 0, let cwd = Self.workingDirectory(of: pid), cwd != directory {
            directory = cwd
        }
    }

    /// A process's current directory, from the kernel.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    func terminate() {
        poll?.invalidate()
        poll = nil
        view.terminate()
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.programTitle = title.trimmingCharacters(in: .whitespaces) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        Task { @MainActor in self.directory = url.path }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.activity = .exited
            self.poll?.invalidate()
        }
    }
}

/// Every terminal session in the window, the panel's visibility, and the
/// split. Lives on AppState so it outlasts any tab.
@MainActor
final class AgentTerminalStore: ObservableObject {
    @Published private(set) var sessions: [AgentTerminalSession] = []
    @Published var selectedId: AgentTerminalSession.ID? { didSet { updateShown() } }
    /// The session shown in the right-hand pane when split.
    @Published var splitId: AgentTerminalSession.ID? { didSet { updateShown() } }
    @Published var isVisible = false { didSet { updateShown(); if !isVisible { isMaximized = false } } }
    /// The terminal takes the whole window, the tab hidden behind it.
    @Published var isMaximized = false
    /// What ⌘T opens. Kept current by the window from the person's settings.
    var defaultLaunch: AgentLaunch = .shell

    let contextPath: String
    /// The agent brief beside the context file, regenerated when the
    /// installed `fleetmate` CLI changes.
    let brief: AgentBriefStore

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        contextPath = dir.appendingPathComponent("agent-context.json").path
        brief = AgentBriefStore(directory: dir)
        // Generate ahead of the first session; open() checks again.
        let brief = brief
        Task.detached(priority: .utility) { brief.refresh() }
    }

    var selected: AgentTerminalSession? { sessions.first { $0.id == selectedId } }
    var split: AgentTerminalSession? { sessions.first { $0.id == splitId } }

    /// Start a session. `show` false leaves the panel as it is, so a session
    /// started at launch is ready behind the toolbar button without taking
    /// half the window.
    @discardableResult
    func open(_ launch: AgentLaunch, focus: Bool = true, show: Bool = true) -> AgentTerminalSession {
        // A stat when the brief is current; a regeneration only after the
        // CLI was installed or updated.
        brief.refresh()
        let session = AgentTerminalSession(launch: launch, contextPath: contextPath, brief: brief)
        session.wantsFocus = focus
        let id = session.id
        session.view.onShortcut = { [weak self] shortcut in
            Task { @MainActor in self?.handle(shortcut, from: id) }
        }
        sessions.append(session)
        selectedId = session.id
        if show { isVisible = true }
        return session
    }

    /// Split the panel: the right pane gets a new session like the selected one.
    func toggleSplit() {
        if splitId != nil {
            splitId = nil
            return
        }
        let base = selected?.launch ?? defaultLaunch
        let current = selectedId
        let session = open(base, focus: false)
        splitId = session.id
        selectedId = current
    }

    func close(_ id: AgentTerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        if splitId == id { splitId = nil }
        if selectedId == id {
            let neighbour = sessions.indices.contains(index) ? sessions[index] : sessions.last
            selectedId = neighbour?.id == splitId ? sessions.first { $0.id != splitId }?.id : neighbour?.id
            selected?.wantsFocus = true
        }
        if sessions.isEmpty { isVisible = false }
    }

    func select(_ id: AgentTerminalSession.ID, focus: Bool = true) {
        if id == splitId { splitId = selectedId }
        selectedId = id
        if focus { selected?.wantsFocus = true }
        isVisible = true
    }

    func toggle(defaultLaunch: AgentLaunch) {
        if sessions.isEmpty {
            open(defaultLaunch)
        } else {
            isVisible.toggle()
            if isVisible { selected?.wantsFocus = true }
        }
    }

    func terminateAll() {
        sessions.forEach { $0.terminate() }
    }

    private func cycle(by offset: Int) {
        guard !sessions.isEmpty else { return }
        let index = sessions.firstIndex { $0.id == selectedId } ?? 0
        let next = (index + offset + sessions.count) % sessions.count
        select(sessions[next].id)
    }

    private func handle(_ shortcut: TerminalShortcut, from id: AgentTerminalSession.ID) {
        switch shortcut {
        case .newSession: open(defaultLaunch)
        case .closeSession: close(id)
        case .split: toggleSplit()
        case .clear: sessions.first { $0.id == id }?.view.clearScreen()
        case .next: cycle(by: 1)
        case .previous: cycle(by: -1)
        case .select(let n): if sessions.indices.contains(n) { select(sessions[n].id) }
        case .maximize: isMaximized.toggle()
        }
    }

    private func updateShown() {
        for session in sessions {
            session.isShown = isVisible && (session.id == selectedId || session.id == splitId)
        }
    }
}

/// UserDefaults keys for the person's own agent settings. Unset falls back to
/// the managed defaults in FleetMateConfig.
enum AgentSettingsKey {
    static let command = "agentCommand"
    static let autoStart = "agentAutoStart"
    static let repos = "agentRepos"
    static let panelHeight = "agentPanelHeight"
}
