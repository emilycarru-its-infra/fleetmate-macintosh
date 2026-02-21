import Foundation

// MARK: - Entra Group (Unified)

/// Entra ID group conforming to UnifiedGroup protocol.
public struct EntraUnifiedGroup: UnifiedGroup, Sendable {
    public let id: String
    public let provider: String = "entra"
    public let displayName: String
    public let groupDescription: String?
    public let email: String?
    public let isSecurityGroup: Bool
    public let isMailEnabled: Bool
    public let groupType: String?
    public let memberCount: Int?
    public let externalUrl: String?
    
    /// Original Entra group for full access to all fields.
    public let rawGroup: EntraGroup
    
    public init(from group: EntraGroup) {
        self.id = group.id ?? ""
        self.displayName = group.displayName ?? "Unknown"
        self.groupDescription = group.description
        self.email = group.mail
        self.isSecurityGroup = group.securityEnabled ?? false
        self.isMailEnabled = group.mailEnabled ?? false
        
        // Determine group type
        if let types = group.groupTypes, types.contains("Unified") {
            self.groupType = "Microsoft 365"
        } else if group.securityEnabled == true {
            self.groupType = "Security"
        } else if group.mailEnabled == true {
            self.groupType = "Distribution"
        } else {
            self.groupType = "Other"
        }
        
        self.memberCount = nil // Would need separate API call
        
        if let groupId = group.id {
            self.externalUrl = "https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/\(groupId)"
        } else {
            self.externalUrl = nil
        }
        
        self.rawGroup = group
    }
}

// MARK: - Entra Group Provider

/// Entra ID group provider implementing GroupProvider protocol.
public actor EntraGroupProvider: GroupProvider {
    public typealias GroupType = EntraUnifiedGroup
    
    private let service: GraphService
    private let config: FleetMateConfig
    private var authenticated = false
    
    public nonisolated let providerId: String = "entra"
    public nonisolated let providerName: String = "Entra ID"
    
    public var isEnabled: Bool {
        config.isSystemsGraphConfigured
    }
    
    public init(config: FleetMateConfig) {
        self.config = config
        self.service = GraphService(config: config)
    }
    
    public func authenticate() async throws -> Bool {
        do {
            _ = try await service.searchGroups("test", limit: 1)
            authenticated = true
            return true
        } catch {
            authenticated = false
            throw ProviderError.unauthorized
        }
    }
    
    public func listGroups(filter: GroupFilter?) async throws -> [EntraUnifiedGroup] {
        let query: String
        if let prefix = filter?.namePrefix {
            query = prefix
        } else if let searchText = filter?.searchText {
            query = searchText
        } else {
            query = "" // Will return all groups (up to limit)
        }
        
        let limit = filter?.limit ?? 100
        let groups = try await service.searchGroups(query, limit: limit)
        
        var unified = groups.map { EntraUnifiedGroup(from: $0) }
        
        // Apply additional filters
        if let isSecurityGroup = filter?.isSecurityGroup {
            unified = unified.filter { $0.isSecurityGroup == isSecurityGroup }
        }
        if let isMailEnabled = filter?.isMailEnabled {
            unified = unified.filter { $0.isMailEnabled == isMailEnabled }
        }
        
        return unified
    }
    
    public func getGroup(groupId: String) async throws -> EntraUnifiedGroup? {
        // GraphService would need a getGroup method
        // For now, search and filter
        let groups = try await service.searchGroups(groupId, limit: 10)
        guard let group = groups.first(where: { $0.id == groupId }) else {
            return nil
        }
        return EntraUnifiedGroup(from: group)
    }
    
    public func searchGroups(query: String, limit: Int) async throws -> [EntraUnifiedGroup] {
        let groups = try await service.searchGroups(query, limit: limit)
        return groups.map { EntraUnifiedGroup(from: $0) }
    }
    
    public func getGroupMembers(groupId: String) async throws -> [GroupMember] {
        let devices = try await service.getGroupDeviceMembers(groupId)
        
        return devices.map { device in
            GroupMember(
                id: device.id ?? "",
                displayName: device.displayName,
                type: .device,
                email: nil
            )
        }
    }
}
