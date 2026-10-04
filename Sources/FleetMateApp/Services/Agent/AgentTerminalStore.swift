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

/// One terminal: a pseudo-terminal running the session's command, with the
/// view that draws it. The view is created once and kept for the session's
/// life, so moving between tabs or hiding the panel never ends the process.
@MainActor
final class AgentTerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let launch: AgentLaunch
    let view: LocalProcessTerminalView
    @Published var title: String
    @Published private(set) var exited = false
    /// Take keyboard focus the next time the view is shown. Set for sessions
    /// the person opened; a session started at launch must not steal typing
    /// from whatever they are doing.
    var wantsFocus = false

    init(launch: AgentLaunch, contextPath: String) {
        self.launch = launch
        self.title = launch.label
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        start(contextPath: contextPath)
    }

    private func start(contextPath: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var args = ["-l"]
        let command = launch.command.trimmingCharacters(in: .whitespaces)
        if !command.isEmpty {
            // The remote wrappers take the folder to open as their argument.
            var line = command
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
        env["FLEETMATE_CONTEXT"] = contextPath
        let environment = env.map { "\($0.key)=\($0.value)" }

        let directory = launch.directory.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        view.startProcess(executable: shell, args: args, environment: environment,
                          execName: nil, currentDirectory: directory)
    }

    func terminate() {
        view.terminate()
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            if !title.isEmpty { self.title = title }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.exited = true }
    }
}

/// Every terminal session in the window, the panel's visibility, and the
/// split. Lives on AppState so it outlasts any tab.
@MainActor
final class AgentTerminalStore: ObservableObject {
    @Published private(set) var sessions: [AgentTerminalSession] = []
    @Published var selectedId: AgentTerminalSession.ID?
    /// The session shown in the right-hand pane when split.
    @Published var splitId: AgentTerminalSession.ID?
    @Published var isVisible = false

    let contextPath: String

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        contextPath = dir.appendingPathComponent("agent-context.json").path
    }

    var selected: AgentTerminalSession? { sessions.first { $0.id == selectedId } }
    var split: AgentTerminalSession? { sessions.first { $0.id == splitId } }

    @discardableResult
    func open(_ launch: AgentLaunch, focus: Bool = true) -> AgentTerminalSession {
        let session = AgentTerminalSession(launch: launch, contextPath: contextPath)
        session.wantsFocus = focus
        sessions.append(session)
        selectedId = session.id
        isVisible = true
        return session
    }

    /// Split the panel: the right pane gets a new session like the selected one.
    func toggleSplit() {
        if splitId != nil {
            splitId = nil
            return
        }
        let base = selected?.launch ?? .shell
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
            selectedId = sessions.last(where: { $0.id != splitId })?.id ?? sessions.last?.id
        }
        if sessions.isEmpty { isVisible = false }
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
}

/// UserDefaults keys for the person's own agent settings. Unset falls back to
/// the managed defaults in FleetMateConfig.
enum AgentSettingsKey {
    static let command = "agentCommand"
    static let autoStart = "agentAutoStart"
    static let repos = "agentRepos"
    static let panelHeight = "agentPanelHeight"
}
