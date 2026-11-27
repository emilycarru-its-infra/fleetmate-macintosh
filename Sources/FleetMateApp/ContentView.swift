import SwiftUI
import FleetMateCore
import AgentsMate

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
    static let compactModuleToolbarBelow: CGFloat = 1900
    @State private var showAuthPopover = false
    @ObservedObject private var terminals: AgentTerminalStore
    @ObservedObject private var repoOrdering = RepositoryOrdering.shared
    @Environment(\.appFontScale) private var fontScale

    init(terminals: AgentTerminalStore) {
        self.terminals = terminals
    }

    private var availableTabs: [AppTab] {
        AppTab.enabledTabs(config: appState.config, modules: appState.modules)
    }

    private var selectedTab: AppTab { appState.selectedTab }

    /// The sessions fill the window.
    private var inAgentsMode: Bool {
        terminals.isMaximized && terminals.isVisible && !terminals.lanes.lanes.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.tdxNeedsSignIn, selectedTab == .tickets || AppEdition.current.isTicketsOnly {
                TdxSignInBanner()
            }
            if !(terminals.isMaximized && terminals.isVisible && !terminals.lanes.lanes.isEmpty) {
                tabContent
                    .frame(maxHeight: .infinity)
            }
            if !AppEdition.current.isTicketsOnly {
                AgentTerminalDock(store: terminals,
                                  repos: repoOrdering.sorted(agentEntries: appState.agentRepos),
                                  defaultLaunch: appState.agentDefaultLaunch)
                    // The first time the Agent opens, its repositories and
                    // the tracked ones in Settings › Repositories are synced.
                    .onAppear { if terminals.isVisible { AgentRepoSync.syncOnFirstOpen(appState) } }
                    .onChange(of: terminals.isVisible) { _, visible in
                        if visible { AgentRepoSync.syncOnFirstOpen(appState) }
                    }
            }
        }
            // Work items, issues, pull requests, commits and runs open over
            // the tab, the Agent dock included.
            .modifier(LightboxHost(appState: appState))
            .frame(minWidth: 500, minHeight: 400)
            // The window's width for the tab bar, the toolbar items' ranking,
            // and the search field pinned to the title bar: AgentsMate's.
            .agentsMainWindowChrome(windowWidth: $windowWidth,
                                    extraItemLabels: ["Graphs", "Recent Activity", "Authentication", "Service Principal"]) { width in
                GlobalSearchToolbarField(width: width)
                    .environmentObject(appState)
                    .appFontScale(fontScale)
            }
            .toolbar {
                // Agent, history, the tabs and the right-hand spacer are
                // AgentsMate's, the same in every app; what follows the spacer
                // is this app's.
                AgentsMainToolbar(
                    agent: AppEdition.current.isTicketsOnly ? nil
                        : AgentsToolbarAgent(isOn: terminals.isShowing, store: terminals.lanes) {
                            terminals.toggle(defaultLaunch: appState.agentDefaultLaunch)
                        },
                    history: AgentsToolbarHistory(canGoBack: appState.canGoBack, canGoForward: appState.canGoForward,
                                              backShortcut: "⌘[", forwardShortcut: "⌘]",
                                                  goBack: { appState.goBack() }, goForward: { appState.goForward() }),
                    tabs: availableTabs.enumerated().map { index, tab in
                        CollapsingTab(id: tab, title: tab.rawValue, systemImage: tab.icon,
                                      shortcut: index < 9 ? "⌘\(index + 1)" : nil)
                    },
                    selection: $appState.selectedTab,
                    windowWidth: windowWidth,
                    onSelect: { terminals.hide() }
                ) {
                // The authentication shield belongs to the window, not to the
                // Dashboard: auth is what breaks any tab, so it has to be
                // checkable from whichever tab is showing the breakage.
                // Graphs, recents and sign-in belong to the tabs, so Agents mode
                // leaves them out and they return when it ends.
                if selectedTab.hasWidgets, !inAgentsMode {
                    ToolbarItem(placement: .primaryAction) {
                        GraphsToolbarButton(tab: selectedTab).id(selectedTab)
                    }
                }
                if !inAgentsMode {
                ToolbarItem(placement: .primaryAction) {
                    RecentActivityToolbarButton()
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
                    .autoClosingPopover(isPresented: $showAuthPopover, arrowEdge: .bottom) {
                        AuthSettingsView()
                            .environmentObject(appState)
                            .frame(width: 480)
                            .frame(minHeight: 300, idealHeight: 560, maxHeight: 640)
                    }
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
                }
            }
            .environment(\.compactModuleToolbar, windowWidth < Self.compactModuleToolbarBelow)
            .onAppear {
                appState.wireAgentTerminal()
                terminals.resolveDefaultLaunch = { [weak appState] in appState?.agentDefaultLaunch ?? .shell }
                // The tracked repositories as rows in the session list, then
                // the sessions open at the last quit, both waiting to start.
                // A saved workspace named to open at launch takes the place
                // of the single session that otherwise starts.
                terminals.syncBaseline()
                terminals.restoreLastSessions()
                terminals.reloadWorkspaces()
                if !AppEdition.current.isTicketsOnly, !terminals.hasOwnSessions,
                   let workspace = terminals.workspaceFile.launchWorkspace {
                    terminals.open(workspace: workspace)
                } else if appState.agentAutoStart && !terminals.hasOwnSessions && !terminals.hasRepoRows {
                    terminals.open(appState.agentDefaultLaunch, focus: false, show: false)
                }
                writeAgentContext()
            }
            // Agents mode, the sessions filling the window over Development,
            // in full screen: at launch only, and starting no session of its
            // own. TicketsMate has no sessions.
            .agentsLaunch(terminals.lanes) {
                guard !AppEdition.current.isTicketsOnly else { return }
                terminals.lanes.enterAgentsMode()
            }
            .onChange(of: appState.selectedTab) { _, _ in
                terminals.hide()
                appState.closeLightbox()
                appState.agentSelection = nil
                writeAgentContext()
            }
            // The toolbar drops its items in Agents mode, so a popover anchored to
            // one would be left floating with nothing under it.
            .onChange(of: inAgentsMode) { _, _ in showAuthPopover = false }
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
            .sheet(isPresented: $appState.showTdxSsoLogin) {
                TdxSsoLoginView(config: appState.config) { result in
                    appState.handleInteractiveTdxResult(result)
                }
            }
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
    static let agentSymbol = AgentsToolbar.agentSymbol

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
        case .teams:     TeamsView()
        }
    }
}

#if DEBUG
#Preview {
    ContentView(terminals: AgentTerminalStore())
        .environmentObject(AppState())
}
#endif

