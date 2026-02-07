import SwiftUI
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
    
    // MARK: - TDX SSO State
    @Published var showTdxSsoLogin = false
    @Published var tdxSsoAuthenticated = false
    @Published var tdxAuthenticatedUserName: String?
    
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

    init() {
        // Load config - secrets are loaded from secrets.yaml automatically
        do {
            self.config = try FleetMateConfig.load()
        } catch {
            self.config = FleetMateConfig()
            self.errorMessage = "Failed to load config: \(error.localizedDescription)"
        }
        
        // Check if secrets are configured based on loaded config
        secretsConfigured = config.isGraphConfigured || 
                           config.isSnipeConfigured || 
                           config.isTdxConfigured
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
            errorMessage = nil
            
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
    
    // MARK: - TDX SSO Authentication
    
    /// Check if TDX SSO login is required
    var requiresTdxSsoLogin: Bool {
        return tdxService.requiresSsoLogin && !tdxSsoAuthenticated
    }
    
    /// Trigger TDX SSO login flow
    func triggerTdxSsoLogin() {
        showTdxSsoLogin = true
    }
    
    /// Handle successful SSO authentication
    func handleTdxSsoSuccess(token: String, expiry: Date, userId: String?, userName: String?) {
        tdxService.setSsoToken(token, expiry: expiry, userId: userId, userName: userName)
        tdxSsoAuthenticated = true
        tdxAuthenticatedUserName = userName
        showTdxSsoLogin = false
        
        // Invalidate tickets cache to reload with new auth
        invalidateTicketsCache()
    }
    
    /// Handle SSO authentication failure or cancellation
    func handleTdxSsoFailure(_ error: String?) {
        showTdxSsoLogin = false
        if let error = error {
            errorMessage = "TDX SSO login failed: \(error)"
        }
    }
    
    /// Sign out of TDX SSO
    func signOutTdxSso() {
        tdxService.clearSsoToken()
        tdxSsoAuthenticated = false
        tdxAuthenticatedUserName = nil
        invalidateTicketsCache()
    }
}
