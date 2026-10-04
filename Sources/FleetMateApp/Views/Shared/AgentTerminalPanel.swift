import SwiftUI
import SwiftTerm

/// The terminal drawn by a session, hosted in SwiftUI. The session owns the
/// view, so the same NSView is re-hosted when the panel reappears.
private struct TerminalHost: NSViewRepresentable {
    let session: AgentTerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if session.wantsFocus {
            session.wantsFocus = false
            DispatchQueue.main.async { container.window?.makeFirstResponder(session.view) }
        }
    }
}

/// The bottom panel every tab shares: session tabs, a new-session menu that
/// knows the person's agent command and repositories, split and close.
struct AgentTerminalPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AgentTerminalStore
    let repos: [String]
    let defaultLaunch: AgentLaunch

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func pane(_ session: AgentTerminalSession) -> some View {
        TerminalHost(session: session)
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.sessions.filter { $0.id != store.splitId }) { session in
                        SessionTab(session: session,
                                   isSelected: session.id == store.selectedId,
                                   select: { store.selectedId = session.id },
                                   close: { store.close(session.id) })
                    }
                }
            }

            Spacer(minLength: 8)

            Menu {
                Button("New \(defaultLaunch.label)") { store.open(defaultLaunch) }
                Divider()
                ForEach(AgentLaunch.presets, id: \.command) { preset in
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
                Label("New Session", systemImage: "plus")
                    .labelStyle(.iconOnly)
            } primaryAction: {
                store.open(defaultLaunch)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New session (click) or choose what it runs")

            Button(action: store.toggleSplit) {
                Label("Split", systemImage: store.splitId == nil ? "rectangle.split.2x1" : "rectangle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(store.splitId == nil ? "Split the panel" : "Unsplit")

            Button(action: { store.isVisible = false }) {
                Label("Hide Panel", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Hide the terminal (⌃`)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct SessionTab: View {
    @ObservedObject var session: AgentTerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: session.exited ? "stop.circle" : "terminal")
                .appFont(fixed: 10)
                .foregroundStyle(.secondary)
            Text(session.title)
                .appFont(fixed: 11, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").appFont(fixed: 9)
            }
            .buttonStyle(.borderless)
            .opacity(hovered || isSelected ? 1 : 0)
            .help("Close session")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.secondary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
    }
}
