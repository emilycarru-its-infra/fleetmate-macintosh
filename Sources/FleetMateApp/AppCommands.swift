import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Command bus

/// An action a menu command asks the frontmost tab to perform.
///
/// Menu commands live in the `App` scene, which has no route into the state of
/// whichever tab view is on screen. Rather than hoist every view's `@State` up
/// to `AppState` just to reach it from a menu, commands are broadcast and the
/// visible tab picks up the ones it understands. Only one tab view exists at a
/// time (`ContentView.tabContent` switches wholesale), so there is no ambiguity
/// about who responds.
enum AppCommand: Equatable {
    case refresh
    case newItem
    case find
    case toggleFilters
    case clearFilters
    case showListView
    case showBoardView
    case scan
    case selectOnline
}

/// A command plus a unique token.
///
/// The token is what makes pressing ⌘R twice in a row register as two refreshes
/// — without it the published value would be unchanged the second time and
/// `onChange` would never fire.
struct AppCommandRequest: Equatable {
    let id = UUID()
    let command: AppCommand
}

private struct AppCommandReceiver: ViewModifier {
    @EnvironmentObject var appState: AppState
    let handler: (AppCommand) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: appState.pendingCommand) { _, request in
            guard let request else { return }
            handler(request.command)
        }
    }
}

extension View {
    /// Handle menu commands aimed at this tab. Ignore the ones that don't apply.
    func onAppCommand(_ handler: @escaping (AppCommand) -> Void) -> some View {
        modifier(AppCommandReceiver(handler: handler))
    }
}

// MARK: - Menus

struct FleetMateCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default

    /// The settings slider's own step, so the menu and the slider always land
    /// on the same values.
    private let zoomStep = AppFontScale.step

    private var selectedTab: AppTab { appState.selectedTab }

    private var enabledTabs: [AppTab] {
        AppTab.enabledTabs(config: appState.config)
    }

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Activity Log") { openWindow(id: ActivityLogView.windowId) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button(newItemTitle) { appState.perform(.newItem) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!canCreateInSelectedTab)
        }

        // Cut/Copy/Paste/Select All are already here — AppKit supplies them and
        // routes them down the responder chain. A hand-rolled Select All used to
        // sit alongside, giving the Edit menu two identical items.
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find") { appState.tabSearchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!hasSearchField)
            Button("Search Everything") { appState.globalSearchFocusRequest += 1 }
                .keyboardShortcut("k", modifiers: .command)
        }

        if !AppEdition.current.isTicketsOnly {
            CommandMenu("Manage") {
                Button("Scan Room") { appState.perform(.scan) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(selectedTab != .manage)
                Button("Select All Online") { appState.perform(.selectOnline) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(selectedTab != .manage)
            }
        }

        CommandGroup(before: .toolbar) {
            Button("Back") { appState.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!appState.canGoBack)
            Button("Forward") { appState.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!appState.canGoForward)

            Divider()

            ForEach(Array(AppTab.editionTabs().enumerated()), id: \.element.id) { index, tab in
                Button(tab.rawValue) { appState.selectedTab = tab }
                    .keyboardShortcut(tabShortcut(index), modifiers: .command)
                    .disabled(!tab.isEnabled(config: appState.config))
            }

            Divider()

            Button("Go to Next Tab") { cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Go to Previous Tab") { cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            Button("as List") { appState.perform(.showListView) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(!hasListAndBoard)
            Button("as Board") { appState.perform(.showBoardView) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(!hasListAndBoard)

            Divider()

            Button("Show Filters") { appState.perform(.toggleFilters) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!hasFilterPanel)
            Button("Clear Filters") { appState.perform(.clearFilters) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!hasFilters)

            Divider()

            Button("Refresh") { appState.perform(.refresh) }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            if !AppEdition.current.isTicketsOnly {
                Button("Toggle Terminal") {
                    appState.terminals.toggle(defaultLaunch: appState.agentDefaultLaunch)
                }
                .keyboardShortcut("`", modifiers: .control)
                Button("New Terminal Tab") { appState.terminals.open(appState.agentDefaultLaunch) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Terminal Full Window") {
                    let terminals = appState.terminals
                    if terminals.sessions.isEmpty { terminals.open(appState.agentDefaultLaunch) }
                    terminals.isVisible = true
                    terminals.isMaximized.toggle()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Divider()
            }

            Button("Zoom In") { setScale(fontScale + zoomStep) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(fontScale >= AppFontScale.range.upperBound)
            Button("Zoom Out") { setScale(fontScale - zoomStep) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontScale <= AppFontScale.range.lowerBound)
            Button("Actual Size") { fontScale = AppFontScale.default }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(abs(fontScale - AppFontScale.default) < 0.001)
        }
    }

    // MARK: Per-tab capability

    /// Name what ⌘N will actually make, so the File menu isn't a bare "New".
    private var newItemTitle: String {
        switch selectedTab {
        case .tickets:  "New Ticket…"
        case .projects: "New Work Item…"
        default:        "New"
        }
    }

    private var canCreateInSelectedTab: Bool {
        selectedTab == .tickets || selectedTab == .projects
    }

    /// Every tab has a search field — the Dashboard's is the global
    /// cross-system search in its header.
    private var hasSearchField: Bool { true }

    private var hasFilterPanel: Bool {
        [.devices, .inventory, .tickets].contains(selectedTab)
    }

    /// Projects has no filter popover but does have filters to clear.
    private var hasFilters: Bool {
        hasFilterPanel || selectedTab == .projects
    }

    private var hasListAndBoard: Bool {
        selectedTab == .tickets
    }

    // MARK: Actions

    private func tabShortcut(_ index: Int) -> KeyEquivalent {
        KeyEquivalent(Character("\(index + 1)"))
    }

    private func cycleTab(by offset: Int) {
        let tabs = enabledTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(of: selectedTab) ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        appState.selectedTab = tabs[next]
    }

    private func setScale(_ value: Double) {
        fontScale = AppFontScale.clamp((value / AppFontScale.step).rounded() * AppFontScale.step)
    }
}
