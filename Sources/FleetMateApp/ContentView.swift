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
    /// When each system's silent SSO was last attempted from a tab switch.
    /// Previously a one-shot Bool per system: the first failure of the launch
    /// latched it, so a session that recovered — VPN back, `az login` renewed,
    /// a fresh Entra PRT — never re-attempted and the tab stayed empty for the
    /// life of the process. Re-attempt on every visit, no faster than this.
    @State private var lastSsoAttempt: [AuthSystemId: Date] = [:]
    private static let ssoRetryInterval: TimeInterval = 60
    @State private var windowWidth: CGFloat = 1000
    @State private var showAuthPopover = false

    private var availableTabs: [AppTab] {
        AppTab.enabledTabs(config: appState.config)
    }

    private var selectedTab: AppTab { appState.selectedTab }

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
                // Browser-style history, mirrored on ⌘[ / ⌘].
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        appState.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back (⌘[)")
                    .disabled(!appState.canGoBack)
                    Button {
                        appState.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Forward (⌘])")
                    .disabled(!appState.canGoForward)
                }
                ToolbarItem(placement: .principal) {
                    GlassTabBar(selectedTab: $appState.selectedTab, tabs: availableTabs, availableWidth: windowWidth)
                }
                // The authentication shield belongs to the window, not to the
                // Dashboard: auth is what breaks any tab, so it has to be
                // checkable from whichever tab is showing the breakage.
                //
                // A tab's `.searchable` field is a toolbar item AppKit places
                // last of its own accord, so no placement of ours lands to the
                // right of it — the shield ended up stranded mid-toolbar. On
                // macOS 26 the search field can be positioned explicitly, so
                // claim it here and declare the shield after it.
                if #available(macOS 26.0, *) {
                    DefaultToolbarItem(kind: .search, placement: .automatic)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAuthPopover.toggle() }) {
                        Label("Authentication", systemImage: "lock.shield")
                    }
                    .help("Authentication status for every connected system")
                    .popover(isPresented: $showAuthPopover, arrowEdge: .bottom) {
                        AuthSettingsView()
                            .environmentObject(appState)
                            .frame(width: 480)
                            .frame(minHeight: 300, idealHeight: 560, maxHeight: 640)
                    }
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
            .onChange(of: appState.selectedTab) { _, newTab in
                // Re-attempt silent SSO when navigating to a tab that needs auth.
                // No interactive popups — all web auth is silent/headless only.
                if newTab == .tickets,
                   !appState.tdxSsoAuthenticated,
                   appState.tdxService.shouldAttemptSso,
                   shouldRetrySso(.tdx) {
                    appState.attemptSilentTdxSso()
                }
                if newTab == .projects,
                   !appState.devOpsSsoAuthenticated,
                   appState.isDevOpsSsoConfigured,
                   shouldRetrySso(.devops) {
                    appState.attemptSilentDevOpsSso()
                }
                if newTab == .inventory,
                   !appState.snipeSsoAuthenticated,
                   appState.snipeService.shouldAttemptSso,
                   shouldRetrySso(.snipe) {
                    appState.attemptSilentSnipeSso()
                }
            }
            .onChange(of: appState.navigateToTab) { _, newTab in
                if let tab = newTab {
                    appState.selectedTab = tab
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

    /// True when enough time has passed to try this system's silent SSO again,
    /// recording the attempt. Throttled so a burst of tab switches doesn't fan
    /// out a burst of headless auth attempts.
    private func shouldRetrySso(_ system: AuthSystemId) -> Bool {
        let now = Date()
        if let last = lastSsoAttempt[system], now.timeIntervalSince(last) < Self.ssoRetryInterval {
            return false
        }
        lastSsoAttempt[system] = now
        return true
    }

    private func validateSelectedTab() {
        if !selectedTab.isEnabled(config: appState.config) {
            appState.selectedTab = .dashboard
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
