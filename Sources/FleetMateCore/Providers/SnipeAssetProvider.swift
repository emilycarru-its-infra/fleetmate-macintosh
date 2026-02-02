import Foundation

// MARK: - Snipe Asset (Unified)

/// Snipe-IT asset conforming to UnifiedAsset protocol.
public struct SnipeUnifiedAsset: UnifiedAsset, Sendable {
    public let id: String
    public let provider: String = "snipe"
    public let assetTag: String?
    public let serial: String?
    public let name: String
    public let model: String?
    public let manufacturer: String?
    public let category: String?
    public let status: String?
    public let assignedTo: String?
    public let location: String?
    public let purchaseDate: Date?
    public let warrantyExpires: Date?
    public let lastCheckIn: Date?
    public let externalUrl: String?
    
    /// Original Snipe asset for full access to all fields.
    public let rawAsset: SnipeAsset
    
    public init(from asset: SnipeAsset, baseUrl: String?) {
        self.id = String(asset.id)
        self.assetTag = asset.assetTag
        self.serial = asset.serial
        self.name = asset.name ?? asset.assetTag ?? "Unknown"
        self.model = asset.model?.name
        self.manufacturer = asset.manufacturer?.name
        self.category = asset.category?.name
        self.status = asset.statusLabel?.name
        self.assignedTo = asset.assignedTo?.name ?? asset.assignedTo?.username
        self.location = asset.location?.name ?? asset.rtdLocation?.name
        self.purchaseDate = Self.parseDate(asset.purchaseDate?.value)
        self.warrantyExpires = nil // Snipe doesn't have a direct warranty field
        self.lastCheckIn = Self.parseDate(asset.lastAuditDate?.value)
        
        if let baseUrl = baseUrl {
            self.externalUrl = "\(baseUrl)/hardware/\(asset.id)"
        } else {
            self.externalUrl = nil
        }
        
        self.rawAsset = asset
    }
    
    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatters: [DateFormatter] = {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd HH:mm:ss"
            
            let dateOnly = DateFormatter()
            dateOnly.dateFormat = "yyyy-MM-dd"
            
            return [iso, dateOnly]
        }()
        
        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        
        return nil
    }
}

// MARK: - Snipe Asset Provider

/// Snipe-IT asset provider implementing AssetProvider protocol.
public actor SnipeAssetProvider: AssetProvider {
    public typealias AssetType = SnipeUnifiedAsset
    
    private let service: SnipeService
    private let config: FleetMateConfig
    private var authenticated = false
    
    public nonisolated let providerId: String = "snipe"
    public nonisolated let providerName: String = "Snipe-IT"
    
    public var isEnabled: Bool {
        config.isSnipeConfigured
    }
    
    public init(config: FleetMateConfig) {
        self.config = config
        self.service = SnipeService(
            baseUrl: config.snipeUrl,
            apiKey: config.snipeApiKey,
            cacheMinutes: config.cacheMinutes
        )
    }
    
    public func authenticate() async throws -> Bool {
        // Snipe uses API token, no explicit auth step needed
        // Verify by checking if we can list assets
        do {
            _ = try await service.getAssets(limit: 1)
            authenticated = true
            return true
        } catch {
            authenticated = false
            throw ProviderError.unauthorized
        }
    }
    
    public func listAssets(filter: AssetFilter?) async throws -> [SnipeUnifiedAsset] {
        let includeArchived = filter?.includeArchived ?? false
        let limit = filter?.limit ?? 500
        
        // Use getAllAssets for full list, or getAssets for limited
        let assets: [SnipeAsset]
        if includeArchived || limit > 500 {
            assets = try await service.getAllAssets(includeArchived: includeArchived)
        } else {
            assets = try await service.getAssets(limit: limit)
        }
        
        var unified = assets.map { SnipeUnifiedAsset(from: $0, baseUrl: config.snipeUrl) }
        
        // Apply client-side filters
        if let category = filter?.category {
            unified = unified.filter { $0.category?.lowercased() == category.lowercased() }
        }
        if let status = filter?.status {
            unified = unified.filter { $0.status?.lowercased() == status.lowercased() }
        }
        if let location = filter?.location {
            unified = unified.filter { $0.location?.lowercased() == location.lowercased() }
        }
        if let assignedTo = filter?.assignedTo {
            unified = unified.filter { $0.assignedTo?.lowercased().contains(assignedTo.lowercased()) ?? false }
        }
        if let searchText = filter?.searchText, !searchText.isEmpty {
            unified = unified.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.serial?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.assetTag?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.assignedTo?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        
        return unified
    }
    
    public func getAsset(assetId: String) async throws -> SnipeUnifiedAsset? {
        guard let id = Int(assetId) else {
            throw ProviderError.invalidRequest("Invalid asset ID: \(assetId)")
        }
        
        guard let asset = try await service.getAsset(id: id) else {
            return nil
        }
        
        return SnipeUnifiedAsset(from: asset, baseUrl: config.snipeUrl)
    }
    
    public func searchAssets(query: String, limit: Int) async throws -> [SnipeUnifiedAsset] {
        let assets = try await service.getAssets(search: query, limit: limit)
        return assets.map { SnipeUnifiedAsset(from: $0, baseUrl: config.snipeUrl) }
    }
    
    public func getAssetBySerial(serialNumber: String) async throws -> SnipeUnifiedAsset? {
        guard let asset = try await service.getAssetBySerial(serialNumber) else {
            return nil
        }
        return SnipeUnifiedAsset(from: asset, baseUrl: config.snipeUrl)
    }
    
    public func getAssetByTag(assetTag: String) async throws -> SnipeUnifiedAsset? {
        guard let asset = try await service.getAssetByTag(assetTag) else {
            return nil
        }
        return SnipeUnifiedAsset(from: asset, baseUrl: config.snipeUrl)
    }
    
    public func listLocations() async throws -> [AssetLocation] {
        let locations = try await service.getLocations()
        return locations.map { location in
            AssetLocation(
                id: String(location.id),
                name: location.name ?? "Unknown",
                address: [location.address, location.city, location.state, location.zip]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
        }
    }
    
    public func listCategories() async throws -> [AssetCategory] {
        let categories = try await service.getCategories()
        return categories.map { category in
            AssetCategory(
                id: String(category.id),
                name: category.name ?? "Unknown",
                type: category.categoryType
            )
        }
    }
    
    public func listStatuses() async throws -> [AssetStatus] {
        let statuses = try await service.getStatusLabels()
        return statuses.map { status in
            let statusType: AssetStatus.StatusType = {
                switch status.statusMeta?.lowercased() {
                case "deployable": return .deployable
                case "deployed": return .deployed
                case "pending": return .pending
                case "undeployable": return .undeployable
                case "archived": return .archived
                default: return .deployable
                }
            }()
            
            return AssetStatus(
                id: String(status.id),
                name: status.name ?? "Unknown",
                type: statusType
            )
        }
    }
}
