import SwiftUI

/// Liquid Glass tab bar matching Activity Monitor's style.
/// Active tab has a filled pill background, inactive tabs are text-only
/// with vertical line separators between them.
struct GlassTabBar: View {
    @Binding var selectedTab: AppTab
    let tabs: [AppTab]
    let availableWidth: CGFloat
    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                // Separator between tabs (not before first or after selected)
                if index > 0 && tabs[index - 1] != selectedTab && tab != selectedTab {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1, height: 16)
                }

                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .appFont(fixed: 11)
                        Text(tab.rawValue)
                            .appFont(fixed: 13, weight: selectedTab == tab ? .semibold : .regular)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
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
                .focusable(false)
                .help(tab.rawValue)
            }
        }
        .padding(3)
        .modifier(GlassEffectModifier())
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
