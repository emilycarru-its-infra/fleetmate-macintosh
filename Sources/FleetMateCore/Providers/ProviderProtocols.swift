import Foundation

// MARK: - Provider Configuration Protocol

/// Configuration for a provider instance.
public protocol ProviderConfiguration: Sendable {
    /// Whether this provider is enabled.
    var enabled: Bool { get }
}

// MARK: - Base Provider Protocol

/// Base protocol for all FleetMate providers.
/// Implements Actor isolation for thread safety.
public protocol FleetMateProvider: Actor {
    /// Unique identifier for this provider (e.g., "snipe", "intune", "tdx").
    var providerId: String { get }
    
    /// Human-readable provider name for display.
    var providerName: String { get }
    
    /// Whether the provider is currently configured and enabled.
    var isEnabled: Bool { get }
    
    /// Authenticates with the provider. Call before other operations.
    /// - Returns: True if authenticated successfully.
    func authenticate() async throws -> Bool
}

// MARK: - Provider Error

/// Errors that can occur during provider operations.
public enum ProviderError: Error, LocalizedError {
    case notAuthenticated
    case notConfigured
    case itemNotFound(String)
    case apiError(String)
    case networkError(Error)
    case parseError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized
    case forbidden
    case invalidRequest(String)
    
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with the provider"
        case .notConfigured:
            return "Provider is not configured"
        case .itemNotFound(let id):
            return "Item not found: \(id)"
        case .apiError(let message):
            return "API error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited"
        case .unauthorized:
            return "Unauthorized - check credentials"
        case .forbidden:
            return "Forbidden - insufficient permissions"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        }
    }
}

// MARK: - Asset Provider Protocol

/// Protocol for asset/inventory providers (Snipe-IT, ServiceNow, etc.).
/// Manages hardware assets, software licenses, and consumables.
public protocol AssetProvider: FleetMateProvider {
    /// Unified asset type for this provider.
    associatedtype AssetType: UnifiedAsset
    
    /// Lists all assets matching the optional filter.
    /// - Parameter filter: Optional filter criteria.
    /// - Returns: List of assets.
    func listAssets(filter: AssetFilter?) async throws -> [AssetType]
    
    /// Gets a single asset by ID.
    /// - Parameter assetId: Provider-specific asset ID.
    /// - Returns: The asset, or nil if not found.
    func getAsset(assetId: String) async throws -> AssetType?
    
    /// Searches assets by query string.
    /// - Parameters:
    ///   - query: Search query.
    ///   - limit: Maximum results.
    /// - Returns: Matching assets.
    func searchAssets(query: String, limit: Int) async throws -> [AssetType]
    
    /// Gets asset by serial number.
    /// - Parameter serialNumber: Device serial number.
    /// - Returns: The asset, or nil if not found.
    func getAssetBySerial(serialNumber: String) async throws -> AssetType?
    
    /// Gets asset by asset tag.
    /// - Parameter assetTag: Asset tag identifier.
    /// - Returns: The asset, or nil if not found.
    func getAssetByTag(assetTag: String) async throws -> AssetType?
    
    /// Lists available locations.
    func listLocations() async throws -> [AssetLocation]
    
    /// Lists available categories.
    func listCategories() async throws -> [AssetCategory]
    
    /// Lists available status labels.
    func listStatuses() async throws -> [AssetStatus]
}

// MARK: - Management Provider Protocol

/// Protocol for device management providers (Intune, Jamf, SimpleMDM, etc.).
/// Manages device compliance, policies, and deployments.
public protocol ManagementProvider: FleetMateProvider {
    /// Unified managed device type for this provider.
    associatedtype DeviceType: UnifiedManagedDevice
    
    /// Lists all managed devices matching the optional filter.
    /// - Parameter filter: Optional filter criteria.
    /// - Returns: List of managed devices.
    func listDevices(filter: ManagedDeviceFilter?) async throws -> [DeviceType]
    
    /// Gets a single device by ID.
    /// - Parameter deviceId: Provider-specific device ID.
    /// - Returns: The device, or nil if not found.
    func getDevice(deviceId: String) async throws -> DeviceType?
    
    /// Gets device by serial number.
    /// - Parameter serialNumber: Device serial number.
    /// - Returns: The device, or nil if not found.
    func getDeviceBySerial(serialNumber: String) async throws -> DeviceType?
    
    /// Syncs a device (triggers check-in).
    /// - Parameter deviceId: Provider-specific device ID.
    func syncDevice(deviceId: String) async throws
    
    /// Wipes a device.
    /// - Parameter deviceId: Provider-specific device ID.
    func wipeDevice(deviceId: String) async throws
    
