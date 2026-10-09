import SwiftUI

/// The open tab's own list filter, as the toolbar search field sees it.
///
/// A window has one search field. A tab that filters a list registers its
/// filter here instead of drawing a second box, and the toolbar field switches
/// between filtering that list (⌘F) and searching everything (⌘K).
struct TabSearchRegistration {
    let id: UUID
    let tab: AppTab
    let prompt: String
    let onSubmit: (() -> Void)?
}

private struct TabSearchModifier: ViewModifier {
    @EnvironmentObject var appState: AppState
    @Binding var text: String
    let prompt: String
    let onSubmit: (() -> Void)?
    @State private var id = UUID()

    private var isActive: Bool { appState.tabSearch?.id == id }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: register)
            .onChange(of: prompt) { _, _ in register() }
            // Tab views are swapped wholesale, so the next tab may register
            // before this one disappears; only clear what is still ours.
            .onDisappear {
                guard isActive else { return }
                appState.tabSearch = nil
                appState.tabSearchText = ""
            }
            .onChange(of: text) { _, new in
                if isActive, appState.tabSearchText != new { appState.tabSearchText = new }
            }
            .onChange(of: appState.tabSearchText) { _, new in
                if isActive, text != new { text = new }
            }
    }

    private func register() {
        appState.tabSearch = TabSearchRegistration(id: id, tab: appState.selectedTab, prompt: prompt, onSubmit: onSubmit)
        if appState.tabSearchText != text { appState.tabSearchText = text }
    }
}

extension View {
    /// Filter this tab's list from the toolbar search field. Replaces
    /// `.searchable`, which would put a second field in the toolbar.
    func tabSearch(text: Binding<String>, prompt: String, onSubmit: (() -> Void)? = nil) -> some View {
        modifier(TabSearchModifier(text: text, prompt: prompt, onSubmit: onSubmit))
    }
}
