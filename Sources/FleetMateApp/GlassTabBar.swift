import SwiftUI

/// Liquid Glass tab bar that lives in the window toolbar (.principal placement).
/// One glass capsule wraps the whole strip; the selected tab is indicated by a
/// matchedGeometryEffect sliding fill — no double-glass layering.
struct GlassTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 13)
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
            }
        }
        .padding(3)
        .glassEffect(in: .capsule)
    }
}