    /// Gets compliance status for a device.
    /// - Parameter deviceId: Provider-specific device ID.
    /// - Returns: Compliance status.
    func getComplianceStatus(deviceId: String) async throws -> ComplianceStatus
    
    /// Lists available device groups/profiles.
    func listProfiles() async throws -> [DeviceProfile]
}

// MARK: - Ticket Provider Protocol

/// Protocol for ticketing/service desk providers (TDX, ServiceNow, Zendesk, etc.).
/// Manages tickets, incidents, and service requests.
public protocol TicketProvider: FleetMateProvider {
    /// Unified ticket type for this provider.
    associatedtype TicketType: UnifiedTicket
    
    /// Lists tickets matching the optional filter.
    /// - Parameter filter: Optional filter criteria.
    /// - Returns: List of tickets.
    func listTickets(filter: TicketFilter?) async throws -> [TicketType]
    
    /// Gets a single ticket by ID.
    /// - Parameter ticketId: Provider-specific ticket ID.
    /// - Returns: The ticket, or nil if not found.
    func getTicket(ticketId: String) async throws -> TicketType?
    
    /// Searches tickets by query string.
    /// - Parameters:
    ///   - query: Search query.
    ///   - limit: Maximum results.
    /// - Returns: Matching tickets.
    func searchTickets(query: String, limit: Int) async throws -> [TicketType]
    
    /// Creates a new ticket.
    /// - Parameter request: Ticket creation request.
    /// - Returns: The created ticket.
    func createTicket(request: UnifiedCreateTicketRequest) async throws -> TicketType
    
    /// Updates an existing ticket.
    /// - Parameters:
    ///   - ticketId: Provider-specific ticket ID.
    ///   - request: Update request.
    /// - Returns: The updated ticket.
    func updateTicket(ticketId: String, request: UnifiedUpdateTicketRequest) async throws -> TicketType
    
    /// Adds a comment to a ticket.
    /// - Parameters:
    ///   - ticketId: Provider-specific ticket ID.
    ///   - comment: Comment text.
    ///   - isPrivate: Whether the comment is internal only.
    func addComment(ticketId: String, comment: String, isPrivate: Bool) async throws
    
    /// Lists available ticket statuses.
    func listStatuses() async throws -> [TicketStatus]
    
    /// Lists available ticket categories/types.
    func listCategories() async throws -> [TicketCategory]
}

// MARK: - User Provider Protocol

/// Protocol for user directory providers (Entra ID, Okta, etc.).
/// Manages user identities and group memberships.
public protocol UserProvider: FleetMateProvider {
    /// Unified user type for this provider.
    associatedtype UserType: UnifiedUser
    
    /// Lists users matching the optional filter.
    /// - Parameter filter: Optional filter criteria.
    /// - Returns: List of users.
    func listUsers(filter: UserFilter?) async throws -> [UserType]
    
    /// Gets a single user by ID.
    /// - Parameter userId: Provider-specific user ID.
    /// - Returns: The user, or nil if not found.
    func getUser(userId: String) async throws -> UserType?
    
    /// Searches users by query string.
    /// - Parameters:
    ///   - query: Search query (name, email, etc.).
    ///   - limit: Maximum results.
    /// - Returns: Matching users.
    func searchUsers(query: String, limit: Int) async throws -> [UserType]
    
    /// Gets user by email.
    /// - Parameter email: User email address.
    /// - Returns: The user, or nil if not found.
    func getUserByEmail(email: String) async throws -> UserType?
}

// MARK: - Group Provider Protocol

/// Protocol for group/directory providers (Entra ID, Okta, etc.).
/// Manages security groups and memberships.
public protocol GroupProvider: FleetMateProvider {
    /// Unified group type for this provider.
    associatedtype GroupType: UnifiedGroup
    
    /// Lists groups matching the optional filter.
    /// - Parameter filter: Optional filter criteria.
    /// - Returns: List of groups.
    func listGroups(filter: GroupFilter?) async throws -> [GroupType]
    
    /// Gets a single group by ID.
    /// - Parameter groupId: Provider-specific group ID.
    /// - Returns: The group, or nil if not found.
    func getGroup(groupId: String) async throws -> GroupType?
    
    /// Searches groups by name.
    /// - Parameters:
    ///   - query: Search query (group name).
    ///   - limit: Maximum results.
    /// - Returns: Matching groups.
    func searchGroups(query: String, limit: Int) async throws -> [GroupType]
    
    /// Gets members of a group.
    /// - Parameter groupId: Provider-specific group ID.
    /// - Returns: List of member identifiers.
    func getGroupMembers(groupId: String) async throws -> [GroupMember]
}
