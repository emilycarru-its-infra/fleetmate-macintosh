import SwiftUI
import FleetMateCore

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
    /// Below this width the visible module folds its toolbar (segments into a
    /// menu, titled buttons to icons) so the module tab bar keeps its room.
    static let compactModuleToolbarBelow: CGFloat = 1400
    @State private var showAuthPopover = false
    @ObservedObject private var terminals: AgentTerminalStore

    init(terminals: AgentTerminalStore) {
        self.terminals = terminals
    }

    private var availableTabs: [AppTab] {
        AppTab.enabledTabs(config: appState.config, modules: appState.modules)
    }

    private var selectedTab: AppTab { appState.selectedTab }

    var body: some View {
        VStack(spacing: 0) {
            if !(terminals.isMaximized && terminals.isVisible && !terminals.sessions.isEmpty) {
                tabContent
                    .frame(maxHeight: .infinity)
                    .environment(\.compactModuleToolbar, windowWidth < Self.compactModuleToolbarBelow)
            }
            if !AppEdition.current.isTicketsOnly {
                AgentTerminalDock(store: terminals,
                                  repos: appState.agentRepos,
                                  defaultLaunch: appState.agentDefaultLaunch)
            }
        }
            .frame(minWidth: 500, minHeight: 400)
            // A preference read through a background GeometryReader stopped
            // updating once the window had been narrowed, so widening it
            // again left the toolbar compact. Observe the geometry directly.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { windowWidth = $0 }
            .background(ToolbarPriorityBridge { appState.globalSearchFocusRequest += 1 })
            .toolbar {
                // Browser-style history, mirrored on ⌘[ / ⌘].
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        appState.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .help("Back (⌘[)")
                    .disabled(!appState.canGoBack)
                    Button {
                        appState.goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .help("Forward (⌘])")
                    .disabled(!appState.canGoForward)
                }
                // A single tab needs no tab bar.
                if availableTabs.count > 1 {
                    ToolbarItem(placement: .principal) {
                        GlassTabBar(selectedTab: $appState.selectedTab, tabs: availableTabs, availableWidth: windowWidth)
                    }
                }
                // The authentication shield belongs to the window, not to the
                // Dashboard: auth is what breaks any tab, so it has to be
                // checkable from whichever tab is showing the breakage.
                // Push every trailing control to the window's right edge.
                // Without it they sat right after the centred tab bar, leaving
                // the right of the toolbar empty and search short of the edge.
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                }
                if selectedTab.hasWidgets {
                    ToolbarItem(placement: .primaryAction) {
                        GraphsToolbarButton(tab: selectedTab).id(selectedTab)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    RecentActivityToolbarButton()
                }
                if !AppEdition.current.isTicketsOnly {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { terminals.toggle(defaultLaunch: appState.agentDefaultLaunch) }) {
                            Label("Agent", systemImage: Self.agentSymbol)
                        }
                        .help("Show or hide the agent terminal (⌃`)")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAuthPopover.toggle() }) {
                        // A Label, so the overflow menu and Customize Toolbar
                        // show "Authentication" rather than a bare shield.
                        Label {
                            Text("Authentication")
                        } icon: {
                            ElevationShieldLabel()
                        }
                    }
                    .popover(isPresented: $showAuthPopover, arrowEdge: .bottom) {
                        AuthSettingsView()
                            .environmentObject(appState)
                            .frame(width: 480)
                            .frame(minHeight: 300, idealHeight: 560, maxHeight: 640)
                    }
                }
                if appState.authManager.hasServicePrincipalWarning {
                    ToolbarItem(placement: .automatic) {
                        // A Label, so the overflow menu has a name for it.
                        Label {
                            Text("Service Principal")
                        } icon: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .appFont(fixed: 11)
                                Text("SP")
                                    .appFont(fixed: 10, weight: .bold)
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 4))
                        }
                        .labelStyle(.iconOnly)
                        .help("One or more systems are logged in as a Service Principal")
                    }
                }
                // Last, at the far right, where search is looked for.
                ToolbarItem(placement: .primaryAction) {
                    GlobalSearchToolbarField(width: windowWidth < Self.compactModuleToolbarBelow ? 200 : 300)
                }
            }
            .onAppear {
                appState.wireAgentTerminal()
                terminals.defaultLaunch = appState.agentDefaultLaunch
                if appState.agentAutoStart && terminals.sessions.isEmpty {
                    terminals.open(appState.agentDefaultLaunch, focus: false, show: false)
                }
                writeAgentContext()
            }
            .onChange(of: appState.selectedTab) { _, _ in
                appState.agentSelection = nil
                writeAgentContext()
            }
            .onChange(of: appState.agentSelection) { _, _ in writeAgentContext() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                terminals.terminateAll()
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
                if newTab == .projects || newTab == .development,
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
            .actionErrorBanner($appState.linkError, title: "Couldn't open link")
            .modifier(HandbookReaderHost(knowledge: appState.knowledge))
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
            .onChange(of: appState.config.isManageConfigured) { _, _ in validateSelectedTab() }
            .onChange(of: appState.modules) { _, _ in validateSelectedTab() }
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
        if !selectedTab.isEnabled(config: appState.config, modules: appState.modules) {
            appState.selectedTab = AppTab.launchTab()
        }
    }

    private func writeAgentContext() {
        appState.writeAgentContext()
    }

    /// The agent symbol where the system has it (macOS 15.1 and later),
    /// sparkles before that.
    static let agentSymbol = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil
        ? "apple.intelligence" : "sparkles"

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .devices:   DevicesView()
        case .reporting: ReportingView()
        case .manage:    ManageView(manage: appState.manageState)
        case .inventory: AssetsView()
        case .tickets:   TicketsView()
        case .projects:  BoardsView()
        case .development: DevelopmentView()
        case .identity:  IdentityView()
        }
    }
}

#if DEBUG
#Preview {
    ContentView(terminals: AgentTerminalStore())
        .environmentObject(AppState())
}
#endif

