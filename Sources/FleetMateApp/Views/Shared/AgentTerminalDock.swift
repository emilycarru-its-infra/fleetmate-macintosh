import SwiftUI
import AppKit

/// A persistent top-edge strip holds labeled visibility and size controls.
/// The terminal and strip behave as one split: drag the divider down to the
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
            AgentTerminalStrip(store: store, defaultLaunch: defaultLaunch)
            if store.isShowing {
                if !store.isMaximized { divider }
                AgentTerminalPanel(store: store, repos: repos, defaultLaunch: defaultLaunch)
                    .frame(height: store.isMaximized ? nil : CGFloat(liveHeight ?? panelHeight))
                    .frame(maxHeight: store.isMaximized ? .infinity : nil)
            }
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

/// The bar on the terminal's top edge: the agent, the sessions, and the
/// controls to show, hide or fill the window with the terminal. Plain text
/// throughout; nothing here is a badge.
struct AgentTerminalStrip: View {
    @ObservedObject var store: AgentTerminalStore
    let defaultLaunch: AgentLaunch
    @State private var hovered = false
    @AppStorage(AgentSettingsKey.panelHeight) private var panelHeight: Double = 280

    static let height: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                stripContent(details: true)
                stripContent(details: false)
            }
        }
        .background(hovered && !store.isShowing ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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

    private func stripContent(details: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ContentView.agentSymbol)
                .foregroundStyle(.secondary)
            if details { Text("Agent").appFont(.caption, weight: .semibold).fixedSize() }
            if details {
                Text(defaultLaunch.label).appFont(.caption).foregroundStyle(.secondary).fixedSize()
            }
            // Session activity changes without the store publishing, so
            // read it on a slow tick rather than re-rendering the window.
            if details {
                TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                    Text(status).appFont(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            Spacer(minLength: 8)
            Button(action: toggleShown) {
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 28, height: 4)
                    .frame(width: 36, height: 22)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(store.isShowing ? "Collapse terminal" : "Open terminal")
            .help("Click to show or hide the terminal; drag to open or close")
            Spacer(minLength: 8)
            Button("Split View") {
                store.show(defaultLaunch: defaultLaunch)
                store.isMaximized = false
                panelHeight = max(120, ((NSApp.keyWindow?.contentLayoutRect.height ?? 800) - 36) / 2)
            }
            .help("Show FleetMate and the terminal at half height")
            Button(action: toggleFullWindow) {
                Label(isFullWindow ? "Restore" : "Full Window",
                      systemImage: isFullWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(isFullWindow ? "Restore the terminal to its height (⇧⌘↩)" : "Fill the window with the terminal (⇧⌘↩)")
            Button(action: toggleShown) {
                Label(store.isShowing ? "Hide Terminal" : "Show Terminal",
                      systemImage: store.isShowing ? "chevron.down" : "chevron.up")
            }
            .help(store.isShowing ? "Hide the Agent Terminal (⌃`)" : "Show the Agent Terminal (⌃`)")
        }
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: Self.height - 1)
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
