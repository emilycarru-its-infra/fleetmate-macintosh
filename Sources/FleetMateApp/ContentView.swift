import SwiftUI
import FleetMateCore

/// Preference key to relay the content area width up to ContentView.
private struct WindowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .dashboard
    @State private var hasAutoPromptedSso = false
    @State private var hasAutoPromptedDevOpsSso = false
    @State private var hasAutoPromptedSnipeSso = false
    @State private var windowWidth: CGFloat = 1000

    private var availableTabs: [AppTab] {
        AppTab.enabledTabs(config: appState.config)
    }

    var body: some View {
        tabContent
            .frame(minWidth: 500, minHeight: 400)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: WindowWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(WindowWidthKey.self) { windowWidth = $0 }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GlassTabBar(selectedTab: $selectedTab, tabs: availableTabs, availableWidth: windowWidth)
                }
                if appState.authManager.hasServicePrincipalWarning {
                    ToolbarItem(placement: .automatic) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .appFont(fixed: 11)
                            Text("SP")
                                .appFont(fixed: 10, weight: .bold)
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 4))
                        .help("One or more systems are logged in as a Service Principal")
                    }
                }
            }
            .onAppear {
                // Phase 1: Attempt silent SSO in the background (no UI).
                // If it fails, Phase 2 interactive login is deferred until the
                // user navigates to a tab that actually needs auth.
                if !appState.tdxSsoAuthenticated && appState.tdxService.shouldAttemptSso {
                    appState.attemptSilentTdxSso()
                }
                // DevOps: same 3-phase pattern
                if !appState.devOpsSsoAuthenticated && appState.isDevOpsSsoConfigured {
                    appState.attemptSilentDevOpsSso()
                }
                // Snipe-IT: silent SSO
                if !appState.snipeSsoAuthenticated && appState.snipeService.shouldAttemptSso {
                    appState.attemptSilentSnipeSso()
                }
            }
            .onChange(of: selectedTab) { _, newTab in
                // Re-attempt silent SSO when navigating to a tab that needs auth.
                // No interactive popups — all web auth is silent/headless only.
                if newTab == .tickets,
                   !appState.tdxSsoAuthenticated,
                   !hasAutoPromptedSso,
                   appState.tdxService.shouldAttemptSso {
                    hasAutoPromptedSso = true
                    appState.attemptSilentTdxSso()
                }
                if newTab == .projects,
                   !appState.devOpsSsoAuthenticated,
                   !hasAutoPromptedDevOpsSso,
                   appState.isDevOpsSsoConfigured {
                    hasAutoPromptedDevOpsSso = true
                    appState.attemptSilentDevOpsSso()
                }
                if newTab == .inventory,
                   !appState.snipeSsoAuthenticated,
                   !hasAutoPromptedSnipeSso,
                   appState.snipeService.shouldAttemptSso {
                    hasAutoPromptedSnipeSso = true
                    appState.attemptSilentSnipeSso()
                }
            }
            .onChange(of: appState.navigateToTab) { _, newTab in
                if let tab = newTab {
                    selectedTab = tab
                    appState.navigateToTab = nil
                }
            }
            .onChange(of: appState.config.isGraphConfigured) { _, _ in validateSelectedTab() }
            .onChange(of: appState.config.isSnipeConfigured) { _, _ in validateSelectedTab() }
            .onChange(of: appState.config.isTdxConfigured) { _, _ in validateSelectedTab() }
            .onChange(of: appState.config.isDevOpsConfigured) { _, _ in validateSelectedTab() }
            .sheet(isPresented: $appState.showOnboardingWizard) {
                OnboardingWizardView()
                    .environmentObject(appState)
            }
    }

    private func validateSelectedTab() {
        if !selectedTab.isEnabled(config: appState.config) {
            selectedTab = .dashboard
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .dashboard: DashboardView()
        case .devices:   DevicesView()
        case .inventory: AssetsView()
        case .tickets:   TicketsView()
        case .projects:  BoardsView()
        case .identity:  IdentityView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
