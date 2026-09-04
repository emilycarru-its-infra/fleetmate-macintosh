import SwiftUI
import Combine
import FleetMateCore

@main
struct FleetMateApp: App {
    @StateObject private var appState = AppState()
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default

    init() {
        // Ensure app appears in Dock and can be activated
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // FleetMate is one window with six modes, not a document app. Leaving
        // automatic tabbing on put "Show Tab Bar" and "Show All Tabs" (⌘\) at
        // the top of the View menu, promising document tabs that don't exist —
        // directly above the ⌘1–⌘6 items that do the switching.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .appFontScale(fontScale)
                .task {
                    await appState.preloadAllData()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            FleetMateCommands(appState: appState)
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .appFontScale(fontScale)
        }
        #endif
    }
}

/// State of the aze elevation sessions Graph rides on, surfaced in the UI.
enum AzeSessionState {
    case direct   // not using aze (FLEETMATE_GRAPH_TRANSPORT=direct)
    case warming  // container cold start in progress (~30s)
    case warm     // ready
    case failed   // warm attempt failed; first real call will retry
}

@MainActor
class AppState: ObservableObject {
    @Published var config: FleetMateConfig
    @Published var azeSessionState: AzeSessionState = .direct
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var secretsConfigured = false
    
    // MARK: - Onboarding
    @Published var showOnboardingWizard = false

    // MARK: - Tab Navigation (set by Dashboard to switch tabs)

