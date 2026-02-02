import Foundation
import os.log

// MARK: - Type Erased Provider Wrappers

/// Type-erased wrapper for AssetProvider to allow storage in collections.
public struct AnyAssetProvider: Sendable {
    private let _providerId: @Sendable () async -> String
    private let _providerName: @Sendable () async -> String
    private let _isEnabled: @Sendable () async -> Bool
    private let _authenticate: @Sendable () async throws -> Bool
    private let _listAssets: @Sendable (AssetFilter?) async throws -> [any UnifiedAsset]
    private let _getAsset: @Sendable (String) async throws -> (any UnifiedAsset)?
    private let _searchAssets: @Sendable (String, Int) async throws -> [any UnifiedAsset]
    private let _getAssetBySerial: @Sendable (String) async throws -> (any UnifiedAsset)?
    private let _getAssetByTag: @Sendable (String) async throws -> (any UnifiedAsset)?
    
    public init<P: AssetProvider>(_ provider: P) {
        _providerId = { await provider.providerId }
        _providerName = { await provider.providerName }
        _isEnabled = { await provider.isEnabled }
        _authenticate = { try await provider.authenticate() }
        _listAssets = { filter in try await provider.listAssets(filter: filter) }
        _getAsset = { id in try await provider.getAsset(assetId: id) }
        _searchAssets = { query, limit in try await provider.searchAssets(query: query, limit: limit) }
        _getAssetBySerial = { serial in try await provider.getAssetBySerial(serialNumber: serial) }
        _getAssetByTag = { tag in try await provider.getAssetByTag(assetTag: tag) }
    }
    
    public var providerId: String {
        get async { await _providerId() }
    }
    
    public var providerName: String {
        get async { await _providerName() }
    }
    
    public var isEnabled: Bool {
        get async { await _isEnabled() }
    }
    
    public func authenticate() async throws -> Bool {
        try await _authenticate()
    }
    
    public func listAssets(filter: AssetFilter?) async throws -> [any UnifiedAsset] {
        try await _listAssets(filter)
    }
    
    public func getAsset(assetId: String) async throws -> (any UnifiedAsset)? {
        try await _getAsset(assetId)
    }
    
    public func searchAssets(query: String, limit: Int) async throws -> [any UnifiedAsset] {
        try await _searchAssets(query, limit)
    }
    
    public func getAssetBySerial(serialNumber: String) async throws -> (any UnifiedAsset)? {
        try await _getAssetBySerial(serialNumber)
    }
    
    public func getAssetByTag(assetTag: String) async throws -> (any UnifiedAsset)? {
        try await _getAssetByTag(assetTag)
    }
}

/// Type-erased wrapper for TicketProvider.
public struct AnyTicketProvider: Sendable {
    private let _providerId: @Sendable () async -> String
    private let _providerName: @Sendable () async -> String
    private let _isEnabled: @Sendable () async -> Bool
    private let _authenticate: @Sendable () async throws -> Bool
    private let _listTickets: @Sendable (TicketFilter?) async throws -> [any UnifiedTicket]
    private let _getTicket: @Sendable (String) async throws -> (any UnifiedTicket)?
    private let _searchTickets: @Sendable (String, Int) async throws -> [any UnifiedTicket]
    
    public init<P: TicketProvider>(_ provider: P) {
        _providerId = { await provider.providerId }
        _providerName = { await provider.providerName }
        _isEnabled = { await provider.isEnabled }
        _authenticate = { try await provider.authenticate() }
        _listTickets = { filter in try await provider.listTickets(filter: filter) }
        _getTicket = { id in try await provider.getTicket(ticketId: id) }
        _searchTickets = { query, limit in try await provider.searchTickets(query: query, limit: limit) }
    }
    
    public var providerId: String {
        get async { await _providerId() }
    }
    
    public var providerName: String {
        get async { await _providerName() }
    }
    
    public var isEnabled: Bool {
        get async { await _isEnabled() }
    }
    
