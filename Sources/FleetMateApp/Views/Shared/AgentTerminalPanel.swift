import SwiftUI
import SwiftTerm

/// Hosts a session's terminal and hands it keyboard focus once it is
/// actually in a window — focus asked for before then is silently dropped.
private final class TerminalContainer: NSView {
    var session: AgentTerminalSession?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfWanted()
    }

    func focusIfWanted() {
        guard let session, session.wantsFocus, let window else { return }
        // Deferred: this runs inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async {
            session.wantsFocus = false
            window.makeFirstResponder(session.view)
        }
    }
}

/// The terminal drawn by a session, hosted in SwiftUI. The session owns the
/// view, so the same NSView is re-hosted when the panel reappears.
private struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: AgentTerminalSession

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        if session.view.superview !== container { attach(to: container) }
        container.focusIfWanted()
    }

    private func attach(to container: TerminalContainer) {
        container.session = session
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.focusIfWanted()
    }
}

/// The bottom panel every tab shares. Sessions are a list down the left —
/// name, folder and state on each row — rather than tabs, because ten or
/// fifteen tabs leave nothing readable. With one session the list is docked to
/// its status dot; from two it shows names, unless toggled by hand.
struct AgentTerminalPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AgentTerminalStore
    let repos: [String]
    let defaultLaunch: AgentLaunch
    /// A hand toggle, kept until the number of sessions changes.
    @State private var listOverride: Bool?

    private var listCollapsed: Bool { listOverride ?? (store.sessions.count < 2) }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: listCollapsed ? 34 : 250)
            Divider()
            HStack(spacing: 0) {
                if let session = store.selected {
                    pane(session)
                }
                if let split = store.split {
                    Divider()
                    pane(split)
                }
            }
        }
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .onChange(of: store.sessions.count) { _, _ in listOverride = nil }
    }

    private func pane(_ session: AgentTerminalSession) -> some View {
        TerminalHost(session: session)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !listCollapsed {
                    Text("Sessions").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    Text("\(store.sessions.count)").appFont(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    newSessionMenu
                    Button(action: store.toggleSplit) {
                        Label("Split", systemImage: store.splitId == nil ? "rectangle.split.2x1" : "rectangle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(store.splitId == nil ? "Split (⌘D)" : "Unsplit (⌘D)")
                }
                Button(action: { listOverride = !listCollapsed }) {
                    Label("Collapse", systemImage: listCollapsed ? "sidebar.left" : "sidebar.squares.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(listCollapsed ? "Show session names" : "Collapse the session list")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if listCollapsed {
                // Docked: the header has room only for its toggle, so the
                // controls a single session still needs stack under it.
                VStack(spacing: 8) {
                    newSessionMenu
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
                .padding(.bottom, 6)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(session: session,
                                   index: index,
                                   collapsed: listCollapsed,
                                   isSelected: session.id == store.selectedId,
                                   isSplit: session.id == store.splitId,
                                   select: { store.select(session.id) },
                                   close: { store.close(session.id) })
                    }
                }
                .padding(4)
            }
        }
        .background(SwiftUI.Color.secondary.opacity(0.05))
    }

    private var newSessionMenu: some View {
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
            Label("New Session", systemImage: "plus").labelStyle(.iconOnly)
        } primaryAction: {
            store.open(defaultLaunch)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("New session (⌘T), or choose what it runs")
    }
}

private struct SessionRow: View {
    @ObservedObject var session: AgentTerminalSession
    let index: Int
    let collapsed: Bool
    let isSelected: Bool
    let isSplit: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .appFont(fixed: 11.5, weight: isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    Text(session.shortDirectory)
                        .appFont(fixed: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 2)
                if hovered {
                    Button(action: close) {
                        Image(systemName: "xmark").appFont(fixed: 9)
                    }
                    .buttonStyle(.borderless)
                    .help("Close session (⌘W)")
                } else if index < 9 {
                    Text("⌘\(index + 1)").appFont(fixed: 9).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .help("\(session.title)\n\(session.shortDirectory)")
    }

    private var rowBackground: SwiftUI.Color {
        if isSelected { return SwiftUI.Color.accentColor.opacity(0.18) }
        if isSplit { return SwiftUI.Color.accentColor.opacity(0.08) }
        return hovered ? SwiftUI.Color.secondary.opacity(0.08) : .clear
    }

    /// Green while output streams, orange when a session out of sight rang
    /// its bell (an agent waiting on you), grey when idle or ended.
    private var statusDot: some View {
        let color: SwiftUI.Color
        switch session.activity {
        case .busy: color = .green
        case .attention: color = .orange
        case .idle: color = .secondary.opacity(0.5)
        case .exited: color = .secondary.opacity(0.2)
        }
        return Circle().fill(color).frame(width: 7, height: 7).frame(width: 12)
    }
}
