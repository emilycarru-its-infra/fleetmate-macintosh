import SwiftUI
import AppKit

/// The terminal under the tab, split at a divider: drag it to resize, drag
/// it to the bottom or double-click it to hide the terminal, drag it to the
/// top to fill the window. Nothing shows while the terminal is hidden; the
/// toolbar's Agent button, ⌘J and ⌃` bring it back in its last mode. The
/// layout and hide controls are in the session list's header.
struct AgentTerminalDock: View {
    @ObservedObject var store: AgentTerminalStore
    let repos: [String]
    let defaultLaunch: AgentLaunch

    /// The open height, remembered across closes and launches.
    @AppStorage(AgentSettingsKey.panelHeight) private var panelHeight: Double = 280
    @State private var dragStart: Double?
    /// The height while the divider is being dragged, allowed below the
    /// minimum so the panel visibly shrinks toward the snap.
    @State private var liveHeight: Double?

    static let minimumHeight: Double = 120
    /// Released below this, the panel closes.
    static let snapHeight: Double = 80

    var body: some View {
        VStack(spacing: 0) {
            if store.isShowing {
                if !store.isMaximized { divider }
                AgentTerminalPanel(store: store, repos: repos, defaultLaunch: defaultLaunch)
                    .frame(height: store.isMaximized ? nil : CGFloat(liveHeight ?? panelHeight))
                    .frame(maxHeight: store.isMaximized ? .infinity : nil)
            }
        }
    }

    /// Show the terminal at half the window's height.
    static func splitView(_ store: AgentTerminalStore, defaultLaunch: AgentLaunch) {
        store.show(defaultLaunch: defaultLaunch)
        store.isMaximized = false
        let available = NSApp.keyWindow?.contentLayoutRect.height ?? 800
        UserDefaults.standard.set(max(minimumHeight, (available - 36) / 2), forKey: AgentSettingsKey.panelHeight)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                // Measured in window coordinates: the handle moves with the
                // panel, so local coordinates made the drag jitter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? panelHeight
                        dragStart = start
                        if store.isMaximized { store.isMaximized = false }
                        liveHeight = min(max(start - value.translation.height, 24), 1600)
                    }
                    .onEnded { value in
                        let start = dragStart ?? panelHeight
                        let height = start - value.translation.height
                        let available = NSApp.keyWindow?.contentLayoutRect.height ?? 900
                        if height < Self.snapHeight {
                            // Folded away: keep the height it had for next time.
                            store.hide()
                        } else if height > available * 0.85 {
                            // Nearly to the top: fill the window, and restore
                            // to the height it had before.
                            store.isMaximized = true
                        } else {
                            panelHeight = min(max(height, Self.minimumHeight), 1600)
                        }
                        liveHeight = nil
                        dragStart = nil
                    }
            )
            .onTapGesture(count: 2) { store.hide() }
            .help("Drag to resize; drag to the bottom or double-click to close (⌃`)")
            .accessibilityElement()
            .accessibilityLabel("Agent Terminal divider")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Hide Agent Terminal") { store.hide() }
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
                terminals.isVisible = true
                terminals.savingWorkspaceRequested = true
            }
        }
        .onAppear(perform: terminals.reloadWorkspaces)
    }
}

/// View › Show/Hide Session List, ⌃⌘S as in any Mac sidebar.
struct AgentSessionListMenuItem: View {
    @ObservedObject var terminals: AgentTerminalStore

    var body: some View {
        let collapsed = terminals.listCollapsedOverride ?? (terminals.sessions.count < 2)
        Button(collapsed ? "Show Terminal Session List" : "Hide Terminal Session List") {
            terminals.listCollapsedOverride = !collapsed
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
        .disabled(!terminals.isShowing)
    }
}

/// The toolbar's Agent control: the first item at the far left, filled with the
/// accent colour so it reads as the app's main action rather than one more
/// glyph. ⌘J (View › Show Agent) and ⌃` toggle it from anywhere; while the
/// terminal is open the icon becomes a check so the state is still visible.
struct AgentModeToolbarToggle: View {
    @ObservedObject var terminals: AgentTerminalStore
    let defaultLaunch: AgentLaunch

    var body: some View {
        Button {
            terminals.toggle(defaultLaunch: defaultLaunch)
        } label: {
            // The window toolbar strips bordered-prominent tint, so the
            // capsule is drawn here. Closed, it is accent-tinted glass that
            // calls for attention; open, it goes neutral and shows a check.
            Label("Agent", systemImage: terminals.isShowing ? "checkmark" : ContentView.agentSymbol)
                .labelStyle(.titleAndIcon)
                .font(.body.weight(.semibold))
                .foregroundStyle(terminals.isShowing ? Color.primary : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .modifier(AgentButtonSurface(active: terminals.isShowing))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("`", modifiers: .control)
        .help(terminals.isShowing ? "Hide the agent terminal (⌘J or ⌃`)" : "Work with the agent in the terminal (⌘J or ⌃`)")
        .accessibilityLabel("Agent")
        .accessibilityValue(terminals.isShowing ? "On" : "Off")
        .accessibilityAddTraits(terminals.isShowing ? .isSelected : [])
    }
}

/// Liquid Glass on macOS 26, a plain filled capsule before it.
private struct AgentButtonSurface: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                active ? .regular.interactive() : .regular.tint(.accentColor).interactive(),
                in: .capsule
            )
        } else {
            content.background(
                Capsule().fill(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
            )
        }
    }
}
