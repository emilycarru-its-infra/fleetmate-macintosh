import AppKit
import Combine
import SwiftTerm
import FleetMateCore

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

/// Keys a terminal handles itself while it has focus, the way Terminal and
/// iTerm do, ahead of the app's menus.
enum TerminalShortcut {
    case newSession, closeSession, split, clear, next, previous, select(Int), maximize
    /// ⌃` hides the terminal even while it has the keyboard.
    case togglePanel

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case (.control, "`"): self = .togglePanel
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
            if event.keyCode == 50, flags == .control { // ` on any layout's key
                self = .togglePanel
            } else if event.keyCode == 48, flags.contains(.control) { // Tab
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

    private var inputMonitor: Any?

    func installInputHandling() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown, self.window?.firstResponder === self {
                return self.handleKeyDown(event) ? nil : event
            }
            if event.type == .scrollWheel, !self.isHiddenOrHasHiddenAncestor,
               self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                return self.handleScrollWheel(event) ? nil : event
            }
            return event
        }
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .shift, event.keyCode == 36 || event.keyCode == 76 {
            send([0x0a])
            return true
        }
        if flags == .shift {
            switch event.keyCode {
            case 116: pageUp(); return true
            case 121: pageDown(); return true
            case 115: scroll(toPosition: 0); return true
            case 119: scroll(toPosition: 1); return true
            default: break
            }
        }
        return false
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        // Shift always browses local history. Otherwise full-screen agents
        // need wheel events delivered to their UI rather than an empty buffer.
        guard terminal.isCurrentBufferAlternate, !event.modifierFlags.contains(.shift) else {
            return false
        }
        guard event.scrollingDeltaY != 0 else { return true }
        let count = min(10, max(1, Int(abs(event.scrollingDeltaY))))
        if allowMouseReporting, terminal.mouseMode != .off {
            let point = convert(event.locationInWindow, from: nil)
            let column = min(terminal.cols - 1, max(0, Int(point.x / max(bounds.width, 1) * CGFloat(terminal.cols))))
            let row = min(terminal.rows - 1, max(0, Int((bounds.height - point.y) / max(bounds.height, 1) * CGFloat(terminal.rows))))
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: event.scrollingDeltaY > 0 ? 64 : 65,
                                   x: column, y: row, pixelX: Int(point.x), pixelY: Int(bounds.height - point.y))
            }
        } else {
            let sequence = event.scrollingDeltaY > 0 ? "\u{1b}[A" : "\u{1b}[B"
            for _ in 0..<count { send(txt: sequence) }
        }
        return true
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

    /// Whether the program in the terminal takes pasted text as one block
    /// (Claude Code, Codex and zsh all do once they are drawn).
    var acceptsBracketedPaste: Bool { getTerminal().bracketedPasteMode }

    /// Type `text` into the program's input as a paste, never followed by
    /// Return. Control characters and escape sequences are stripped first, so
    /// the text cannot end the paste early, submit it or drive the terminal.
    /// With bracketed paste the newlines stay; without it they become spaces,
    /// so nothing runs until the person presses Return.
    func pasteText(_ text: String) {
        if acceptsBracketedPaste {
            send(txt: "\u{1b}[200~" + AgentContextSanitizer.pastePayload(text) + "\u{1b}[201~")
        } else {
            send(txt: AgentContextSanitizer.clean(text, keepNewlines: false))
        }
    }

    // MARK: Drop

    /// Text dropped on the terminal is pasted; files arrive as quoted paths,
    /// the way Terminal does it.
    static let droppedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: Self.droppedTypes) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            pasteText(text)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            pasteText(urls.map { $0.isFileURL ? AgentTerminalSession.quote($0.path) : $0.absoluteString }.joined(separator: " ") + " ")
        } else {
            return false
        }
        window?.makeFirstResponder(self)
        return true
    }
}

