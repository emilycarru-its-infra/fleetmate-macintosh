import SwiftUI
import AppKit

/// The bottom of the window: the Agent Terminal when it is open, above a slim
/// bar that stays on the window's edge either way and holds the show, hide
/// and full-window controls. The two behave as one split: drag the divider down to the
/// bottom and the terminal folds into the strip, drag the strip up (or click
/// it) and it opens at the height it had. Double-clicking the divider closes
/// it. ⌃` and View › Show/Hide Agent Terminal do the same from anywhere.
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
    /// Released below this, the panel closes into the strip.
    static let snapHeight: Double = 80

    var body: some View {
        VStack(spacing: 0) {
            if store.isShowing {
                // Filling the window, there is nothing above to resize against.
                if !store.isMaximized { divider }
                AgentTerminalPanel(store: store, repos: repos, defaultLaunch: defaultLaunch)
                    .frame(height: store.isMaximized ? nil : CGFloat(liveHeight ?? panelHeight))
                    .frame(maxHeight: store.isMaximized ? .infinity : nil)
            }
            AgentTerminalStrip(store: store, defaultLaunch: defaultLaunch)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
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

/// The bar on the window's bottom edge: the agent, the sessions, and the
/// controls to show, hide or fill the window with the terminal. Plain text
/// throughout; nothing here is a badge.
struct AgentTerminalStrip: View {
    @ObservedObject var store: AgentTerminalStore
    let defaultLaunch: AgentLaunch
    @State private var hovered = false

    static let height: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: ContentView.agentSymbol)
                    .foregroundStyle(.secondary)
                Text("Agent").appFont(.caption, weight: .semibold)
                Text(defaultLaunch.label).appFont(.caption).foregroundStyle(.secondary)
                // Session activity changes without the store publishing, so
                // read it on a slow tick rather than re-rendering the window.
                TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                    Text(status).appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: toggleFullWindow) {
                    Label(isFullWindow ? "Restore" : "Full Window",
                          systemImage: isFullWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isFullWindow ? "Restore the terminal to its height (⇧⌘↩)" : "Fill the window with the terminal (⇧⌘↩)")
                Button(action: toggleShown) {
                    Label(store.isShowing ? "Hide Agent Terminal" : "Show Agent Terminal",
                          systemImage: store.isShowing ? "chevron.down" : "chevron.up")
                }
                .help(store.isShowing ? "Hide the Agent Terminal (⌃`)" : "Show the Agent Terminal (⌃`)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: Self.height - 1)
        }
        .background(hovered && !store.isShowing ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if !store.isShowing { store.show(defaultLaunch: defaultLaunch) } }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onEnded { value in
                    if value.translation.height < -8, !store.isShowing {
                        store.show(defaultLaunch: defaultLaunch)
                    } else if value.translation.height > 8, store.isShowing {
                        store.hide()
                    }
                }
        )
        .help(store.isShowing ? "" : "Show the Agent Terminal (⌃`) — click or drag up")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Terminal, \(status)")
    }

    private var isFullWindow: Bool { store.isShowing && store.isMaximized }

    private func toggleShown() {
        if store.isShowing { store.hide() } else { store.show(defaultLaunch: defaultLaunch) }
    }

    private func toggleFullWindow() {
        if isFullWindow {
            store.isMaximized = false
        } else {
            store.show(defaultLaunch: defaultLaunch)
            store.isMaximized = true
        }
    }

    private var status: String {
        let sessions = store.sessions
        guard !sessions.isEmpty else { return "No sessions" }
        var text = sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
        if sessions.contains(where: { $0.activity == .attention }) {
            text += " · waiting for you"
        } else if sessions.contains(where: { $0.activity == .busy }) {
            text += " · working"
        }
        return text
    }
}

/// View › Show/Hide Agent Terminal, titled by what it will do.
struct AgentTerminalMenuItems: View {
    @ObservedObject var terminals: AgentTerminalStore
    let defaultLaunch: () -> AgentLaunch

    var body: some View {
        Button {
            if terminals.isShowing {
                terminals.hide()
            } else {
                terminals.show(defaultLaunch: defaultLaunch())
            }
        } label: {
            Label(terminals.isShowing ? "Hide Agent Terminal" : "Show Agent Terminal",
                  systemImage: ContentView.agentSymbol)
        }
        .keyboardShortcut("`", modifiers: .control)
    }
}
