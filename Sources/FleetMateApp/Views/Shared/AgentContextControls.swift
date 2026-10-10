import AppKit
import SwiftUI
import FleetMateCore

/// Puts `AgentContext` blocks on the pasteboard and into drags: the Markdown
/// as plain text, plus the item's link as a URL where it has one.
enum AgentContextPasteboard {
    static func write(_ contexts: [AgentContext], to pasteboard: NSPasteboard = .general) {
        guard !contexts.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(AgentContextRenderer.render(contexts), forType: .string)
        if contexts.count == 1, let link = contexts[0].url, let url = URL(string: link) {
            item.setString(url.absoluteString, forType: .URL)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
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
    func sendToAgent(_ contexts: [AgentContext]) {
        guard !contexts.isEmpty else { return }
        if !terminals.insert(AgentContextRenderer.render(contexts)) {
            AgentContextPasteboard.write(contexts)
            terminals.show(defaultLaunch: agentDefaultLaunch)
        }
    }
}

/// "Copy for Agent" and "Send to Agent", for a row's context menu.
struct AgentContextMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let contexts: [AgentContext]

    init(_ context: AgentContext) { contexts = [context] }
    init(_ contexts: [AgentContext]) { self.contexts = contexts }

    var body: some View {
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
struct AgentContextButton: View {
    @EnvironmentObject private var appState: AppState
    let context: AgentContext?

    init(_ context: AgentContext?) { self.context = context }

    var body: some View {
        Menu {
            Button("Send to Agent") { if let context { appState.sendToAgent([context]) } }
            Button("Copy for Agent") { if let context { AgentContextPasteboard.write([context]) } }
        } label: {
            Label("Agent", systemImage: ContentView.agentSymbol)
        } primaryAction: {
            if let context { appState.sendToAgent([context]) }
        }
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
