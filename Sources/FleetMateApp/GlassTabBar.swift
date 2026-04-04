import SwiftUI

/// Applies Liquid Glass on macOS 26+, falls back to a translucent capsule on older systems.
private struct GlassEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Liquid Glass tab bar that adapts to available width.
/// - **Full**: icon + text labels (wide windows, ≥ 850 pt)
/// - **Compact**: icon only (medium windows, ≥ 500 pt)
/// - **Overflow**: visible icon tabs + "…" menu (narrow windows)
struct GlassTabBar: View {
    @Binding var selectedTab: AppTab
    let tabs: [AppTab]
    let availableWidth: CGFloat
    @Namespace private var selectionNS

    // MARK: - Layout mode

    private enum LayoutMode {
        case full
        case compact
        case overflow(maxVisible: Int)
    }

    private var layoutMode: LayoutMode {
        if availableWidth >= 850 { return .full }
        if availableWidth >= 500 { return .compact }
        if availableWidth >= 380 { return .overflow(maxVisible: 4) }
        return .overflow(maxVisible: 2)
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            switch layoutMode {
            case .full:
                tabButtons(tabs: tabs, showLabels: true)
            case .compact:
                tabButtons(tabs: tabs, showLabels: false)
            case .overflow(let maxVisible):
                let split = splitTabs(maxVisible: maxVisible)
                tabButtons(tabs: split.visible, showLabels: false)
                overflowMenu(tabs: split.overflow)
            }
        }
        .padding(3)
        .modifier(GlassEffectModifier())
    }

    // MARK: - Tab buttons

    @ViewBuilder
    private func tabButtons(tabs: [AppTab], showLabels: Bool) -> some View {
        ForEach(tabs) { tab in
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    selectedTab = tab
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12))
                    if showLabels {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .padding(.horizontal, showLabels ? 13 : 10)
                .padding(.vertical, 7)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                .background {
                    if selectedTab == tab {
                        Capsule()
                            .fill(.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: selectionNS)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(tab.rawValue)
        }
    }

    // MARK: - Overflow menu

    @ViewBuilder
    private func overflowMenu(tabs: [AppTab]) -> some View {
        let isSelectedInOverflow = tabs.contains(selectedTab)

        Menu {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(isSelectedInOverflow ? Color.primary : Color.secondary)
                .background {
                    if isSelectedInOverflow {
                        Capsule()
                            .fill(.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "selection", in: selectionNS)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More tabs")
    }

    // MARK: - Tab splitting

    /// Selected tab always stays in the visible set; bumped tab moves to overflow.
    private func splitTabs(maxVisible: Int) -> (visible: [AppTab], overflow: [AppTab]) {
        let all = tabs
        guard maxVisible < all.count else { return (all, []) }

        var visible = Array(all.prefix(maxVisible))
        var overflow = Array(all.dropFirst(maxVisible))

        if let idx = overflow.firstIndex(of: selectedTab) {
            let bumped = visible[maxVisible - 1]
            visible[maxVisible - 1] = selectedTab
            overflow[idx] = bumped
        }

        return (visible, overflow)
    }
}
