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

/// A toolbar search field that only filters the open tab's list (⌘F), for a
/// window with nothing else to search.
struct TabSearchToolbarField: View {
    @EnvironmentObject var appState: AppState
    var width: CGFloat = 300
    @FocusState private var focused: Bool

    private var prompt: String { appState.tabSearch?.prompt ?? "Search" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focused ? Color.accentColor : .secondary)
                .onTapGesture { focused = true }
            TextField("", text: $appState.tabSearchText, prompt: Text(prompt).foregroundStyle(.secondary))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { appState.tabSearch?.onSubmit?() }
                .onExitCommand { clear() }
            if appState.tabSearchText.isEmpty {
                Text("⌘F")
                    .appFont(fixed: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .appFont(.body)
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: focused ? 1.5 : 1)
        )
        .help("Filter \(appState.tabSearch?.tab.rawValue.lowercased() ?? "this list") (⌘F)")
        .onChange(of: appState.tabSearchFocusRequest) { _, _ in focused = true }
        .disabled(appState.tabSearch == nil)
    }

    private func clear() {
        appState.tabSearchText = ""
        focused = false
    }
}
