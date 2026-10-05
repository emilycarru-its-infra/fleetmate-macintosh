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
    @ObservedObject private var terminals: AgentTerminalStore
    @AppStorage(AgentSettingsKey.panelHeight) private var panelHeight: Double = 280
    @State private var panelDragStart: Double?

    init(terminals: AgentTerminalStore) {
        self.terminals = terminals
    }

    private var availableTabs: [AppTab] {
        AppTab.enabledTabs(config: appState.config)
    }

    private var selectedTab: AppTab { appState.selectedTab }

    var body: some View {
        VStack(spacing: 0) {
            if !(terminals.isMaximized && terminals.isVisible && !terminals.sessions.isEmpty) {
                tabContent
                    .frame(maxHeight: .infinity)
            }
            if terminals.isVisible && !terminals.sessions.isEmpty {
                terminalPanel
            }
        }
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
                // The tab's own filter field sits on the left with the tab's
                // controls, so search-everything can be the last item on the
                // right.
                if #available(macOS 26.0, *) {
                    DefaultToolbarItem(kind: .search, placement: .navigation)
                }
                if selectedTab.hasWidgets {
                    ToolbarItem(placement: .primaryAction) {
                        GraphsToolbarButton(tab: selectedTab).id(selectedTab)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    RecentActivityToolbarButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { terminals.toggle(defaultLaunch: appState.agentDefaultLaunch) }) {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .help("Show or hide the terminal (⌃`)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAuthPopover.toggle() }) {
                        ElevationShieldLabel()
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
                // Last, at the far right, where search is looked for.
                ToolbarItem(placement: .primaryAction) {
                    GlobalSearchToolbarField(compact: windowWidth < GlassTabBar.compactBelow)
                }
            }
            .onAppear {
                terminals.defaultLaunch = appState.agentDefaultLaunch
                if appState.agentAutoStart && terminals.sessions.isEmpty {
                    terminals.open(appState.agentDefaultLaunch, focus: false)
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
            appState.selectedTab = .development
        }
    }

    private func writeAgentContext() {
        AgentContextWriter.write(tab: appState.selectedTab.rawValue,
                                 selection: appState.agentSelection,
                                 to: terminals.contextPath)
    }

    /// The shared bottom terminal, with a drag handle to resize it.
    private var terminalPanel: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
                .padding(.vertical, 2)
                .contentShape(Rectangle().inset(by: -3))
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    // Measured in window coordinates: the handle moves with
                    // the panel, so local coordinates made the drag jitter.
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = panelDragStart ?? panelHeight
                            panelDragStart = start
                            if terminals.isMaximized { terminals.isMaximized = false }
                            panelHeight = min(max(start - value.translation.height, 120), 1600)
                        }
                        .onEnded { _ in
                            // Dragged nearly to the top: fill the window, and
                            // restore to the height it had before.
                            let available = NSApp.keyWindow?.contentLayoutRect.height ?? 900
                            if panelHeight > available * 0.85 {
                                panelHeight = panelDragStart ?? 280
                                terminals.isMaximized = true
                            }
                            panelDragStart = nil
                        }
                )
            AgentTerminalPanel(store: terminals,
                               repos: appState.agentRepos,
                               defaultLaunch: appState.agentDefaultLaunch)
                .frame(height: terminals.isMaximized ? nil : panelHeight)
                .frame(maxHeight: terminals.isMaximized ? .infinity : nil)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .devices:   DevicesView()
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