    public func authenticate() async throws -> Bool {
        try await _authenticate()
    }
    
    public func listTickets(filter: TicketFilter?) async throws -> [any UnifiedTicket] {
        try await _listTickets(filter)
    }
    
    public func getTicket(ticketId: String) async throws -> (any UnifiedTicket)? {
        try await _getTicket(ticketId)
    }
    
    public func searchTickets(query: String, limit: Int) async throws -> [any UnifiedTicket] {
        try await _searchTickets(query, limit)
    }
}

/// Type-erased wrapper for ManagementProvider.
public struct AnyManagementProvider: Sendable {
    private let _providerId: @Sendable () async -> String
    private let _providerName: @Sendable () async -> String
    private let _isEnabled: @Sendable () async -> Bool
    private let _authenticate: @Sendable () async throws -> Bool
    private let _listDevices: @Sendable (ManagedDeviceFilter?) async throws -> [any UnifiedManagedDevice]
    private let _getDevice: @Sendable (String) async throws -> (any UnifiedManagedDevice)?
    private let _getDeviceBySerial: @Sendable (String) async throws -> (any UnifiedManagedDevice)?
    private let _syncDevice: @Sendable (String) async throws -> Void
    
    public init<P: ManagementProvider>(_ provider: P) {
        _providerId = { await provider.providerId }
        _providerName = { await provider.providerName }
        _isEnabled = { await provider.isEnabled }
        _authenticate = { try await provider.authenticate() }
        _listDevices = { filter in try await provider.listDevices(filter: filter) }
        _getDevice = { id in try await provider.getDevice(deviceId: id) }
        _getDeviceBySerial = { serial in try await provider.getDeviceBySerial(serialNumber: serial) }
        _syncDevice = { id in try await provider.syncDevice(deviceId: id) }
    }
    
    public var providerId: String {
        get async { await _providerId() }
    }
    
    public var providerName: String {
        get async { await _providerName() }
    }
    
    public var isEnabled: Bool {
        get async { await _isEnabled() }
    }
    
    public func authenticate() async throws -> Bool {
        try await _authenticate()
    }
    
    public func listDevices(filter: ManagedDeviceFilter?) async throws -> [any UnifiedManagedDevice] {
        try await _listDevices(filter)
    }
    
    public func getDevice(deviceId: String) async throws -> (any UnifiedManagedDevice)? {
        try await _getDevice(deviceId)
    }
    
    public func getDeviceBySerial(serialNumber: String) async throws -> (any UnifiedManagedDevice)? {
        try await _getDeviceBySerial(serialNumber)
    }
    
    public func syncDevice(deviceId: String) async throws {
        try await _syncDevice(deviceId)
    }
}

// MARK: - Provider Registries

/// Registry for asset providers.
public actor AssetProviderRegistry {
    private var providers: [String: AnyAssetProvider] = [:]
    private let logger = Logger(subsystem: "com.fleetmate", category: "AssetProviderRegistry")
    
    public init() {}
    
    public func registerProvider<P: AssetProvider>(_ provider: P) async {
        let wrapped = AnyAssetProvider(provider)
        let providerId = await wrapped.providerId
        providers[providerId] = wrapped
        logger.debug("Registered asset provider: \(providerId)")
    }
    
    public var allProviders: [AnyAssetProvider] {
        Array(providers.values)
    }
    
    public var enabledProviders: [AnyAssetProvider] {
        get async {
            var enabled: [AnyAssetProvider] = []
            for provider in providers.values {
                if await provider.isEnabled {
                    enabled.append(provider)
                }
            }
            return enabled
        }
    }
    
    public func getProvider(_ providerId: String) -> AnyAssetProvider? {
        providers[providerId]
    }
    
    /// Lists assets from all enabled providers.
    public func listAllAssets(filter: AssetFilter? = nil) async -> [any UnifiedAsset] {
        var allAssets: [any UnifiedAsset] = []
        
        for provider in await enabledProviders {
            do {
                let assets = try await provider.listAssets(filter: filter)
                allAssets.append(contentsOf: assets)
            } catch {
                let providerId = await provider.providerId
                logger.error("Failed to list assets from \(providerId): \(error.localizedDescription)")
            }
        }
        
        return allAssets
    }
    
    /// Searches across all enabled providers.
    public func searchAllAssets(query: String, limit: Int = 50) async -> [any UnifiedAsset] {
        var allAssets: [any UnifiedAsset] = []
        
        for provider in await enabledProviders {
            do {
                let assets = try await provider.searchAssets(query: query, limit: limit)
                allAssets.append(contentsOf: assets)
            } catch {
                let providerId = await provider.providerId
                logger.error("Failed to search assets in \(providerId): \(error.localizedDescription)")
            }
        }
        
        return allAssets
    }
}

