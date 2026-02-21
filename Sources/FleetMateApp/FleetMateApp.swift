import SwiftUI
import Combine
import FleetMateCore

@main
struct FleetMateApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        // Ensure app appears in Dock and can be activated
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.preloadAllData()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            // Standard Edit menu with Cut/Copy/Paste/Select All
            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        #endif
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var config: FleetMateConfig
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var secretsConfigured = false
    
    // MARK: - Tab Navigation (set by Dashboard to switch tabs)
    @Published var navigateToTab: String?
    
    // MARK: - Auth Manager
    @Published var authManager: AuthManager
    
    // MARK: - TDX SSO State
    @Published var showTdxSsoLogin = false
    @Published var tdxSsoAuthenticated = false
    @Published var tdxAuthenticatedUserName: String?
    private var ssoViewModel: TdxSsoLoginViewModel?
    
    // MARK: - Azure DevOps Auth State (managed via az CLI)
    @Published var devOpsAzLoginRunning = false
    
    // MARK: - Cached Data
    // Data caches with timestamps to avoid reloading on tab switches
    
    @Published var cachedDevices: [IntuneDevice] = []
    @Published var cachedAssets: [SnipeAsset] = []
    @Published var cachedTickets: [TdxTicket] = []
    @Published var cachedWorkItems: [WorkItem] = []
    @Published var cachedUsers: [SnipeUser] = []
    @Published var cachedEntraUsers: [EntraUser] = []
    @Published var cachedGroups: [EntraGroup] = []
    
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
    lazy var tdxService: TdxService = TdxService(config: config)
    lazy var snipeService: SnipeService = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
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
        dbg.info("secretsConfigured = \(secretsConfigured)", category: "startup")
        dbg.info("Log file: \(dbg.logFilePath)", category: "startup")
    }

    func reloadConfig() {
        do {
            config = try FleetMateConfig.load()
            
            // Check if secrets are configured
            secretsConfigured = config.isGraphConfigured || 
                               config.isSnipeConfigured || 
                               config.isTdxConfigured
            
            // Reinitialize services
            graphService = GraphService(config: config)
            devOpsService = AzureDevOpsService(config: config)
            tdxService = TdxService(config: config)
            snipeService = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
            reportMateService = ReportMateService(config: config)
            errorMessage = nil
            
            // Re-bootstrap auth manager
            authManager.bootstrapFromConfig()
            
            // Clear caches on config reload
            invalidateAllCaches()
        } catch {
            errorMessage = "Failed to reload config: \(error.localizedDescription)"
        }
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
    
    /// Preload all data sources concurrently in the background
    func preloadAllData() async {
        dbg.info("preloadAllData starting", category: "preload")
        dbg.info("  Graph configured:  \(config.isGraphConfigured), cache valid: \(isDevicesCacheValid)", category: "preload")
        dbg.info("  Snipe configured:  \(config.isSnipeConfigured), cache valid: \(isAssetsCacheValid)", category: "preload")
        dbg.info("  TDX configured:    \(config.isTdxConfigured), cache valid: \(isTicketsCacheValid)", category: "preload")
        dbg.info("  Systems Graph:     \(config.isSystemsGraphConfigured), cache valid: \(isGroupsCacheValid)", category: "preload")

        await withTaskGroup(of: Void.self) { group in
            // Preload devices
            if config.isGraphConfigured && !isDevicesCacheValid {
                group.addTask { @MainActor in
                    dbg.info("Preloading devices...", category: "preload")
                    do {
                        let devices = try await self.graphService.getManagedDevices(limit: 10000)
                        self.updateDevicesCache(devices)
                        dbg.info("Devices preloaded: \(devices.count) devices", category: "preload")
                    } catch {
                        dbg.error("Devices preload FAILED: \(error)", category: "preload")
                    }
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
            
            // Preload groups
            if config.isSystemsGraphConfigured && !isGroupsCacheValid {
                group.addTask { @MainActor in
                    dbg.info("Preloading groups...", category: "preload")
                    do {
                        let groups = try await self.graphService.searchGroups("Devices-", limit: 100)
                        self.updateGroupsCache(groups)
                        dbg.info("Groups preloaded: \(groups.count) groups", category: "preload")
                    } catch {
                        dbg.error("Groups preload FAILED: \(error)", category: "preload")
                    }
                }
            }
        }
        dbg.info("preloadAllData finished", category: "preload")

        // Probe auth status for all configured systems
        await authManager.probeAll(
            graphService: graphService,
            tdxService: tdxService,
            snipeService: snipeService,
            devOpsService: devOpsService
        )
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
    func attemptSilentTdxSso() {
        guard ssoViewModel == nil else { return }

        let viewModel = TdxSsoLoginViewModel(config: config)
        ssoViewModel = viewModel

        Task { @MainActor [weak self] in
            guard let self else { return }
            let silentSuccess = await viewModel.performSilentAuthentication()
            self.ssoViewModel = nil

            if silentSuccess,
               let result = viewModel.authResult,
               result.success,
               let token = result.token {
                // Got JWT from cached session — fully silent
                let expiry = Date().addingTimeInterval(23 * 60 * 60)
                self.handleTdxSsoSuccess(
                    token: token,
                    expiry: expiry,
                    userId: result.userEmail,
                    userName: result.userName
                )
            }
            // Phase 1 failed — do nothing. Phase 2 is triggered on-demand
            // when the user navigates to a tab that requires TDX auth.
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
        tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
        tdxSsoAuthenticated = true
        tdxAuthenticatedUserName = userName
        showTdxSsoLogin = false
        authManager.update(.tdx, state: .valid(user: userName, expiry: expiry))
        
        // Invalidate tickets cache to reload with new auth
        invalidateTicketsCache()
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
        authManager.update(.tdx, state: .configured)
        invalidateTicketsCache()
    }
    
    // MARK: - Azure DevOps SSO Authentication
    
    /// True if `az` CLI is installed (DevOps auth is always via az login)
    var isDevOpsSsoConfigured: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/az") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/az")
    }

    /// Launch `az login` — az CLI opens the browser and handles OAuth2 itself.
    func triggerDevOpsSsoLogin() {
        guard !devOpsAzLoginRunning else { return }
        devOpsAzLoginRunning = true
        Task {
            await authManager.loginDevOps(devOpsService: devOpsService)
            devOpsAzLoginRunning = false
            invalidateWorkItemsCache()
        }
    }

    /// Run `az logout` and reset DevOps auth state.
    func signOutDevOpsSso() {
        Task {
            await authManager.logoutDevOps(devOpsService: devOpsService)
            invalidateWorkItemsCache()
        }
    }
}
