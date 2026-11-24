import SwiftUI
import AgentsMate

/// The main tabs: AgentsMate's collapsing bar with this app's tabs. Tabs that
/// are not open show their icon when room is short, and name themselves on
/// hover. They never fold into a menu.
struct GlassTabBar: View {
    @Binding var selectedTab: AppTab
    let tabs: [AppTab]
    var onSelect: () -> Void = {}
    let availableWidth: CGFloat

    /// The toolbar's leading and trailing controls each take up to this much,
    /// and the bar is centred, so it can use the window less twice this.
    static let sideReserve: CGFloat = 620

    var body: some View {
        CollapsingTabBar(selection: $selectedTab,
                         tabs: tabs.enumerated().map { index, tab in
                             CollapsingTab(id: tab, title: tab.rawValue, systemImage: tab.icon,
                                           shortcut: index < 9 ? "⌘\(index + 1)" : nil)
                         },
                         availableWidth: availableWidth - Self.sideReserve * 2,
                         onSelect: onSelect)
    }
}

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

/// Glass button modifier for action buttons — interactive glass on macOS 26+
struct GlassButtonModifier: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(8)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func glassButton(cornerRadius: CGFloat = 8) -> some View {
        modifier(GlassButtonModifier(cornerRadius: cornerRadius))
    }
}