/// One terminal: a pseudo-terminal running the session's command, with the
/// view that draws it. The view is created once and kept for the session's
/// life, so moving between tabs or hiding the panel never ends the process.
@MainActor
final class AgentTerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    enum Activity { case idle, busy, attention, exited }

    let id: UUID
    /// What the session runs. A row that follows the default has its command
    /// filled in by the store just before it starts.
    private(set) var launch: AgentLaunch
    /// A Repos row with no command of its own: it runs the default agent
    /// from Settings › Agent as it is when the row starts.
    let followsDefault: Bool
    let view: FleetMateTerminalView
    /// The terminal title as the program last set it (OSC 0 or 2).
    @Published private(set) var programTitle: String?
    /// The task named in that title, without its status glyph.
    @Published private(set) var titleTask: String?
    /// The title's glyph says the agent is working (a spinner frame).
    @Published private(set) var titleWorking = false
    @Published private(set) var agentTitle: String?
    /// The name the person gave the row; it wins over every automatic name.
    @Published var customTitle = ""
    @Published var section = "Sessions"
    /// The row's name until the program titles it: the repository's name for
    /// a row from the Repos workspace.
    let label: String?
    /// The folder of the Repos workspace entry this row stands for, as
    /// compared (`TerminalWorkspaceBaseline.normalized`); nil for the rest.
    let repoDirectory: String?
    @Published var pinned = false
    /// Resume the agent's last conversation here when the session starts.
    var resume = false
    /// The process has been started. Rows from a workspace wait, as a
    /// bookmark, until they are first shown.
    @Published private(set) var isStarted = false
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

    var onSectionChange: ((String) -> Void)?
    private var metadataModifiedAt: Date?
    private let metadataPath: String

    private var lastOutput = Date.distantPast
    /// When the session last printed or rang its bell; nil until it has.
    private(set) var lastActivity: Date?
    private var poll: Timer?

    var title: String {
        TerminalSessionName.resolve(custom: customTitle, agent: agentTitle, task: titleTask,
                                    label: label, fallback: launch.label)
    }

    /// The folder as a breadcrumb below the repository roots, set by the store.
    var breadcrumbRoots: [String] = []
    var breadcrumb: String { TerminalBreadcrumb.make(directory, roots: breadcrumbRoots) }

    /// The directory with the home folder as ~.
    var shortDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }

    /// Starts `launch` in `directory`. `briefPath` and `codexValuePath` are
    /// this session's own brief, with where it opened at the top.
    /// `cliUpdatesManaged` is true when FleetMate keeps the agent CLIs
    /// current, so they skip their own update checks.
    /// A session that starts nothing until `start` is called.
    init(id: UUID, launch: AgentLaunch, directory start: String, sessionDirectory: URL, fontSize: CGFloat,
         label: String? = nil, repoDirectory: String? = nil, followsDefault: Bool = false) {
        self.id = id
        self.followsDefault = followsDefault
        self.metadataPath = sessionDirectory.appendingPathComponent(id.uuidString + ".json").path
        self.launch = launch
        self.directory = start
        self.label = label
        self.repoDirectory = repoDirectory
        self.view = FleetMateTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
    }

    /// Start the process. `briefPath` and `codexValuePath` are this session's
    /// own brief, with where it opened at the top. `cliUpdatesManaged` is true
    /// when FleetMate keeps the agent CLIs current, so they skip their own
    /// update checks.
    /// Settle a row that follows the default on the command it runs.
    func resolveDefault(_ command: String) {
        guard followsDefault, !isStarted else { return }
        launch.command = command
    }

    func start(contextPath: String, briefPath: String, codexValuePath: String, cliUpdatesManaged: Bool) {
        guard !isStarted else { return }
        isStarted = true
        let start = directory
        view.processDelegate = self
        view.installInputHandling()
        view.getTerminal().changeHistorySize(50_000)
        view.onOutput = { [weak self] in
            Task { @MainActor in self?.noteOutput() }
        }
        view.onBell = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.lastActivity = Date()
                guard !self.isShown else { return }
                self.activity = .attention
            }
        }
        view.registerForDraggedTypes(FleetMateTerminalView.droppedTypes)
        startProcess(contextPath: contextPath, briefPath: briefPath, codexValuePath: codexValuePath,
                     cliUpdatesManaged: cliUpdatesManaged, directory: start)
        // Follow the shell's directory and let a busy session settle back to
        // idle once output stops.
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func startProcess(contextPath: String, briefPath: String, codexValuePath: String,
                              cliUpdatesManaged: Bool, directory: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var args = ["-l"]
        let command = launch.command.trimmingCharacters(in: .whitespaces)
        if !command.isEmpty {
            // Claude Code and Codex are handed the FleetMate brief on their
            // command line; anything else finds it through the environment.
            var line = AgentBrief.launchLine(command, briefPath: briefPath,
                                             codexValuePath: codexValuePath,
                                             selfUpdate: !cliUpdatesManaged)
            // Back after a relaunch: pick the last conversation here up
            // again, or start afresh when there is none to resume.
            if resume, let resumed = AgentResume.command(command) {
                let resumeLine = AgentBrief.launchLine(resumed, briefPath: briefPath,
                                                       codexValuePath: codexValuePath,
                                                       selfUpdate: !cliUpdatesManaged)
                line = resumeLine + " || " + line
            }
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
        env[AgentBrief.briefVariable] = briefPath
        env["FLEETMATE_SESSION"] = metadataPath
        env["FLEETMATE_WORKSPACE"] = AgentWorkspace().root.path
        env["FLEETMATE_INSTRUCTIONS"] = AgentWorkspace().instructionsURL.path
        if cliUpdatesManaged {
            // FleetMate updates Claude Code in the background, so it must not
            // update itself mid-session too.
            env["DISABLE_AUTOUPDATER"] = "1"
        }
        let environment = env.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: shell, args: args, environment: environment,
                          execName: nil, currentDirectory: directory)
    }

    private func noteOutput() {
        lastOutput = Date()
        lastActivity = lastOutput
        if activity == .idle { activity = .busy }
    }

    private func refresh() {
        guard activity != .exited else { return }
        refreshMetadata()
        if activity == .busy, Date().timeIntervalSince(lastOutput) > 2 { activity = .idle }
        if let pid = view.process?.shellPid, pid > 0, let cwd = Self.workingDirectory(of: pid), cwd != directory {
            directory = cwd
        }
    }

    private func refreshMetadata() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: metadataPath),
              let modified = attributes[.modificationDate] as? Date, modified != metadataModifiedAt,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 16_384,
              let data = FileManager.default.contents(atPath: metadataPath),
              let metadata = try? JSONDecoder().decode(AgentSessionMetadata.self, from: data) else { return }
        metadataModifiedAt = modified
        if let title = metadata.title { agentTitle = title }
        if let section = metadata.section, !section.isEmpty { onSectionChange?(section) }
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

    /// Programs that count as an agent CLI when they hold the terminal.
    static let agentPrograms = ["claude", "codex", "node"]

    /// True when the terminal's foreground process is an agent CLI rather than
    /// the shell, from the pseudo-terminal's foreground process group.
    var agentIsForeground: Bool {
        guard isStarted, activity != .exited, let process = view.process, process.childfd >= 0 else { return false }
        let group = tcgetpgrp(process.childfd)
        guard group > 0, group != process.shellPid else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let name = String(cString: buffer).lowercased()
        return Self.agentPrograms.contains { name.hasPrefix($0) }
    }

    /// Output is streaming, or the agent's title shows its spinner: the
    /// program is working.
    var isRunning: Bool { activity == .busy || (titleWorking && activity != .exited && isStarted) }

    /// An agent is waiting on the person: it rang its bell out of sight, or
    /// it sits idle at its prompt.
    var isPaused: Bool {
        activity == .attention || (activity == .idle && !titleWorking && agentIsForeground)
    }

    /// The row's status line.
    enum Status: Equatable { case notStarted, running, paused, idle, exited }

    var status: Status {
        if !isStarted { return .notStarted }
        if activity == .exited { return .exited }
        if isRunning { return .running }
        if isPaused { return .paused }
        return .idle
    }

    func terminate() {
        poll?.invalidate()
        poll = nil
        if isStarted { view.terminate() }
        try? FileManager.default.removeItem(atPath: metadataPath)
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let parsed = TerminalTitle.parse(title)
        Task { @MainActor in
            self.programTitle = title.trimmingCharacters(in: .whitespaces)
            self.titleTask = parsed.task
            self.titleWorking = parsed.working ?? false
        }
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
    @Published var isVisible = false {
        willSet { if newValue && !isVisible { rememberContentFocus() } }
        didSet {
            updateShown()
            if !isVisible { isMaximized = false }
            if oldValue && !isVisible { returnFocusToContent() }
        }
    }
    /// The terminal takes the whole window, the tab hidden behind it.
    /// While the panel is open the choice is remembered, so it reopens in
    /// the mode it was last used in.
    @Published var isMaximized = false {
        didSet { if isVisible { UserDefaults.standard.set(isMaximized, forKey: AgentSettingsKey.lastFullWindow) } }
    }
    /// Whether the terminal was last used filling the window rather than split.
    /// Full window until the person has used it split: the terminal is a mode
    /// to work in, not a strip under the tab.
    var lastUsedFullWindow: Bool {
        UserDefaults.standard.object(forKey: AgentSettingsKey.lastFullWindow) as? Bool ?? true
    }
    /// What ⌘T opens. Kept current by the window from the person's settings.
    /// What a new session runs, read each time so a change in Settings ›
    /// Agent reaches the next session and every Repos row not yet started.
    var defaultLaunch: AgentLaunch { resolveDefaultLaunch?() ?? .shell }
    /// Set by the app: the default from Settings, the managed default or Codex.
    var resolveDefaultLaunch: (() -> AgentLaunch)?
    /// What to tell a new session about where it is, given its directory.
    /// Set by AppState; nil until then.
    var whereabouts: ((String) -> AgentWhereabouts)?
    /// Where a session opens when its launch names no folder.
    var startDirectory: (() -> String)?
    var subscriptions = Set<AnyCancellable>()
    /// Keeps codex and claude current in the background.
    let updater = AgentCliUpdateModel()

    let workspace = AgentWorkspace()
    @Published private(set) var workspaceError: String?
    @Published var sections = ["Sessions"]
    @Published var collapsedSections: Set<String> = []
    let contextPath: String
    /// The agent brief beside the context file, regenerated when the
    /// installed `fleetmate` CLI changes.
    let brief: AgentBriefStore

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate", isDirectory: true)
        // Owner-only: the brief and selection files describe the person's work.
        try? PrivateFile.ensureDirectory(dir.path)
        contextPath = dir.appendingPathComponent("agent-context.json").path
        brief = AgentBriefStore(directory: dir)
        // Clear the previous run before a session can open. Doing this in
        // the detached refresh could remove a newly created session's brief.
        try? FileManager.default.removeItem(at: brief.sessionDirectory)
        // Generate ahead of the first session; open() checks again.
        let brief = brief
        Task.detached(priority: .utility) { brief.refresh() }
        updater.start()
        // Follow the app's text size as it changes (Settings, View › Zoom).
        appliedFontSize = fontSize
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyFont() }
            .store(in: &subscriptions)
    }

    /// The fallback workspace is independent of any repository checkout.
    static func workspaceDirectory() -> String { AgentWorkspace().root.path }

    var selected: AgentTerminalSession? { sessions.first { $0.id == selectedId } }
    var split: AgentTerminalSession? { sessions.first { $0.id == splitId } }

    /// Start a session. `show` false leaves the panel as it is, so a session
    /// started at launch is ready behind the toolbar button without taking
    /// half the window.
    @discardableResult
    func open(_ launch: AgentLaunch, focus: Bool = true, show: Bool = true) -> AgentTerminalSession {
        let session = makeSession(launch)
        session.wantsFocus = focus
        // Beside the selected session, unless that is a repository's row:
        // a new session is the person's own, not one of Repos'.
        session.section = selected.flatMap { $0.repoDirectory == nil ? $0.section : nil } ?? "Sessions"
        sessions.append(session)
        startIfNeeded(session)
        selectedId = session.id
        if show { isVisible = true }
        return session
    }

    /// A session ready to start, in the list but running nothing yet.
    private func makeSession(_ launch: AgentLaunch, label: String? = nil,
                             repoDirectory: String? = nil, followsDefault: Bool = false) -> AgentTerminalSession {
        let id = UUID()
        var directory = launch.directory.map { ($0 as NSString).expandingTildeInPath }
            ?? startDirectory?() ?? Self.workspaceDirectory()
        if directory == workspace.root.path {
            do {
                try workspace.prepare()
            } catch {
                workspaceError = "Could not prepare the agent workspace: \(error.localizedDescription)"
                directory = FileManager.default.homeDirectoryForCurrentUser.path
            }
        }
        let session = AgentTerminalSession(id: id, launch: launch, directory: directory,
                                           sessionDirectory: brief.sessionDirectory, fontSize: fontSize,
                                           label: label, repoDirectory: repoDirectory,
                                           followsDefault: followsDefault)
        session.breadcrumbRoots = breadcrumbRoots
        session.onSectionChange = { [weak self, weak session] name in
            guard let self, let session else { return }
            self.addSection(name)
            self.move(session, to: name)
        }
        session.view.onShortcut = { [weak self] shortcut in
            Task { @MainActor in self?.handle(shortcut, from: id) }
        }
        return session
    }

    /// Start a session's process the first time it is needed: opened,
    /// selected or shown in the split.
    func startIfNeeded(_ session: AgentTerminalSession) {
        guard !session.isStarted else { return }
        // A stat when the brief is current; a regeneration only after the
        // CLI was installed or updated.
        brief.refresh()
        do {
            try workspace.prepare()
            workspaceError = nil
        } catch {
            workspaceError = "Could not prepare the agent workspace: \(error.localizedDescription)"
        }
        // A Repos row with no command of its own runs the default as it is now.
        session.resolveDefault(defaultLaunch.command)
        let directory = session.directory
        let place = whereabouts?(directory) ?? AgentWhereabouts(module: "FleetMate", workingDirectory: directory)
        let paths = brief.writeSessionBrief(id: session.id.uuidString, whereabouts: place)
        let managed = updater.isEnabled
        if managed, AgentLaunch.isAgent(session.launch.command) { updater.updateIfStale() }
        session.start(contextPath: contextPath, briefPath: paths.briefPath,
                      codexValuePath: paths.codexValuePath, cliUpdatesManaged: managed)
    }

    /// Sessions whose process has started.
    var startedSessions: [AgentTerminalSession] { sessions.filter(\.isStarted) }
    /// Whether any session is the person's own rather than a repository's row.
    var hasOwnSessions: Bool { sessions.contains { $0.repoDirectory == nil } }

    /// Split the panel: the right pane gets a new session like the selected one.
    func toggleSplit() {
        if splitId != nil {
            splitId = nil
            return
        }
        let base = selected?.launch ?? defaultLaunch
        let current = selectedId
        let section = selected?.section ?? "Sessions"
        let session = open(base, focus: false)
        session.section = section
        splitId = session.id
        selectedId = current
    }

    /// Close a session. A repository's row that is running stops and stays
    /// in the list, ready to start again; one that is not running is taken
    /// out of the list and of the Repos workspace.
    func close(_ id: AgentTerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let keepsRow = session.isStarted && session.repoDirectory.map(baselineDirectories.contains) == true
        session.terminate()
        brief.removeSessionBrief(id: id.uuidString)
        if keepsRow, let directory = session.repoDirectory {
            var launch = session.launch
            if session.followsDefault { launch.command = "" }
            let fresh = makeSession(launch, label: session.label, repoDirectory: directory,
                                    followsDefault: session.followsDefault)
            fresh.customTitle = session.customTitle
            fresh.section = session.section
            fresh.pinned = session.pinned
            sessions[index] = fresh
        } else {
            sessions.remove(at: index)
            if session.repoDirectory != nil { persistBaselineRows() }
        }
        if splitId == id { splitId = nil }
        if selectedId == id {
            // The nearest running session, never a row that would start.
            let running = sessions.enumerated().filter { $0.element.isStarted && $0.element.id != splitId }
            let after = running.first { $0.offset >= index } ?? running.last
            selectedId = after?.element.id
            selected?.wantsFocus = true
        }
        if startedSessions.isEmpty { isVisible = false }
    }

    func select(_ id: AgentTerminalSession.ID, focus: Bool = true) {
        if id == splitId { splitId = selectedId }
        selectedId = id
        if focus { selected?.wantsFocus = true }
        isVisible = true
    }

    /// Whether the panel is on screen (the strip shows otherwise).
    var isShowing: Bool { isVisible && !sessions.isEmpty }

    /// Show the panel, starting a session if there is none, and give the
    /// terminal the keyboard.
    func show(defaultLaunch: AgentLaunch) {
        if selected == nil {
            open(defaultLaunch)
        } else {
            isVisible = true
            selected?.wantsFocus = true
        }
    }

    /// Show the panel in the mode it was last used in: split or full window.
    func expand(defaultLaunch: AgentLaunch) {
        let fullWindow = lastUsedFullWindow
        show(defaultLaunch: defaultLaunch)
        isMaximized = fullWindow
    }

    /// Hide the panel into the strip; the keyboard goes back to the content.
    func hide() {
        isVisible = false
    }

    /// What had the keyboard when the panel opened, to hand it back on close.
    private weak var contentResponder: NSResponder?

    private func rememberContentFocus() {
        guard let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder,
              !(responder is FleetMateTerminalView) else { return }
        contentResponder = responder
    }

    /// If a terminal has the keyboard, hand it back to whatever had it
    /// before the panel opened, else to the window, so typing never goes to
    /// a hidden pane.
    private func returnFocusToContent() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              window.firstResponder is FleetMateTerminalView else { return }
        if let previous = contentResponder, (previous as? NSView)?.window === window {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    // MARK: Text size

    /// The terminal's text follows the app's text size (Settings ›
    /// Appearance, View › Zoom), plus the terminal's own ⌘+ / ⌘- steps.
    static let baseFontSize: CGFloat = 12
    static let fontSizeRange: ClosedRange<CGFloat> = 8...36
    /// Points added to the scaled base by View › Zoom while a terminal has
    /// the keyboard.
    @Published private(set) var fontOffset: CGFloat =
        CGFloat(UserDefaults.standard.double(forKey: AgentSettingsKey.fontOffset)) {
        didSet {
            UserDefaults.standard.set(Double(fontOffset), forKey: AgentSettingsKey.fontOffset)
            applyFont()
        }
    }

    /// The size every session draws at now.
    var fontSize: CGFloat {
        let scale = UserDefaults.standard.object(forKey: AppFontScale.storageKey) as? Double ?? AppFontScale.default
        let base = (Self.baseFontSize * CGFloat(AppFontScale.clamp(scale))).rounded()
        return min(max(base + fontOffset, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    /// Whether a terminal session has the keyboard in the key window.
    var hasKeyboardFocus: Bool {
        isShowing && NSApp.keyWindow?.firstResponder is FleetMateTerminalView
    }

    func adjustFont(by points: CGFloat) {
        let target = fontSize + points
        guard Self.fontSizeRange.contains(target) else { return }
        fontOffset += points
    }

    func resetFont() { fontOffset = 0 }

    private var appliedFontSize: CGFloat = 0

    /// Redraw every session at `fontSize`. SwiftTerm re-lays out the grid
    /// and tells the program the new size; nothing restarts.
    func applyFont() {
        let size = fontSize
        guard size != appliedFontSize else { return }
        appliedFontSize = size
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        for session in sessions { session.view.font = font }
    }

    func toggle(defaultLaunch: AgentLaunch) {
        if isShowing { hide() } else { expand(defaultLaunch: defaultLaunch) }
    }

    /// Put `text` into an agent's input without pressing Return, showing the
    /// panel and focusing that session. Only a session whose foreground
    /// process is an agent CLI with bracketed paste on receives it, never a
    /// bare shell. Returns false when no agent is running; the caller copies
    /// the text instead, so nothing is ever sent on the person's behalf.
    @discardableResult
    func insert(_ text: String) -> Bool {
        let candidates = [selected].compactMap { $0 } + sessions.filter { $0.id != selectedId }
        guard let session = candidates.first(where: { $0.agentIsForeground && $0.view.acceptsBracketedPaste }) else {
            return false
        }
        select(session.id)
        session.view.pasteText(text)
        return true
    }

    func move(_ session: AgentTerminalSession, to section: String) {
        guard sections.contains(section) else { return }
        objectWillChange.send()
        session.section = section
        if session.repoDirectory != nil { persistBaselineRows() }
    }

    /// Name a session; empty goes back to the automatic name.
    func rename(_ session: AgentTerminalSession, to name: String) {
        session.customTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.repoDirectory != nil { persistBaselineRows() }
    }

    func setPinned(_ session: AgentTerminalSession, _ pinned: Bool) {
        objectWillChange.send()
        session.pinned = pinned
        if session.repoDirectory != nil { persistBaselineRows() }
    }

    func toggleCollapsed(_ section: String) {
        if collapsedSections.insert(section).inserted == false { collapsedSections.remove(section) }
        if sessions.contains(where: { $0.section == section && $0.repoDirectory != nil }) { persistBaselineRows() }
    }

    func addSection(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sections.contains(name) else { return }
        sections.append(name)
    }

    func renameSection(_ old: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, !sections.contains(name),
              let index = sections.firstIndex(of: old) else { return }
        sections[index] = name
        if collapsedSections.remove(old) != nil { collapsedSections.insert(name) }
        for session in sessions where session.section == old { session.section = name }
        persistBaselineRows()
    }

    func removeSection(_ name: String) {
        guard name != "Sessions" else { return }
        for session in sessions where session.section == name { session.section = "Sessions" }
        sections.removeAll { $0 == name }
        collapsedSections.remove(name)
        persistBaselineRows()
    }

    // MARK: - Reordering

    /// Move a section up or down the list.
    func moveSection(_ name: String, by offset: Int) {
        guard let index = sections.firstIndex(of: name) else { return }
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        sections.swapAt(index, target)
        persistBaselineRows()
    }

    /// Drop a session on another: it takes that one's place and section.
    /// With no target it goes to the end of `section`.
    func moveSession(_ id: AgentTerminalSession.ID, before target: AgentTerminalSession.ID?, in section: String) {
        guard id != target, sections.contains(section),
              let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: from)
        session.section = section
        if let target, let to = sessions.firstIndex(where: { $0.id == target }) {
            sessions.insert(session, at: to)
        } else if let last = sessions.lastIndex(where: { $0.section == section }) {
            sessions.insert(session, at: last + 1)
        } else {
            sessions.append(session)
        }
        if session.repoDirectory != nil { persistBaselineRows() }
    }

    // MARK: - Saved workspaces

    /// The saved workspaces, read from the file again whenever a menu opens
    /// so hand edits apply without a relaunch.
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

    /// The sessions open now, by section, as a workspace named `name`. A
    /// session keeps its name only when the person gave it one, so the rest
    /// follow their program's title next time.
    func snapshot(named name: String) -> TerminalWorkspace {
        let sections = sections.map { section in
            TerminalWorkspace.Section(
                name: section,
                collapsed: collapsedSections.contains(section) ? true : nil,
                sessions: sessions.filter { $0.section == section }.map { session in
                    let custom = session.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    return TerminalWorkspace.Session(
                        name: custom.isEmpty ? nil : custom,
                        command: session.launch.command,
                        directory: TerminalWorkspaceStore.abbreviate(session.directory))
                })
        }
        return TerminalWorkspace(name: name, show: true, fullWindow: isMaximized && isVisible ? true : nil, sections: sections)
    }

    /// Save the open sessions as `name`, replacing a workspace of that name.
    func saveWorkspace(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let workspace = snapshot(named: name)
        writeWorkspaces { $0.upsert(workspace) }
    }

    func deleteWorkspace(named name: String) {
        writeWorkspaces { $0.remove(named: name) }
    }

    /// Name the workspace to open when FleetMate starts, or none.
    func setOpenAtLaunch(_ name: String?) {
        writeWorkspaces { $0.openAtLaunch = name }
    }

    /// Open a workspace's sessions beside any already open. A session already
    /// open with the same name, command and folder is not opened twice, so
    /// opening a workspace again only fills in what was closed.
    /// Show the Repos tab, where a repository is cloned. Set by AppState.
    var showRepos: (() -> Void)?
    /// The View menu asked to save the open sessions; the session list asks for the name.
    @Published var savingWorkspaceRequested = false
    /// The session list collapsed to its status dots; nil follows the
    /// number of sessions until toggled.
    @Published var listCollapsedOverride: Bool?

    /// The registry's checkouts the Repos tab knows and shows, with their
    /// activity, and the roots the session rows' breadcrumbs start below.
    private func repoCheckouts() -> [TerminalWorkspaceBaseline.Checkout] {
        let store = RepoRegistryStore()
        guard let document = try? store.load() else { return [] }
        breadcrumbRoots = Array(Set(document.settings.scanRoots + [document.settings.cloneRoot]))
        return TerminalWorkspaceBaseline.checkouts(
            from: document, excluding: TerminalWorkspaceBaseline.hiddenRepoIds(registryPath: store.registryPath))
    }

    /// Where session rows' breadcrumbs start: the repository roots from
    /// Settings › Repositories.
    private(set) var breadcrumbRoots: [String] = [] {
        didSet { for session in sessions { session.breadcrumbRoots = breadcrumbRoots } }
    }

    /// The folders of the Repos workspace's sessions, as compared.
    private var baselineDirectories: Set<String> {
        Set((workspaceFile.baseline?.sections ?? []).flatMap(\.sessions).compactMap(\.directory)
            .map(TerminalWorkspaceBaseline.normalized))
    }

    /// Keep the Repos workspace in step with the tracked repositories and
    /// show it in the session list: one section per host, one row per
    /// repository, each starting in its folder the first time it is chosen.
    /// Runs at launch, when FleetMate comes forward and when the registry
    /// changes. Edits the person made to the workspace stay.
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

    /// Add a row for every Repos workspace session not in the list yet and
    /// take out rows, not yet started, whose session left the workspace.
    private func applyBaselineToList() {
        let baseline = workspaceFile.baseline
        let wanted = baselineDirectories
        sessions.removeAll { session in
            guard let directory = session.repoDirectory, !session.isStarted, !wanted.contains(directory) else { return false }
            session.terminate()
            return true
        }
        for section in baseline?.sections ?? [] {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if !sections.contains(name) {
                sections.append(name)
                if section.collapsed == true { collapsedSections.insert(name) }
            }
            for entry in section.sessions {
                guard let directory = entry.directory else { continue }
                let key = TerminalWorkspaceBaseline.normalized(directory)
                guard !sessions.contains(where: { $0.repoDirectory == key }) else { continue }
                // No command of its own: it runs the default when it starts.
                let session = makeSession(AgentLaunch(command: entry.command ?? "",
                                                      directory: TerminalWorkspaceStore.expand(directory)),
                                          label: entry.label, repoDirectory: key,
                                          followsDefault: entry.command == nil)
                session.customTitle = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                session.pinned = entry.pinned == true
                session.resume = entry.resume == true
                session.section = name
                insertInSection(session)
            }
        }
    }

    private func insertInSection(_ session: AgentTerminalSession) {
        if let last = sessions.lastIndex(where: { $0.section == session.section }) {
            sessions.insert(session, at: last + 1)
        } else {
            sessions.append(session)
        }
    }

    /// Write the list's repository rows back to the Repos workspace: their
    /// names, pins, sections and order, and the absence of removed rows, so
    /// the next sync keeps what the person arranged.
    private func persistBaselineRows() {
        guard workspaceFile.baselineIndex != nil else { return }
        let rows = sessions.filter { $0.repoDirectory != nil }
        let sectionOrder = sections
        let collapsed = collapsedSections
        writeWorkspaces { file in
            guard let index = file.baselineIndex else { return }
            var workspace = file.workspaces[index]
            var entries: [String: TerminalWorkspace.Session] = [:]
            for entry in workspace.sections.flatMap(\.sessions) {
                guard let directory = entry.directory else { continue }
                entries[TerminalWorkspaceBaseline.normalized(directory)] = entries[TerminalWorkspaceBaseline.normalized(directory)] ?? entry
            }
            var rebuilt: [TerminalWorkspace.Section] = []
            for name in sectionOrder {
                let fromRows: [TerminalWorkspace.Session] = rows.filter { $0.section == name }.compactMap { row in
                    guard let key = row.repoDirectory, var entry = entries[key] else { return nil }
                    let custom = row.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry.name = custom.isEmpty ? nil : custom
                    entry.pinned = row.pinned ? true : nil
                    return entry
                }
                // Sessions written by hand with no folder are kept where they were.
                let unlisted = workspace.sections.first { $0.name == name }?.sessions.filter { $0.directory == nil } ?? []
                guard !fromRows.isEmpty || !unlisted.isEmpty else { continue }
                rebuilt.append(.init(name: name, collapsed: collapsed.contains(name) ? true : nil,
                                     sessions: fromRows + unlisted))
            }
            workspace.sections = rebuilt
            file.workspaces[index] = workspace
        }
    }

    private var registryWatch: Timer?
    private var registryModified: Date?

    /// Sync again whenever the repository registry changes, so tracking,
    /// hiding or cloning a repository shows in the list within seconds.
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

    /// Whether any repository is checked out, for the empty Workspaces menu.
    var hasRepoCheckouts: Bool { !repoCheckouts().isEmpty }

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
        // Rows the rebuild re-labelled or moved start over from the file.
        sessions.removeAll { session in
            guard session.repoDirectory != nil, !session.isStarted else { return false }
            session.terminate()
            return true
        }
        applyBaselineToList()
    }

    /// Add checkouts the Repos workspace lacks, keeping every edit to it,
    /// including those the person removed before.
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

    // MARK: Restore at relaunch

    /// Put the sessions open when FleetMate last quit back in the list,
    /// waiting to start, with agents set to resume their conversation.
    func restoreLastSessions() {
        guard !AppEdition.current.isTicketsOnly, restoresSessions, !restored,
              let restore = workspaceFile.restore else { return }
        restored = true
        var first: AgentTerminalSession?
        defer {
            // ⌃` brings the first one back, resuming, rather than a new session.
            if selectedId == nil, let first { selectedId = first.id }
        }
        for section in restore.sections {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for entry in section.sessions {
                let command = entry.command ?? ""
                let directory = entry.directory.map { TerminalWorkspaceStore.expand($0) }
                // A repository's row: it resumes when next chosen. One that
                // follows the default resumes whatever the default is then.
                if let directory, let row = sessions.first(where: {
                    $0.repoDirectory == TerminalWorkspaceBaseline.normalized(directory)
                        && ($0.followsDefault || $0.launch.command == command)
                }) {
                    row.resume = entry.resume == true
                    continue
                }
                addSection(name)
                let session = makeSession(AgentLaunch(command: command, directory: directory), label: entry.label)
                session.customTitle = entry.name ?? ""
                session.pinned = entry.pinned == true
                session.resume = entry.resume == true
                session.section = name
                insertInSection(session)
                if first == nil { first = session }
            }
        }
    }

    private var restored = false

    /// Reopen sessions at launch (Settings › Agent). Default on.
    var restoresSessions: Bool {
        UserDefaults.standard.object(forKey: AgentSettingsKey.restoreSessions) as? Bool ?? true
    }

    /// Record the running sessions for the next launch: the person's own in
    /// their sections, and repository rows that were started, so they resume.
    private func saveRestore() {
        guard !AppEdition.current.isTicketsOnly, restoresSessions else { return }
        let running = sessions.filter { $0.isStarted && $0.activity != .exited }
        let names = sections.filter { name in running.contains { $0.section == name } }
        let restore = TerminalWorkspace(name: "Last Sessions", sections: names.map { name in
            TerminalWorkspace.Section(name: name, sessions: running.filter { $0.section == name }.map { session in
                let custom = session.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let isRow = session.repoDirectory != nil
                return TerminalWorkspace.Session(
                    name: custom.isEmpty ? nil : custom,
                    command: session.launch.command,
                    // A row is found again by its folder; the person's own
                    // sessions reopen where they last were.
                    directory: TerminalWorkspaceStore.abbreviate(isRow ? (session.launch.directory ?? session.directory)
                                                                        : session.directory),
                    pinned: session.pinned ? true : nil,
                    resume: AgentResume.command(session.launch.command) != nil ? true : nil)
            })
        })
        writeWorkspaces { $0.restore = restore.sections.isEmpty ? nil : restore }
    }

    func open(workspace: TerminalWorkspace, show: Bool? = nil) {
        let selectedBefore = selectedId
        var first: AgentTerminalSession?
        for section in workspace.sections {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            addSection(name)
            if section.collapsed == true { collapsedSections.insert(name) } else { collapsedSections.remove(name) }
            for entry in section.sessions {
                // In the Repos workspace a session with no command runs the default.
                let command = entry.command
                    ?? (workspace.source == TerminalWorkspaceBaseline.source ? defaultLaunch.command : "")
                let directory = entry.directory.map { TerminalWorkspaceStore.expand($0) }
                let title = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let alreadyOpen = sessions.contains { session in
                    (session.followsDefault && !session.isStarted ? defaultLaunch.command : session.launch.command) == command
                        && session.customTitle == title
                        && (directory == nil || session.launch.directory.map { TerminalWorkspaceStore.expand($0) } == directory)
                }
                if alreadyOpen { continue }
                let session = open(AgentLaunch(command: command, directory: directory), focus: false, show: false)
                session.customTitle = title
                session.section = name
                if first == nil { first = session }
            }
        }
        // Everything was in the list already (the Repos workspace at launch):
        // leave it as it is rather than start a row nobody chose.
        if first == nil && show == nil { return }
        selectedId = first?.id ?? selectedBefore ?? startedSessions.first?.id ?? sessions.first?.id
        if show ?? workspace.show ?? true, !sessions.isEmpty {
            isVisible = true
            isMaximized = workspace.fullWindow ?? false
            selected?.wantsFocus = true
        }
    }

    func terminateAll() {
        saveRestore()
        sessions.forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: brief.sessionDirectory)
    }

    /// Step through the running sessions; rows waiting to start are skipped,
    /// so cycling never starts twenty agents on the way past.
    private func cycle(by offset: Int) {
        let running = startedSessions
        guard !running.isEmpty else { return }
        let index = running.firstIndex { $0.id == selectedId } ?? 0
        let next = (index + offset + running.count) % running.count
        select(running[next].id)
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
        case .togglePanel: hide()

        }
    }

    private func updateShown() {
        for session in sessions {
            session.isShown = isVisible && (session.id == selectedId || session.id == splitId)
            if session.isShown { startIfNeeded(session) }
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
