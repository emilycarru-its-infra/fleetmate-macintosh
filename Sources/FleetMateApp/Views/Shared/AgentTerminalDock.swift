import SwiftUI
import AppKit
import AgentsMate
import FleetMateCore

/// The terminal under the tab: AgentsMate's dock, with FleetMate's new
/// session and workspaces menus in its list header. Drag the divider to
/// resize, to the bottom or double-click it to hide, near the top to fill
/// the window. The toolbar's Agent button, ⌘J and ⌃` bring it back in its
/// last mode.
struct AgentTerminalDock: View {
    @ObservedObject var store: AgentTerminalStore
    let repos: [String]
    let defaultLaunch: AgentLaunch
    @State private var savingWorkspace = false
    @State private var workspaceName = ""

    var body: some View {
        AgentLaneDock(store: store.lanes, labels: AgentTerminalStore.labels) {
            HStack(spacing: 2) {
                newSessionMenu
                workspacesMenu
            }
        } empty: {
            emptyState
        }
        .alert("Save Sessions as Workspace", isPresented: $savingWorkspace) {
            TextField("Name", text: $workspaceName)
            Button("Save") { store.saveWorkspace(named: workspaceName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A workspace with the same name is replaced.")
        }
        // View › Save Sessions as Workspace… asks here.
        .onChange(of: store.savingWorkspaceRequested) { _, requested in
            guard requested else { return }
            store.savingWorkspaceRequested = false
            workspaceName = ""
            savingWorkspace = true
        }
    }

    /// Show the terminal at half the window's height.
    static func splitView(_ store: AgentTerminalStore, defaultLaunch: AgentLaunch) {
        store.show(defaultLaunch: defaultLaunch)
        store.isMaximized = false
        let available = NSApp.keyWindow?.contentLayoutRect.height ?? 800
        UserDefaults.standard.set(max(120, (available - 36) / 2), forKey: store.lanes.keys.dockHeight)
    }

    /// A plus that starts the default session, and beside it a chevron, always
    /// shown, for choosing what the session runs. A Menu's own indicator only
    /// appears on hover in the window's list header.
    private var newSessionMenu: some View {
        HStack(spacing: 0) {
            Button {
                store.open(defaultLaunch)
            } label: {
                Label("New Session", systemImage: "plus").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("New session (⌘T)")
            Menu {
                Button("New \(defaultLaunch.label)") { store.open(defaultLaunch) }
                Divider()
                ForEach(AgentLaunch.installedPresets, id: \.command) { preset in
                    Button(preset.label) { store.open(AgentLaunch(command: preset.command)) }
                }
                if !repos.isEmpty {
                    Divider()
                    Section("Open in repository") {
                        ForEach(repos, id: \.self) { repo in
                            Button((repo as NSString).lastPathComponent) {
                                store.open(AgentLaunch(command: defaultLaunch.command, directory: repo))
                            }
                        }
                    }
                }
            } label: {
                Label("Choose What the Session Runs", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose what the new session runs")
        }
    }

    private var workspacesMenu: some View {
        Menu {
            AgentWorkspaceMenuContent(store: store) { workspaceName = ""; savingWorkspace = true }
        } label: {
            Label("Workspaces", systemImage: "square.stack").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear(perform: store.reloadWorkspaces)
        .help("Open, save and manage terminal workspaces")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "terminal")
        } description: {
            Text("Start a session, or clone a repository to get a row for it.")
        } actions: {
            Button("New Session") { store.open(defaultLaunch) }
            if !store.hasRepoCheckouts { Button("Clone a Repository in Repos…") { store.showRepos?() } }
        }
    }

    static func openWorkspacesFile(reveal: Bool) {
        let path = TerminalWorkspaceStore.defaultPath
        if !FileManager.default.fileExists(atPath: path) {
            try? TerminalWorkspaceStore.save(TerminalWorkspaceFile(), to: path)
        }
        let url = URL(fileURLWithPath: path)
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // JSON may have no default app; TextEdit always opens it.
            let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            if let editor {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}

/// The workspaces menu: the file's saved workspaces, the Repos workspace,
/// and the file itself.
struct AgentWorkspaceMenuContent: View {
    @ObservedObject var store: AgentTerminalStore
    let saveSessions: () -> Void

    var body: some View {
        let file = store.workspaceFile
        if file.workspaces.isEmpty {
            Text("No Saved Workspaces")
            if store.hasRepoCheckouts {
                Button("Create Workspace from Repos") { store.regenerateBaselineWorkspace() }
            } else {
                Button("Clone a Repository in Repos…") { store.showRepos?() }
            }
        } else {
            Section("Open Workspace") {
                ForEach(file.workspaces, id: \.name) { workspace in
                    Button("\(workspace.name) — \(workspace.sessionCount == 1 ? "1 session" : "\(workspace.sessionCount) sessions")") {
                        store.open(workspace: workspace, show: true)
                    }
                }
            }
        }
        Divider()
        Button("Save Sessions as Workspace…", action: saveSessions)
            .disabled(store.lanes.lanes.isEmpty)
        if !file.workspaces.isEmpty {
            Picker("Open at Launch", selection: Binding(
                get: { file.launchWorkspace?.name ?? "" },
                set: { store.setOpenAtLaunch($0.isEmpty ? nil : $0) }
            )) {
                Text("None").tag("")
                ForEach(file.workspaces, id: \.name) { Text($0.name).tag($0.name) }
            }
            Menu("Delete Workspace") {
                ForEach(file.workspaces, id: \.name) { workspace in
                    Button(workspace.name) { store.deleteWorkspace(named: workspace.name) }
                }
            }
        }
        Divider()
        Button("Add Missing Repos") { store.addMissingReposToBaseline() }
        Button("Regenerate Repos Workspace") { store.regenerateBaselineWorkspace() }
        Divider()
        Button("Edit Workspaces File") { AgentTerminalDock.openWorkspacesFile(reveal: false) }
        Button("Show Workspaces File in Finder") { AgentTerminalDock.openWorkspacesFile(reveal: true) }
        if let error = store.workspaceFileError { Text(error) }
    }
}

/// View › Show/Hide Agent (⌘J), titled by what it will do. ⌃` does the
/// same from the toolbar control and from inside a terminal.
struct AgentTerminalMenuItems: View {
    @ObservedObject var terminals: AgentTerminalStore
    let defaultLaunch: () -> AgentLaunch

    var body: some View {
        Button {
            if terminals.isShowing {
                terminals.hide()
            } else {
                terminals.expand(defaultLaunch: defaultLaunch())
            }
        } label: {
            Label(terminals.isShowing ? "Hide Agent" : "Show Agent",
                  systemImage: ContentView.agentSymbol)
        }
        .keyboardShortcut("j", modifiers: .command)
    }
}

/// View › Terminal Workspaces: the same menu as the session list's. Saving
/// opens the terminal so the session list can ask for the name.
struct AgentWorkspaceMenuItems: View {
    @ObservedObject var terminals: AgentTerminalStore

    var body: some View {
        Menu("Terminal Workspaces") {
            AgentWorkspaceMenuContent(store: terminals) {
                terminals.lanes.showDock()
                terminals.savingWorkspaceRequested = true
            }
        }
        .onAppear(perform: terminals.reloadWorkspaces)
    }
}
