import AppKit
import SwiftUI
import FleetMateCore
import AgentsMate

/// Puts `AgentContext` blocks on the pasteboard and into drags: the Markdown
/// as plain text, plus the item's link as a URL where it has one.
@MainActor
enum AgentContextPasteboard {
    static func write(_ contexts: [AgentContext], to pasteboard: NSPasteboard = .general, anchor: NSView? = nil) {
        guard !contexts.isEmpty else { return }
        let item = NSPasteboardItem()
        let text = AgentContextRenderer.render(contexts)
        item.setString(text, forType: .string)
        if contexts.count == 1, let link = contexts[0].url, let url = URL(string: link) {
            item.setString(url.absoluteString, forType: .URL)
        }
        pasteboard.clearContents()
        if pasteboard.writeObjects([item]), pasteboard === NSPasteboard.general {
            ClipboardPreview.show(text, heading: "Copied for Agent", anchor: anchor)
        }
    }

    /// A drag carries the text alone, so wherever it lands (the agent
    /// terminal, a note, a message) it arrives as the context block.
    static func itemProvider(_ contexts: [AgentContext]) -> NSItemProvider {
        NSItemProvider(object: AgentContextRenderer.render(contexts) as NSString)
    }
}

extension AppState {
    /// Paste the blocks into a running agent's input, never pressing Return.
    /// With no agent running, copy them and open the terminal idle, so the
    /// person pastes them alongside their own request.
    func sendToAgent(_ contexts: [AgentContext], anchor: NSView? = nil) {
        guard !contexts.isEmpty else { return }
        if !terminals.insert(AgentContextRenderer.render(contexts)) {
            AgentContextPasteboard.write(contexts, anchor: anchor)
            terminals.show(defaultLaunch: agentDefaultLaunch)
        }
    }
}

extension AppState {
    /// The checkout of a pipeline run's repository, from the repository
    /// registry, when this Mac has one.
    func checkoutFolder(for run: PipelineRun) -> String? {
        guard let repository = run.repository, let document = try? RepoRegistryStore().load() else { return nil }
        let wanted = "\(run.container)/\(repository)".lowercased()
        let provider: RepoProvider = run.source == .gitHub ? .gitHub : .azureDevOps
        return document.entries.first { $0.key.provider == provider && $0.key.displayName.lowercased() == wanted }
            .map { ($0.path as NSString).expandingTildeInPath }
    }

    /// Send a pipeline report to the agent working in the run's repository:
    /// its lane, opened if need be. The text is pasted and never sent with
    /// Return, so the person reads it first. When no lane is ready within a
    /// while, or the repository has no checkout here, it goes on the
    /// clipboard and the agent terminal opens.
    func sendPipelineReport(_ text: String, for run: PipelineRun, anchor: NSView? = nil) {
        guard !AppEdition.current.isTicketsOnly else { return }
        guard let folder = checkoutFolder(for: run) else {
            if !terminals.insert(text) { copyAndShowAgent(text, anchor: anchor) }
            return
        }
        let store = terminals.lanes
        let key = AgentLaneStore.canonicalFolder(URL(fileURLWithPath: folder, isDirectory: true)).path
        let id = store.displayOrder.first { lane in
            !store.isDetached(lane.id) && lane.directory.map {
                AgentLaneStore.canonicalFolder($0).path == key
            } == true
        }?.id ?? terminals.open(AgentLaunch(command: agentDefaultLaunch.command, directory: folder), focus: true, show: true)
        store.showDock()
        store.open(id, focus: true)
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                if let session = store.sessions[id], session.programIsForeground, session.view.acceptsBracketedPaste {
                    if store.send(text, to: id) == .sent { return }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.copyAndShowAgent(text, anchor: anchor)
        }
    }

    private func copyAndShowAgent(_ text: String, anchor: NSView?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ClipboardPreview.show(text, heading: "No agent was ready, so this is on the clipboard", anchor: anchor)
        terminals.show(defaultLaunch: agentDefaultLaunch)
    }
}

/// "Copy for Agent" and "Send to Agent", for a row's context menu. TicketsMate
/// has no agent terminal, so there it shows neither.
struct AgentContextMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let contexts: [AgentContext]

    init(_ context: AgentContext) { contexts = [context] }
    init(_ contexts: [AgentContext]) { self.contexts = contexts }

    var body: some View {
        if !AppEdition.current.isTicketsOnly { items }
    }

    @ViewBuilder
    private var items: some View {
        Button {
            AgentContextPasteboard.write(contexts)
        } label: {
            Label("Copy for Agent", systemImage: ContentView.agentSymbol)
        }
        .disabled(contexts.isEmpty)
        Button {
            appState.sendToAgent(contexts)
        } label: {
            Label("Send to Agent", systemImage: "arrow.down.to.line")
        }
        .disabled(contexts.isEmpty)
    }
}

/// The detail-view button: click sends to the agent session, the menu copies.
/// TicketsMate has no agent terminal, so there it is not shown.
struct AgentContextButton: View {
    @StateObject private var anchor = ClipboardAnchor()
    @EnvironmentObject private var appState: AppState
    let context: AgentContext?

    init(_ context: AgentContext?) { self.context = context }

    var body: some View {
        if !AppEdition.current.isTicketsOnly { button }
    }

    private var button: some View {
        Menu {
            Button("Send to Agent") { if let context { appState.sendToAgent([context], anchor: anchor.view) } }
            Button("Copy for Agent") { if let context { AgentContextPasteboard.write([context], anchor: anchor.view) } }
        } label: {
            Label("Agent", systemImage: ContentView.agentSymbol)
        } primaryAction: {
            if let context { appState.sendToAgent([context], anchor: anchor.view) }
        }
        .background(ClipboardAnchorView(anchor: anchor).accessibilityHidden(true))
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(context == nil)
        .help("Send this \(context?.kind.label.lowercased() ?? "item") to the running agent, or copy it when none is running; the menu copies it")
    }
}

extension View {
    /// Lets the row be dragged into the agent terminal (or anywhere text
    /// goes) as its context block. Built lazily, when the drag starts.
    func agentContextDrag(_ context: @escaping () -> AgentContext) -> some View {
        onDrag { AgentContextPasteboard.itemProvider([context()]) }
    }
}
