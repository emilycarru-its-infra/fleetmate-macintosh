import SwiftUI

/// Liquid Glass tab bar that lives in the window toolbar (.principal placement).
/// All tab pills merge into a single fluid glass strip via GlassEffectContainer;
/// the selected tab gets a tinted highlight that animates smoothly on switch.
struct GlassTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        GlassEffectContainer(spacing: 40) {
            HStack(spacing: 2) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selectedTab == tab
                            ? .regular.tint(.accentColor).interactive()
                            : .regular.interactive(),
                        in: .capsule
                    )
                }
            }
        }
    }
}