/// Registry for ticket providers.
public actor TicketProviderRegistry {
    private var providers: [String: AnyTicketProvider] = [:]
    private let logger = Logger(subsystem: "com.fleetmate", category: "TicketProviderRegistry")
    
    public init() {}
    
    public func registerProvider<P: TicketProvider>(_ provider: P) async {
        let wrapped = AnyTicketProvider(provider)
        let providerId = await wrapped.providerId
        providers[providerId] = wrapped
        logger.debug("Registered ticket provider: \(providerId)")
    }
    
    public var allProviders: [AnyTicketProvider] {
        Array(providers.values)
    }
    
    public var enabledProviders: [AnyTicketProvider] {
        get async {
            var enabled: [AnyTicketProvider] = []
            for provider in providers.values {
                if await provider.isEnabled {
                    enabled.append(provider)
                }
            }
            return enabled
        }
    }
    
    public func getProvider(_ providerId: String) -> AnyTicketProvider? {
        providers[providerId]
    }
    
    /// Lists tickets from all enabled providers.
    public func listAllTickets(filter: TicketFilter? = nil) async -> [any UnifiedTicket] {
        var allTickets: [any UnifiedTicket] = []
        
        for provider in await enabledProviders {
            do {
                let tickets = try await provider.listTickets(filter: filter)
                allTickets.append(contentsOf: tickets)
            } catch {
                let providerId = await provider.providerId
                logger.error("Failed to list tickets from \(providerId): \(error.localizedDescription)")
            }
        }
        
        return allTickets
    }
}

/// Registry for management providers.
public actor ManagementProviderRegistry {
    private var providers: [String: AnyManagementProvider] = [:]
    private let logger = Logger(subsystem: "com.fleetmate", category: "ManagementProviderRegistry")
    
    public init() {}
    
    public func registerProvider<P: ManagementProvider>(_ provider: P) async {
        let wrapped = AnyManagementProvider(provider)
        let providerId = await wrapped.providerId
        providers[providerId] = wrapped
        logger.debug("Registered management provider: \(providerId)")
    }
    
    public var allProviders: [AnyManagementProvider] {
        Array(providers.values)
    }
    
    public var enabledProviders: [AnyManagementProvider] {
        get async {
            var enabled: [AnyManagementProvider] = []
            for provider in providers.values {
                if await provider.isEnabled {
                    enabled.append(provider)
                }
            }
            return enabled
        }
    }
    
    public func getProvider(_ providerId: String) -> AnyManagementProvider? {
        providers[providerId]
    }
    
    /// Lists devices from all enabled providers.
    public func listAllDevices(filter: ManagedDeviceFilter? = nil) async -> [any UnifiedManagedDevice] {
        var allDevices: [any UnifiedManagedDevice] = []
        
        for provider in await enabledProviders {
            do {
                let devices = try await provider.listDevices(filter: filter)
                allDevices.append(contentsOf: devices)
            } catch {
                let providerId = await provider.providerId
                logger.error("Failed to list devices from \(providerId): \(error.localizedDescription)")
            }
        }
        
        return allDevices
    }
}