    /// The visible tab. Lives here rather than in `ContentView` so the ⌘1–⌘6
    /// menu commands, which are built in the `App` scene, can both read it (to
    /// decide whether ⌘N means "ticket" or "work item") and set it.
    ///
    /// The didSet logs each change with its call stack: the app has been seen
    /// jumping to Inventory with no user action, and only three code paths
    /// write tab state — none of them targeting Inventory. Until the jump is
    /// reproduced with this in place, the log is the only way to name the
    /// caller. Cheap enough to keep (fires only on actual changes).
    @Published var selectedTab: AppTab = .dashboard {
        didSet {
            guard oldValue != selectedTab else { return }
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(5)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " | ")
            dbg.info("Tab \(oldValue.rawValue) → \(selectedTab.rawValue) via: \(frames)", category: "tabs")
            // Browser-style history: any organic navigation pushes the old tab
            // and clears the forward stack; Back/Forward set the flag so their
            // own writes don't re-record.
            if !isNavigatingTabHistory {
                tabBackStack.append(oldValue)
                tabForwardStack.removeAll()
            }
        }
    }

    // MARK: - Tab history (Back / Forward, ⌘[ / ⌘])

    private var tabBackStack: [AppTab] = []
    private var tabForwardStack: [AppTab] = []
    private var isNavigatingTabHistory = false

    var canGoBack: Bool { !tabBackStack.isEmpty }
    var canGoForward: Bool { !tabForwardStack.isEmpty }

    func goBack() {
        guard let previous = tabBackStack.popLast() else { return }
        isNavigatingTabHistory = true
        tabForwardStack.append(selectedTab)
        selectedTab = previous
        isNavigatingTabHistory = false
    }

    func goForward() {
        guard let next = tabForwardStack.popLast() else { return }
        isNavigatingTabHistory = true
        tabBackStack.append(selectedTab)
        selectedTab = next
        isNavigatingTabHistory = false
    }
    @Published var navigateToTab: AppTab? {
        didSet {
            guard let tab = navigateToTab else { return }
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(5)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " | ")
            dbg.info("navigateToTab ← \(tab.rawValue) via: \(frames)", category: "tabs")
        }
    }
    /// The most recent menu command, for the visible tab to act on.
    /// See `AppCommand` for why this is a broadcast rather than a direct call.
    @Published var pendingCommand: AppCommandRequest?

    @Published var navigateToDeviceId: String?
    @Published var navigateToTicketId: Int?
    @Published var navigateToFilter: String?
    /// Text dropped into the Inventory search field on arrival — how global
    /// search lands on a specific asset (serial / tag / name), distinct from
    /// `navigateToFilter` which drives the status filter.
    @Published var navigateToInventorySearch: String?
    /// DevOps work item to open in the Projects tab on arrival.
    @Published var navigateToWorkItemId: Int?
    /// A filter to apply in a module tab on arrival — how dashboard chart
    /// wedges/bars deep-link into their section pre-filtered.
    @Published var navigateToModuleFilter: ModuleFilterLink?
    
    // MARK: - Auth Manager
    @Published var authManager: AuthManager
    
    // MARK: - TDX SSO State
    @Published var showTdxSsoLogin = false
    @Published var tdxSsoAuthenticated = false
    @Published var tdxAuthenticatedUserName: String?
    private var ssoViewModel: TdxSsoLoginViewModel?
    
    // MARK: - Snipe-IT SSO State
    @Published var snipeSsoAuthenticated = false
    @Published var snipeAuthenticatedUserName: String?
    private var snipeSsoService: SnipeSsoService?

    // MARK: - Azure DevOps SSO State
    @Published var showDevOpsSsoLogin = false
    @Published var devOpsSsoAuthenticated = false
    @Published var devOpsSsoUserName: String?
    /// UPN the DevOps token was issued to. Azure DevOps work is attributed to the
    /// operator personally -- commits, PRs and work-item edits must carry a real
    /// `@example.edu` identity, never a shared or managed one -- so the panel shows
    /// which account is signed in rather than just a display name.
    @Published var devOpsSsoUserEmail: String?
    @Published var devOpsProjectReady = false
    private var devOpsSsoViewModel: DevOpsSsoLoginViewModel?
    
    // MARK: - Cached Data
    // Data caches with timestamps to avoid reloading on tab switches
    
    @Published var cachedDevices: [IntuneDevice] = []
    @Published var cachedAssets: [SnipeAsset] = []
    @Published var cachedTickets: [TdxTicket] = []
    @Published var cachedWorkItems: [WorkItem] = []
    @Published var cachedUsers: [SnipeUser] = []
    @Published var cachedEntraUsers: [EntraUser] = []
    @Published private(set) var isAssignedUsersLoading = false
    @Published private(set) var assignedUsersLoadAttempted = false
    @Published private(set) var assignedUsersLoadError: String?
    @Published var cachedGroups: [EntraGroup] = []
    private var isPreloadingAllData = false
    private var preloadAllDataRequested = false
    private var sharedQueriesLoadInFlight = false
    /// Snipe activity log for the dashboard feed — cached so tab switches
    /// don't blank the feed while it refetches.
    @Published var cachedSnipeActivity: [SnipeActivityLog] = []
    /// Device members per group id, filled at launch right after the groups
    /// load — so Identity opens with every group expandable instantly and
    /// device-name search can say which groups a device belongs to. Lives
    /// here, not in the tab views: tab switches recreate those views, and a
    /// refetch through aze costs a serialized container exec per call.
    @Published var cachedGroupDevices: [String: [EntraDevice]] = [:]

    /// The dashboard's pull request queue.
    ///
    /// Owned here rather than by DashboardView because ContentView swaps
    /// `tabContent` wholesale on every tab change, which destroys the view and
    /// any @StateObject it holds. The queue would come back empty and refetch
    /// each time you returned to the Dashboard — a visible flash of "DevOps 0 /
    /// GitHub 0" and a spinner where a populated list had been. Living on
    /// AppState, it survives tab switches like the other caches.
    let pullRequestQueue = PullRequestQueueModel()

    /// The dashboard's task tables (DevOps work items + GitHub issues) —
    /// AppState-owned for the same tab-switch-survival reason as the PR queue.
    let dashboardTasks = DashboardTasksModel()

    /// Everything the Projects tab loads from Azure DevOps and GitHub.
    ///
    /// Same reasoning as `pullRequestQueue` above: BoardsView kept all of this in
    /// `@State`, so being destroyed on every tab switch threw the work items away
    /// and refetched them from scratch. Projects was the last tab not sharing the
    /// cache the others use.
    @Published var projects = ProjectsCache()


    // Cache timestamps
    private var devicesCacheTime: Date?
    private var assetsCacheTime: Date?
    private var ticketsCacheTime: Date?
    private var workItemsCacheTime: Date?
    private var usersCacheTime: Date?
    private var groupsCacheTime: Date?
    
    /// Cache duration in seconds (from config.cacheMinutes)
    private var cacheDuration: TimeInterval {
        TimeInterval(config.cacheMinutes * 60)
    }

    // Services (lazy initialization)
    lazy var graphService: GraphService = GraphService(config: config)
    lazy var devOpsService: AzureDevOpsService = AzureDevOpsService(config: config)
    lazy var devOpsSsoService: DevOpsSsoService = DevOpsSsoService(tenantId: config.devopsTenantId ?? config.graphTenantId)
    lazy var tdxService: TdxService = TdxService(config: config)
    lazy var snipeService: SnipeService = SnipeService(config: config)
    lazy var reportMateService: ReportMateService = ReportMateService(config: config)

    init() {
        dbg.info("AppState init starting", category: "startup")

        // Load config - secrets are loaded from secrets.yaml automatically
        let loadedConfig: FleetMateConfig
        do {
            loadedConfig = try FleetMateConfig.load()
            dbg.info("Config loaded OK", category: "startup")
        } catch {
            loadedConfig = FleetMateConfig()
            dbg.error("Config load FAILED: \(error.localizedDescription)", category: "startup")
        }
        self.config = loadedConfig
        self.authManager = AuthManager(config: loadedConfig)

        // Log configuration status
        dbg.info("Graph configured:  \(config.isGraphConfigured)  (tenantId=\(config.graphTenantId != nil), devicesGraphId=\(config.devicesGraphId != nil), systemsGraphId=\(config.systemsGraphId != nil))", category: "config")
        dbg.info("DevOps configured: \(config.isDevOpsConfigured) (org=\(config.devopsOrganization ?? "nil"), project=\(config.devopsProject ?? "nil"), clientId=\(config.devopsClientId != nil), tenantId=\(config.devopsTenantId != nil))", category: "config")
        dbg.info("TDX configured:    \(config.isTdxConfigured)    (baseUrl=\(config.tdxBaseUrl != nil), appId=\(config.tdxAppId != nil), authMethod=\(config.tdxAuthMethod))", category: "config")
        dbg.info("Snipe configured:  \(config.isSnipeConfigured)  (url=\(config.snipeUrl != nil), apiKey=\(config.snipeApiKey != nil))", category: "config")

        // Tasks providers
        if let tasks = config.tasks {
            let azdo = tasks.providers.azdevops
            let gh = tasks.providers.github
            let gitea = tasks.providers.gitea
            dbg.info("Tasks providers: azdevops.enabled=\(azdo?.enabled ?? false) github.enabled=\(gh?.enabled ?? false) gitea.enabled=\(gitea?.enabled ?? false)", category: "config")
            if let az = azdo {
                dbg.info("  azdevops: org=\(az.organization ?? "nil") project=\(az.project ?? "nil")", category: "config")
            }
            if let g = gh {
                dbg.info("  github: org=\(g.organization ?? "nil") owner=\(g.owner ?? "nil") repo=\(g.repo ?? "nil") projectNumber=\(g.projectNumber.map(String.init) ?? "nil")", category: "config")
            }
        } else {
            dbg.warn("No tasks section in config", category: "config")
        }

        // Check if secrets are configured based on loaded config
        secretsConfigured = config.isGraphConfigured || 
                           config.isSnipeConfigured || 
                           config.isTdxConfigured
        if !secretsConfigured {
            showOnboardingWizard = true
        }
        dbg.info("secretsConfigured = \(secretsConfigured)", category: "startup")
        dbg.info("Log file: \(dbg.logFilePath)", category: "startup")
    }

    /// Save credential fields to Keychain and reload services.
    func saveConfig(_ updated: FleetMateConfig) {
        do {
            dbg.info("[SaveConfig] Saving to keychain...", category: "config")
            try FleetMateConfig.saveToKeychain(updated)
            dbg.info("[SaveConfig] Keychain save OK, reloading...", category: "config")
            reloadConfig()
            dbg.info("[SaveConfig] Reload complete. TDX configured: \(config.isTdxConfigured), Snipe configured: \(config.isSnipeConfigured)", category: "config")
        } catch {
            let msg = "Failed to save config: \(error.localizedDescription)"
            dbg.error("[SaveConfig] \(msg)", category: "config")
            errorMessage = msg
        }
    }

    func reloadConfig() {
        do {
            config = try FleetMateConfig.load()
            
            // Check if secrets are configured
            secretsConfigured = config.isGraphConfigured ||
                               config.isSnipeConfigured ||
                               config.isTdxConfigured ||
                               config.isDevOpsConfigured
            
            // Reinitialize services
            graphService = GraphService(config: config)
            devOpsService = AzureDevOpsService(config: config)
            devOpsSsoService = DevOpsSsoService(tenantId: config.devopsTenantId ?? config.graphTenantId)
            tdxService = TdxService(config: config)
            snipeService = SnipeService(config: config)
            reportMateService = ReportMateService(config: config)
            errorMessage = nil

            // Rebuilding devOpsService above threw away its bearer token and
            // refresh handler while devOpsSsoAuthenticated stayed true, so
            // nothing re-triggered SSO — every later call failed with "SSO login
            // required". This runs on any config save, including the one that
            // first sets the DevOps organization. Carry the live session over.
            installDevOpsTokenRefresh()
            if devOpsSsoAuthenticated {
                Task { @MainActor in
                    if let result = try? await self.devOpsSsoService.refreshAccessToken(),
                       result.success, let token = result.accessToken {
                        self.devOpsService.setBearerToken(
                            token,
                            expiry: Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600))
                        )
                    } else {
                        self.devOpsSsoAuthenticated = false
                    }
                }
            }

            // Re-bootstrap auth manager with updated config
            authManager.bootstrapFromConfig(with: config)
            
            // Clear caches on config reload
            invalidateAllCaches()
        } catch {
            errorMessage = "Failed to reload config: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Menu Commands

    /// Broadcast a menu command to whichever tab is on screen.
    func perform(_ command: AppCommand) {
        pendingCommand = AppCommandRequest(command: command)
    }

    // MARK: - Cache Helpers

    /// Check if cache is valid (not expired)
    func isCacheValid(_ cacheTime: Date?) -> Bool {
        guard let cacheTime = cacheTime else { return false }
        return Date().timeIntervalSince(cacheTime) < cacheDuration
    }
    
    /// Invalidate all caches
    func invalidateAllCaches() {
        devicesCacheTime = nil
        assetsCacheTime = nil
        ticketsCacheTime = nil
        workItemsCacheTime = nil
        usersCacheTime = nil
        groupsCacheTime = nil
        cachedDevices = []
        cachedAssets = []
        cachedTickets = []
        cachedWorkItems = []
        cachedUsers = []
        cachedEntraUsers = []
        cachedGroups = []
        cachedGroupDevices = [:]
    }
    
    // MARK: - Data Loading with Caching
    
    /// Check if devices cache is valid
    var isDevicesCacheValid: Bool { isCacheValid(devicesCacheTime) }
    
    /// Check if assets cache is valid
    var isAssetsCacheValid: Bool { isCacheValid(assetsCacheTime) }
    
    /// Check if tickets cache is valid
    var isTicketsCacheValid: Bool { isCacheValid(ticketsCacheTime) }
    
    /// Check if work items cache is valid
    var isWorkItemsCacheValid: Bool { isCacheValid(workItemsCacheTime) }
    
    /// Check if users cache is valid
    var isUsersCacheValid: Bool { isCacheValid(usersCacheTime) }
    
    /// Check if groups cache is valid
    var isGroupsCacheValid: Bool { isCacheValid(groupsCacheTime) }
    
    /// Update devices cache
    func updateDevicesCache(_ devices: [IntuneDevice]) {
        cachedDevices = devices
        devicesCacheTime = Date()
    }
    
    /// Update assets cache
    func updateAssetsCache(_ assets: [SnipeAsset]) {
        cachedAssets = assets
        assetsCacheTime = Date()
    }
    
    /// Update tickets cache
    func updateTicketsCache(_ tickets: [TdxTicket]) {
        cachedTickets = tickets
        ticketsCacheTime = Date()
    }
    
    /// Update work items cache
    func updateWorkItemsCache(_ workItems: [WorkItem]) {
        cachedWorkItems = workItems
        workItemsCacheTime = Date()
    }
    
    /// Update users cache
    func updateUsersCache(snipeUsers: [SnipeUser], entraUsers: [EntraUser]) {
        cachedUsers = snipeUsers
        cachedEntraUsers = entraUsers
        usersCacheTime = Date()
    }
    
    /// Update groups cache
    func updateGroupsCache(_ groups: [EntraGroup]) {
        cachedGroups = groups
        groupsCacheTime = Date()
    }

    /// Invalidate devices cache (force refresh on next load)
    func invalidateDevicesCache() { devicesCacheTime = nil }
    
    /// Invalidate assets cache
    func invalidateAssetsCache() { assetsCacheTime = nil }
    
    /// Invalidate tickets cache
    func invalidateTicketsCache() { ticketsCacheTime = nil }
    
    /// Invalidate work items cache
    func invalidateWorkItemsCache() { workItemsCacheTime = nil }
    
    /// Invalidate users cache
    func invalidateUsersCache() { usersCacheTime = nil }
    
    /// Invalidate groups cache
    func invalidateGroupsCache() { groupsCacheTime = nil }
    
    // MARK: - Background Preloading

    /// Warm the aze elevation sessions (Intune → devices, Entra → identity) so
    /// the ~30s container cold start is paid once at launch rather than on the
    /// user's first action. No-op outside aze mode.
    func warmElevationSessions() async {
        guard config.graphUsesAze else { azeSessionState = .direct; return }
        azeSessionState = .warming
        let warmed = await graphService.warmElevationSessions()
        azeSessionState = warmed ? .warm : .failed
    }

    /// Fill `cachedGroupDevices` for every cached group that doesn't have its
    /// members yet — 20 groups per Graph `$batch` call, merging as each chunk
    /// lands. Through aze every request is one serialized container exec, so
    /// batching (not client-side concurrency) is what makes this fast.
    func preloadGroupMembers() async {
        let pending = cachedGroups.compactMap(\.id).filter { cachedGroupDevices[$0] == nil }
        guard !pending.isEmpty else { return }
        dbg.info("Preloading members for \(pending.count) groups...", category: "preload")
        for chunk in stride(from: 0, to: pending.count, by: 20).map({ Array(pending[$0..<min($0 + 20, pending.count)]) }) {
            do {
                let members = try await graphService.getGroupDeviceMembersBatch(chunk)
                cachedGroupDevices.merge(members) { _, new in new }
            } catch {
                dbg.error("Group member preload chunk failed: \(error)", category: "preload")
            }
        }
        dbg.info("Group members preloaded: \(cachedGroupDevices.count) groups cached", category: "preload")
    }

    /// Fill the Users tab from Intune's managed-device assignments. The
    /// `Devices-Assigned` groups contain device objects, not user objects, so a
    /// Graph user-member cast over that group family cannot produce this roster.
    /// Selecting a row hydrates its complete Entra profile on demand.
    func preloadAssignedUsers(force: Bool = false) async {
        guard !isAssignedUsersLoading else { return }
        guard force || cachedEntraUsers.isEmpty else { return }

        isAssignedUsersLoading = true
        assignedUsersLoadAttempted = true
        assignedUsersLoadError = nil
        defer { isAssignedUsersLoading = false }
        dbg.info("Preloading assigned users...", category: "preload")

        do {
            let devices: [IntuneDevice]
            if force || !isDevicesCacheValid {
                dbg.info("Preloading devices...", category: "preload")
                devices = try await graphService.getManagedDevices(limit: 10000)
                updateDevicesCache(devices)
                dbg.info("Devices preloaded: \(devices.count) devices", category: "preload")
            } else {
                devices = cachedDevices
            }

            var usersByUPN: [String: EntraUser] = [:]
            for device in devices {
                guard let upn = device.userPrincipalName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !upn.isEmpty else { continue }
                let key = upn.lowercased()
                let displayName = device.userDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = usersByUPN[key], existing.displayName?.isEmpty == false {
                    continue
                }
                usersByUPN[key] = EntraUser(
                    id: key,
                    displayName: displayName?.isEmpty == false ? displayName : upn,
                    userPrincipalName: upn,
                    mail: upn
                )
            }

            cachedEntraUsers = usersByUPN.values.sorted {
                ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending
            }
            usersCacheTime = Date()
            dbg.info("Assigned users preloaded: \(cachedEntraUsers.count) users", category: "preload")
        } catch {
            assignedUsersLoadError = error.localizedDescription
            dbg.error("Assigned users preload FAILED: \(error)", category: "preload")
        }
    }

    /// Preload all data sources concurrently in the background
    func preloadAllData() async {
        guard !isPreloadingAllData else {
            preloadAllDataRequested = true
            dbg.info("preloadAllData already running; queued one reconciliation", category: "preload")
            return
        }

        isPreloadingAllData = true
        defer {
            isPreloadingAllData = false
            if preloadAllDataRequested {
                preloadAllDataRequested = false
                Task { @MainActor in
                    await self.preloadAllData()
                }
            }
        }

        dbg.info("preloadAllData starting", category: "preload")
        // Pay the container cold start once, up front, for both Graph domains —
        // so the concurrent loads below reuse warm sessions instead of each
        // racing to create one.
        await warmElevationSessions()
        dbg.info("  Graph configured:  \(config.isGraphConfigured), cache valid: \(isDevicesCacheValid)", category: "preload")
        dbg.info("  Snipe configured:  \(config.isSnipeConfigured), cache valid: \(isAssetsCacheValid)", category: "preload")
        dbg.info("  TDX configured:    \(config.isTdxConfigured), cache valid: \(isTicketsCacheValid)", category: "preload")
        dbg.info("  Systems Graph:     \(config.isSystemsGraphConfigured), cache valid: \(isGroupsCacheValid)", category: "preload")
        dbg.info("  DevOps configured: \(config.isDevOpsConfigured), cache valid: \(isWorkItemsCacheValid)", category: "preload")

        await withTaskGroup(of: Void.self) { group in
            // Managed devices also carry the assigned-user roster used by the
            // Users tab and global search, so populate both in one request.
            if config.isGraphConfigured && (!isDevicesCacheValid || cachedEntraUsers.isEmpty) {
                group.addTask { @MainActor in
                    await self.preloadAssignedUsers()
                }
            }
            
            // Preload assets
            if config.isSnipeConfigured && !isAssetsCacheValid {
                group.addTask { @MainActor in
                    dbg.info("Preloading assets...", category: "preload")
                    do {
                        let assets = try await self.snipeService.getAllAssets()
                        self.updateAssetsCache(assets)
                        dbg.info("Assets preloaded: \(assets.count) assets", category: "preload")
                    } catch {
                        dbg.error("Assets preload FAILED: \(error)", category: "preload")
                    }
                }
            }
            
            // Preload tickets
            if config.isTdxConfigured && !isTicketsCacheValid {
                group.addTask { @MainActor in
                    dbg.info("Preloading tickets...", category: "preload")
                    do {
                        var search = TicketSearchRequest(maxResults: 500)
                        if let groupId = self.config.tdxResponsibleGroupId {
                            search.responsibleGroupIds = [groupId]
                        }
                        let tickets = try await self.tdxService.searchTickets(search: search, maxResults: 500)
                        self.updateTicketsCache(tickets)
                        dbg.info("Tickets preloaded: \(tickets.count) tickets", category: "preload")
                    } catch {
                        dbg.error("Tickets preload FAILED: \(error)", category: "preload")
                    }
                }
            }

            // Resolve who "me" is in TDX, so Assign to me is ready on first use
            if config.isTdxConfigured && tdxMe == nil {
                group.addTask { @MainActor in
                    await self.resolveTdxMe()
                }
            }

            if config.isSystemsGraphConfigured {
                group.addTask { @MainActor in
                    if !self.isGroupsCacheValid {
                        dbg.info("Preloading groups...", category: "preload")
                        do {
                            let groups = try await self.graphService.searchGroups("Devices-", limit: DeviceGroupFetch.limit)
                            self.updateGroupsCache(groups)
                            dbg.info("Groups preloaded: \(groups.count) groups", category: "preload")
                        } catch {
                            dbg.error("Groups preload FAILED: \(error)", category: "preload")
                        }
                    }

                    // Group list was still fresh — warm any members not yet
                    // loaded this launch (the method skips cached groups).
                    await self.preloadGroupMembers()
                }
            }
            
            // Preload work items (DevOps) — only if we already have a valid token.
            // SSO runs concurrently; if the token isn't ready yet, BoardsView will
            // load work items on demand once auth completes.
            if config.isDevOpsConfigured && !isWorkItemsCacheValid && devOpsService.hasValidToken {
                group.addTask { @MainActor in
                    dbg.info("Preloading work items...", category: "preload")
                    do {
                        let items = try await self.devOpsService.getWorkItems(limit: 200)
                        self.updateWorkItemsCache(items)
                        dbg.info("Work items preloaded: \(items.count) items", category: "preload")
                    } catch {
                        dbg.error("Work items preload FAILED: \(error)", category: "preload")
                    }
                }
            }

            // Preload Projects (DevOps work items + GitHub issues).
            //
            // Same token guard as work items above: a registry built before the
            // DevOps token lands would return GitHub issues only, and marking the
            // cache loaded would leave Projects looking half-empty until a manual
            // refresh. Better to let BoardsView load it on demand in that case.
            let ghEnabled = config.tasks?.providers.github?.enabled == true
            let azdoReady = config.isDevOpsConfigured && devOpsService.hasValidToken
            if projects.loadedAt == nil, azdoReady || (ghEnabled && !config.isDevOpsConfigured) {
                group.addTask { @MainActor in
                    dbg.info("Preloading projects...", category: "preload")
                    do {
                        let config = try FleetMateConfig.load()
                        let registry = await self.makeTaskRegistry(config: config)

                        let bucketsByProvider = await registry.listAllBuckets()
                        self.projects.buckets = Array(Set(
                            bucketsByProvider.values.flatMap { $0.map(\.name) }
                        )).sorted()

                        var filter = TaskFilter()
                        filter.includeClosed = true
                        filter.limit = 500
                        self.projects.allTasks = await registry.listTasks(filter: filter)
                        self.projects.syncEnabled =
                            (config.tasks?.planner != nil) || (config.tasks?.markdown != nil)
                        self.projects.loadedAt = Date()
                        dbg.info("Projects preloaded: \(self.projects.allTasks.count) tasks", category: "preload")
                    } catch {
                        dbg.error("Projects preload FAILED: \(error)", category: "preload")
                    }
                }
            }
        }
        dbg.info("preloadAllData finished", category: "preload")

        // Shared queries load after the fan-out above: they need the resolved
        // project, and their own fan-out (one WIQL per query) is heavy enough
        // not to race the first-paint loads.
        await preloadSharedQueries()

        // Probe auth status for all configured systems
        await authManager.probeAll(
            graphService: graphService,
            tdxService: tdxService,
            snipeService: snipeService,
            devOpsService: devOpsService
        )
    }
    
    // MARK: - Task Providers

    /// Build the task provider registry (Azure DevOps, GitHub Projects, Gitea)
    /// and authenticate each one.
    ///
    /// Lives here rather than in BoardsView so the launch preload and the view
    /// build an identical registry. `authenticateAll()` isolates per-provider
    /// failures, so one dead provider doesn't take the others down.
    func makeTaskRegistry(config: FleetMateConfig) async -> TaskProviderRegistry {
        dbg.info("makeTaskRegistry starting — devOpsService.hasValidToken=\(devOpsService.hasValidToken) org=\(config.devopsOrganization ?? "nil") project=\(config.devopsProject ?? "nil")", category: "boards")
        let registry = TaskProviderRegistry()
        let azdo   = AzureDevOpsTaskProvider(service: devOpsService, config: config)
        let github = GitHubProjectsTaskProvider(config: config.tasks?.providers.github ?? GitHubProviderConfig())
        let gitea  = GiteaTaskProvider(config: config)

        await registry.registerProvider(azdo)
        await registry.registerProvider(github)
        await registry.registerProvider(gitea)

        dbg.info("Registered providers: azdo.enabled=\(await azdo.isEnabled) github.enabled=\(await github.isEnabled) gitea.enabled=\(await gitea.isEnabled)", category: "boards")

        let authResults = await registry.authenticateAll()
        for (id, success) in authResults {
            dbg.info("Provider \(id) auth: \(success ? "OK" : "FAILED")", category: "boards")
        }
        return registry
    }

    // MARK: - TDX SSO Authentication
    
    /// Check if TDX SSO login is required
    var requiresTdxSsoLogin: Bool {
        return tdxService.requiresSsoLogin && !tdxSsoAuthenticated
    }
    
    /// Phase 1: Attempt silent SSO authentication (no UI).
    /// Tries a URLSession-only check — succeeds when a valid Shibboleth/Platform
    /// SSO session is already present in the system.
    /// If it fails, does NOT show any UI. The interactive Phase 2 sheet is
    /// triggered later, only when the user navigates to a tab that needs auth.
    /// Put the device's Entra PRT cookie into shared storage so the silent SAML
    /// chain authenticates without a prompt. No-op when the broker declines.
    func primeEntraPrtCookies() async {
        guard let entraUrl = URL(string: "https://login.microsoftonline.com/\(config.effectiveAzureTenantId)/saml2") else { return }
        let cookies = await EntraPrtCookieProvider().ssoCookies(for: entraUrl)
        guard !cookies.isEmpty else { return }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        dbg.info("[PRT] Installed \(cookies.count) PRT cookie(s) for the silent SAML chain", category: "tdx-sso")
    }

    func attemptSilentTdxSso() {
        guard ssoViewModel == nil else { return }
        dbg.info("[SSO Phase 1] Starting silent TDX SSO attempt (authMethod=\(config.tdxAuthMethod), ssoEnabled=\(config.tdxSsoEnabled))", category: "tdx-sso")

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Resolve the sign-in address before the flow starts. Entra's page
            // needs a username to advance, `app-sso` doesn't reliably supply
            // one, and arriving with it late means the attempt has already
            // timed out onto the service account.
            await self.primeTdxSsoUpn()

            // Phase 0: ask the Entra broker for the device's PRT cookie and put
            // it in shared cookie storage, which the silent URLSession chain
            // below already reads from. Without it Entra answers that chain with
            // its interactive sign-in page, because the SSO plug-in acts only on
            // requests an app actually makes — it does not intercept traffic.
            await self.primeEntraPrtCookies()

            let viewModel = TdxSsoLoginViewModel(config: self.config)
            self.ssoViewModel = viewModel

            let silentSuccess = await viewModel.performSilentAuthentication()
            self.ssoViewModel = nil

            if silentSuccess,
               let result = viewModel.authResult,
               result.success,
               let token = result.token {
                // Got JWT from cached session — fully silent
                let expiry = Date().addingTimeInterval(23 * 60 * 60)
                dbg.info("[SSO Phase 1] Silent SSO SUCCEEDED — user=\(result.userName ?? "unknown") email=\(result.userEmail ?? "unknown")", category: "tdx-sso")
                self.handleTdxSsoSuccess(
                    token: token,
                    expiry: expiry,
                    userId: result.userEmail,
                    userName: result.userName
                )
            } else {
                dbg.warn("[SSO Phase 1] Silent SSO FAILED — will attempt headless WKWebView (Phase 1.5)", category: "tdx-sso")
                // Phase 1.5: Try headless WKWebView SSO before falling back to interactive sheet
                self.attemptHeadlessTdxSso()
            }
        }
    }
    
    /// Phase 1.5: Attempt SSO using a hidden WKWebView.
    /// The Enterprise SSO Extension can intercept WKWebView requests (but not plain URLSession),
    /// so this may complete silently where Phase 1 failed.
    func attemptHeadlessTdxSso() {
        guard ssoViewModel == nil else { return }
        dbg.info("[SSO Phase 1.5] Starting headless WKWebView SSO attempt", category: "tdx-sso")

        let viewModel = TdxSsoLoginViewModel(config: config)
        ssoViewModel = viewModel

        // Create a hidden off-screen window to host the WKWebView
        let hiddenWindow = NSWindow(
            contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        hiddenWindow.isReleasedWhenClosed = false
        hiddenWindow.orderOut(nil)

        // Attach the WebView to the hidden window so SSO Extension can intercept
        let webView = viewModel.webView
        hiddenWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        // Start the WebView-based SSO flow
        viewModel.startAuthentication()

        // Watch for completion with a timeout
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Wait up to 95 seconds for headless SSO to complete. 25s was
            // calibrated for a chain that either completes or doesn't; it
            // guillotined any method that involves the person's phone — an
            // Authenticator push needs the fallback script to request it
            // (~10-20s in) plus however long a human takes to tap approve.
            let deadline = Date().addingTimeInterval(95)
            while Date() < deadline {
                if let result = viewModel.authResult {
                    self.ssoViewModel = nil
                    hiddenWindow.close()
                    if result.success, let token = result.token {
                        let expiry = Date().addingTimeInterval(23 * 60 * 60)
                        dbg.info("[SSO Phase 1.5] Headless WKWebView SSO SUCCEEDED — user=\(result.userName ?? "unknown")", category: "tdx-sso")
                        self.handleTdxSsoSuccess(
                            token: token,
                            expiry: expiry,
                            userId: result.userEmail,
                            userName: result.userName
                        )
                        return
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s poll
            }

            self.ssoViewModel = nil
            hiddenWindow.close()
            // Deliberately does NOT touch the TDX auth badge here: probeAll
            // verifies TDX independently, and reporting a failure from this
            // racing task is how the panel once showed "Failed: Silent SSO
            // failed" directly above a green "signed in" row.
            // Not "unaffected" any more: with no service account configured,
            // this is the only way in, so a failure here means no TDX access
            // until someone signs in.
            dbg.warn("[SSO Phase 1.5] Headless WKWebView SSO FAILED or timed out — TDX calls will fail until an interactive sign-in succeeds", category: "tdx-sso")
        }
    }

    /// Phase 2: Trigger interactive TDX SSO login (shows WebView sheet).
    /// Called when the user navigates to a tab that requires TDX authentication
    /// and silent Phase 1 didn't succeed.
    func triggerTdxSsoLogin() {
        showTdxSsoLogin = true
    }

    /// Tear down any in-progress silent SSO attempt
    private func cleanupSsoWindow() {
        ssoViewModel = nil
    }
    
    /// Handle successful SSO authentication
    func handleTdxSsoSuccess(token: String, expiry: Date, userId: String?, userName: String?) {
        // If token isn't a real JWT, use cookie-based auth instead
        if !token.hasPrefix("eyJ") {
            // Extract cookies from shared storage for the TDX domain
            if let baseUrl = config.tdxBaseUrl, let url = URL(string: baseUrl) {
                let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
                if !cookies.isEmpty {
                    tdxService.setSsoCookies(cookies, userName: userName)
                } else {
                    tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
                }
            } else {
                tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
            }
        } else {
            tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
        }
        tdxSsoAuthenticated = true
        tdxAuthenticatedUserName = userName
        showTdxSsoLogin = false
        authManager.update(.tdx, state: .valid(user: userName, expiry: expiry))
        
        // Resolve the actual TDX UID from the email — SSO returns email, not TDX UID
        if let email = userId, !email.isEmpty {
            Task {
                do {
                    let people = try await tdxService.searchPeople(searchText: email, maxResults: 1)
                    if let person = people.first, let uid = person.uid {
                        tdxService.setSsoToken(token, expiry: expiry, userId: uid, userName: userName)
                    }
                } catch {
                    // Non-fatal — keep the email as fallback
                }
            }
        }
        
        // Invalidate tickets cache and reload data
        invalidateTicketsCache()
        Task {
            await preloadAllData()
        }
    }
    
    /// Handle SSO authentication failure or cancellation
    func handleTdxSsoFailure(_ error: String?) {
        showTdxSsoLogin = false
        if let error = error {
            errorMessage = "TDX SSO login failed: \(error)"
            authManager.update(.tdx, state: .failed(message: error))
        }
    }
    
    /// Sign out of TDX SSO
    func signOutTdxSso() {
        tdxService.clearSsoToken()
        tdxSsoAuthenticated = false
        tdxAuthenticatedUserName = nil
        tdxMe = nil
        authManager.update(.tdx, state: .configured)
        invalidateTicketsCache()
    }

    // MARK: - TDX Identity ("me")

    /// The TDX person record for whoever is driving the app.
    ///
    /// TDX's Web API always authenticates as the service account, so the session
    /// itself can't say who you are. This is resolved separately from the
    /// signed-in Azure identity and is what "Assign to me" acts on.
    @Published var tdxMe: TdxPerson?

    /// Email addresses to try when resolving `tdxMe`, best first.
    private func tdxIdentityCandidates() async -> [String] {
        var candidates: [String] = []
        if let email = devOpsSsoUserEmail, !email.isEmpty { candidates.append(email) }
        if let account = await devOpsService.currentIdentity().account, !account.isEmpty {
            candidates.append(account)
        }
        if let name = tdxAuthenticatedUserName, name.contains("@") { candidates.append(name) }
        return candidates
    }

    /// Make the signed-in address available to the TDX SSO flow.
    ///
    /// `app-sso platform -s` is not a reliable source: on an enrolled Mac it
    /// can expose no `upn` key at all and mask `loginUserName` as
    /// `a***e@example.edu`. The Azure identity has the real address.
    func primeTdxSsoUpn() async {
        guard TdxSsoLoginViewModel.fallbackUpn == nil else { return }

        if let email = devOpsSsoUserEmail, !email.isEmpty {
            TdxSsoLoginViewModel.fallbackUpn = email.lowercased()
            return
        }
        if let account = await devOpsService.currentIdentity().account, !account.isEmpty {
            TdxSsoLoginViewModel.fallbackUpn = account.lowercased()
        }
    }

    /// Resolve and cache the current user's TDX person record. Cheap to call
    /// repeatedly — it returns immediately once resolved.
    func resolveTdxMe() async {
        guard tdxMe == nil, config.isTdxConfigured else { return }

        for email in await tdxIdentityCandidates() {
            do {
                if let person = try await tdxService.findPerson(email: email) {
                    dbg.info("TDX identity resolved: \(person.fullName ?? "?") via \(email)", category: "tdx")
                    tdxMe = person
                    return
                }
            } catch {
                dbg.warn("TDX identity lookup failed for \(email): \(error.localizedDescription)", category: "tdx")
            }
        }
        dbg.warn("TDX identity unresolved — no signed-in email matched a TDX person", category: "tdx")
    }
    
    // MARK: - Azure DevOps SSO Authentication
    
    /// True if DevOps is configured (org + project set)
    var isDevOpsSsoConfigured: Bool {
        config.isDevOpsConfigured
    }

    /// Phase 1: Attempt silent SSO authentication (az CLI → MSAL cache → refresh token).
    /// No Keychain prompts. If it fails, Phase 1.5 headless WKWebView is tried next.
    func attemptSilentDevOpsSso() {
        guard devOpsSsoViewModel == nil else { return }
        dbg.info("[DevOps SSO Phase 1] Starting silent token acquisition (az CLI → MSAL cache)", category: "devops-sso")

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Try az CLI + MSAL cache (no UI needed)
            do {
                let result = try await self.devOpsSsoService.refreshAccessToken()
                if result.success, let token = result.accessToken {
                    let expiry = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600))
                    dbg.info("[DevOps SSO Phase 1] Silent token acquired — user=\(result.userName ?? "unknown")", category: "devops-sso")
                    self.handleDevOpsSsoSuccess(
                        accessToken: token,
                        expiry: expiry,
                        userName: result.userName,
                        userEmail: result.userEmail
                    )
                    return
                }
            } catch {
                dbg.warn("[DevOps SSO Phase 1] Token acquisition failed: \(error)", category: "devops-sso")
            }

            dbg.warn("[DevOps SSO Phase 1] Silent acquisition failed — trying headless WKWebView (Phase 1.5)", category: "devops-sso")
            self.attemptHeadlessDevOpsSso()
        }
    }

    /// Phase 1.5: Attempt SSO using a hidden WKWebView.
    /// Platform SSO Extension intercepts WKWebView requests to login.microsoftonline.com
    /// and handles auth silently (Kerberos/FIDO).
    func attemptHeadlessDevOpsSso() {
        guard devOpsSsoViewModel == nil else { return }
        dbg.info("[DevOps SSO Phase 1.5] Starting headless WKWebView SSO attempt", category: "devops-sso")

        let viewModel = DevOpsSsoLoginViewModel(ssoService: devOpsSsoService, config: config)
        devOpsSsoViewModel = viewModel

        // Create a hidden off-screen window to host the WKWebView
        let hiddenWindow = NSWindow(
            contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        hiddenWindow.isReleasedWhenClosed = false
        hiddenWindow.orderOut(nil)

        // Attach the WebView so SSO Extension can intercept network requests
        let webView = viewModel.webView
        hiddenWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        // Start the OAuth2 flow in the hidden WebView
        viewModel.startAuthentication()

        // Poll for completion with timeout
        Task { @MainActor [weak self] in
            guard let self else { return }

            // 40s timeout: auth flow needs ~8s for autologon, ~15s for FIDO fallback
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline {
                if let result = viewModel.authResult {
                    self.devOpsSsoViewModel = nil
                    hiddenWindow.close()
                    if result.success, let token = result.accessToken {
                        let expiry = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600))
                        dbg.info("[DevOps SSO Phase 1.5] Headless SSO SUCCEEDED — user=\(result.userName ?? "unknown")", category: "devops-sso")
                        self.handleDevOpsSsoSuccess(
                            accessToken: token,
                            expiry: expiry,
                            userName: result.userName,
                            userEmail: result.userEmail
                        )
                        return
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s poll
            }

            self.devOpsSsoViewModel = nil
            hiddenWindow.close()
            dbg.warn("[DevOps SSO Phase 1.5] Headless SSO FAILED or timed out — auth unavailable (no interactive fallback)", category: "devops-sso")
            self.authManager.reportOptionalAuthFailure(.devops, message: "Silent SSO failed")
        }
    }

    /// Phase 2: Show interactive OAuth2 login sheet.
    func triggerDevOpsSsoLogin() {
        showDevOpsSsoLogin = true
    }

    /// Handle successful DevOps SSO authentication
    func handleDevOpsSsoSuccess(accessToken: String, expiry: Date, userName: String?, userEmail: String?) {
        // Inject token into the REST API service
        devOpsService.setBearerToken(accessToken, expiry: expiry)
        installDevOpsTokenRefresh()
        devOpsSsoAuthenticated = true
        devOpsSsoUserName = userName
        devOpsSsoUserEmail = userEmail
        showDevOpsSsoLogin = false

        // TDX SSO may already be waiting on an address to put in Entra's
        // username field; this is the earliest point one is known.
        Task { @MainActor in await self.primeTdxSsoUpn() }
        // Prefer the UPN: it is the identity Azure DevOps actually attributes
        // work to, and a display name alone cannot show that.
        authManager.update(.devops, state: .valid(user: userEmail ?? userName, expiry: expiry))

        // Invalidate work items cache to reload with new auth
        invalidateWorkItemsCache()

        // Auto-discover a default project (for sprints/boards, which are project-scoped).
        // Work items use org-level WIQL and don't need this.
        Task {
            do {
                if devOpsService.resolvedProject.isEmpty {
                    dbg.info("[DevOps] Running project discovery (for sprints/boards context)", category: "devops-sso")
                    let discovered = try await devOpsService.discoverProject()
                    dbg.info("[DevOps] Default project: \(discovered ?? "none")", category: "devops-sso")
                }
            } catch {
                dbg.warn("[DevOps] Project discovery failed (non-fatal): \(error)", category: "devops-sso")
            }
            // Signal that DevOps is ready — BoardsView observes this to reload
            await MainActor.run { self.devOpsProjectReady = true }
            await self.preloadSharedQueries()
        }
    }

    /// Load every Shared Query in the resolved DevOps project and run them
    /// all concurrently into the Projects cache. Called from the launch
    /// preload and again when DevOps auth lands; BoardsView delegates here so
    /// the view and the preload share one implementation.
    func preloadSharedQueries(force: Bool = false) async {
        guard config.isDevOpsConfigured else { return }
        guard devOpsService.hasValidToken else {
            projects.queriesLoadError = "Not signed in to Azure DevOps."
            return
        }
        let project = devOpsService.resolvedProject
        guard !project.isEmpty else {
            dbg.debug("Shared queries preload: no resolved project yet", category: "preload")
            projects.queriesLoadError = "No Azure DevOps project resolved yet."
            return
        }
        if !force, projects.queriesLoadedAt != nil { return }
        // The launch preload and the Projects tab can both land here; one
        // fan-out of 35 concurrent query runs at a time is plenty.
        guard !sharedQueriesLoadInFlight else { return }
        sharedQueriesLoadInFlight = true
        defer { sharedQueriesLoadInFlight = false }
        let service = devOpsService

        do {
            let queries = try await service.getSharedQueries(project: project)

            let runsById = await withTaskGroup(of: (String, StoredQueryRun)?.self) { group in
                for query in queries {
                    group.addTask {
                        do {
                            let run = try await service.runStoredQuery(id: query.id, project: project)
                            return (query.id, run)
                        } catch {
                            dbg.warn("Query '\(query.name)' failed: \(error)", category: "preload")
                            return nil
                        }
                    }
                }
                var collected: [String: StoredQueryRun] = [:]
                for await result in group {
                    if let (id, run) = result { collected[id] = run }
                }
                return collected
            }

            var display: [String: QueryRunDisplay] = [:]
            for query in queries {
                guard let run = runsById[query.id] else { continue }
                let rows = run.rows.map {
                    QueryDisplayRow(
                        task: $0.item.asUnifiedTask(),
                        depth: $0.depth,
                        hasChildren: $0.hasChildren,
                        queryId: query.id
                    )
                }
                display[query.id] = QueryRunDisplay(
                    query: query,
                    rows: rows,
                    truncated: run.truncated,
                    areaBucket: QueryRunDisplay.areaBucket(rows: rows, queryName: query.name)
                )
            }
            projects.sharedQueries = queries
            projects.queryRuns = display
            projects.queriesLoadedAt = Date()
            projects.queriesLoadError = nil
            let rowCount = display.values.reduce(0) { $0 + $1.rows.count }
            dbg.info("Shared queries preloaded: \(display.count)/\(queries.count) queries, \(rowCount) rows", category: "preload")
        } catch {
            dbg.error("Shared queries preload FAILED: \(error)", category: "preload")
            projects.queriesLoadError = error.localizedDescription
            // The request was refused, not answered — surface it on the auth
            // panel too, so the shield says why the tab is empty.
            authManager.update(.devops, state: .failed(message: error.localizedDescription))
        }
    }

    /// Handle SSO authentication failure or cancellation
    func handleDevOpsSsoFailure(_ error: String?) {
        showDevOpsSsoLogin = false
        if let error = error {
            errorMessage = "DevOps SSO login failed: \(error)"
            authManager.update(.devops, state: .failed(message: error))
        }
    }

    /// Let the REST service re-acquire a token by itself when Azure DevOps
    /// rejects the one it holds.
    ///
    /// Without this a 401 mid-session was terminal for the request: the board
    /// stayed populated from cache while opening any item reported "Not
    /// authenticated to Azure DevOps. SSO login required." — even though the
    /// `az` sign-in behind it was still good and a fresh token was available
    /// silently.
    func installDevOpsTokenRefresh() {
        devOpsService.tokenRefreshHandler = { [weak self] in
            guard let self else { return nil }
            do {
                let result = try await self.devOpsSsoService.refreshAccessToken()
                guard result.success, let token = result.accessToken else { return nil }
                let expiry = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600))
                dbg.info("DevOps token re-acquired after rejection", category: "devops-sso")
                return (token, expiry)
            } catch {
                dbg.warn("DevOps token re-acquisition failed: \(error)", category: "devops-sso")
                return nil
            }
        }
    }

    /// Sign out of DevOps SSO
    func signOutDevOpsSso() {
        devOpsSsoService.clearTokens()
        devOpsService.clearBearerToken()
        devOpsSsoAuthenticated = false
        devOpsSsoUserName = nil
        devOpsSsoUserEmail = nil
        authManager.update(.devops, state: .configured)
        invalidateWorkItemsCache()
    }

    // MARK: - Snipe-IT SSO Authentication

    /// Phase 1: Attempt silent SSO via URLSession (cached cookies).
    func attemptSilentSnipeSso() {
        guard let url = config.snipeUrl, !url.isEmpty else { return }
        dbg.info("[Snipe SSO Phase 1] Starting silent cookie check", category: "snipe-sso")

        let service = SnipeSsoService(snipeUrl: url)
        snipeSsoService = service

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await service.attemptSilentAuth()
            self.snipeSsoService = nil

            if result.success {
                dbg.info("[Snipe SSO Phase 1] Silent SSO SUCCEEDED — user=\(result.userName ?? "unknown")", category: "snipe-sso")
                self.handleSnipeSsoSuccess(cookies: result.cookies, userName: result.userName)
            } else {
                dbg.warn("[Snipe SSO Phase 1] Silent SSO FAILED — trying headless WKWebView (Phase 1.5)", category: "snipe-sso")
                self.attemptHeadlessSnipeSso()
            }
        }
    }

    /// Phase 1.5: Attempt SSO using a hidden WKWebView.
    func attemptHeadlessSnipeSso() {
        guard let url = config.snipeUrl, !url.isEmpty else { return }
        dbg.info("[Snipe SSO Phase 1.5] Starting headless WKWebView SSO", category: "snipe-sso")

        let service = SnipeSsoService(snipeUrl: url)
        snipeSsoService = service

        let hiddenWindow = NSWindow(
            contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        hiddenWindow.isReleasedWhenClosed = false
        hiddenWindow.orderOut(nil)

        let webView = service.createWebView()
        hiddenWindow.contentView = webView
        webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        service.startAuthentication()

        Task { @MainActor [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline {
                if let result = service.authResult {
                    self.snipeSsoService = nil
                    hiddenWindow.close()
                    if result.success {
                        dbg.info("[Snipe SSO Phase 1.5] Headless SSO SUCCEEDED — user=\(result.userName ?? "unknown")", category: "snipe-sso")
                        self.handleSnipeSsoSuccess(cookies: result.cookies, userName: result.userName)
                        return
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            self.snipeSsoService = nil
            hiddenWindow.close()
            dbg.warn("[Snipe SSO Phase 1.5] Headless SSO FAILED or timed out", category: "snipe-sso")
            self.authManager.reportOptionalAuthFailure(.snipe, message: "Silent SSO failed")
        }
    }

    func handleSnipeSsoSuccess(cookies: [HTTPCookie], userName: String?) {
        snipeService.setSsoCookies(cookies, userName: userName)
        snipeSsoAuthenticated = true
        snipeAuthenticatedUserName = userName
        authManager.update(.snipe, state: .valid(user: userName, expiry: nil))
        invalidateAssetsCache()
    }

    func signOutSnipeSso() {
        snipeService.clearSsoCookies()
        snipeSsoAuthenticated = false
        snipeAuthenticatedUserName = nil
        authManager.update(.snipe, state: .configured)
        invalidateAssetsCache()
    }
}
