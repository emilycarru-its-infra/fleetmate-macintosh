import Foundation

// MARK: - Unified Asset Protocol

/// Protocol for unified asset representation across providers.
public protocol UnifiedAsset: Identifiable, Sendable {
    /// Unique identifier within the provider.
    var id: String { get }
    
    /// Provider that owns this asset (e.g., "snipe", "servicenow").
    var provider: String { get }
    
    /// Asset tag or inventory number.
    var assetTag: String? { get }
    
    /// Device serial number.
    var serial: String? { get }
    
    /// Asset name/hostname.
    var name: String { get }
    
    /// Model name.
    var model: String? { get }
    
    /// Manufacturer.
    var manufacturer: String? { get }
    
    /// Category (e.g., "Laptop", "Desktop").
    var category: String? { get }
    
    /// Current status (e.g., "Deployed", "Available").
    var status: String? { get }
    
    /// Assigned user (if any).
    var assignedTo: String? { get }
    
    /// Location name.
    var location: String? { get }
    
    /// Purchase date.
    var purchaseDate: Date? { get }
    
    /// Warranty expiration date.
    var warrantyExpires: Date? { get }
    
    /// Last check-in date.
    var lastCheckIn: Date? { get }
    
    /// URL to view in provider's web UI.
    var externalUrl: String? { get }
    
    /// Creates a composite key for cross-provider identification.
    var compositeKey: String { get }
}

extension UnifiedAsset {
    public var compositeKey: String { "\(provider):\(id)" }
}

// MARK: - Unified Managed Device Protocol

/// Protocol for unified managed device representation across MDM providers.
public protocol UnifiedManagedDevice: Identifiable, Sendable {
    /// Unique identifier within the provider.
    var id: String { get }
    
    /// Provider that manages this device (e.g., "intune", "jamf").
    var provider: String { get }
    
    /// Device name/hostname.
    var deviceName: String { get }
    
    /// Device serial number.
    var serialNumber: String? { get }
    
    /// Operating system name.
    var operatingSystem: String? { get }
    
    /// OS version.
    var osVersion: String? { get }
    
    /// Device model.
    var model: String? { get }
    
    /// Device manufacturer.
    var manufacturer: String? { get }
    
    /// Primary user.
    var primaryUser: String? { get }
    
    /// Whether device is compliant with policies.
    var isCompliant: Bool { get }
    
    /// Whether device is managed.
    var isManaged: Bool { get }
    
    /// Last sync/check-in date.
    var lastSyncDateTime: Date? { get }
    
    /// Enrollment date.
    var enrolledDateTime: Date? { get }
    
    /// Management agent version.
    var managementAgentVersion: String? { get }
    
    /// URL to view in provider's web UI.
    var externalUrl: String? { get }
    
    /// Creates a composite key for cross-provider identification.
    var compositeKey: String { get }
}

extension UnifiedManagedDevice {
    public var compositeKey: String { "\(provider):\(id)" }
}

// MARK: - Unified Ticket Protocol

/// Protocol for unified ticket representation across ticketing providers.
public protocol UnifiedTicket: Identifiable, Sendable {
    /// Unique identifier within the provider.
    var id: String { get }
    
    /// Provider that owns this ticket (e.g., "tdx", "servicenow").
    var provider: String { get }
    
    /// Ticket number/reference.
    var ticketNumber: String { get }
    
    /// Ticket title/subject.
    var title: String { get }
    
    /// Ticket description/body.
    var description: String? { get }
    
    /// Current status.
    var status: String? { get }
    
    /// Priority level.
    var priority: String? { get }
    
    /// Ticket type/category.
    var type: String? { get }
    
    /// Requester name.
    var requestor: String? { get }
    
    /// Assigned technician/agent.
    var assignedTo: String? { get }
    
    /// Responsible group/team.
    var responsibleGroup: String? { get }
    
    /// Created date.
    var createdDate: Date? { get }
    
    /// Last modified date.
    var modifiedDate: Date? { get }
    
    /// Due date.
    var dueDate: Date? { get }
    
    /// Closed date.
    var closedDate: Date? { get }
    
    /// URL to view in provider's web UI.
    var externalUrl: String? { get }
    
    /// Creates a composite key for cross-provider identification.
    var compositeKey: String { get }
}

extension UnifiedTicket {
    public var compositeKey: String { "\(provider):\(id)" }
}

// MARK: - Unified User Protocol

/// Protocol for unified user representation across directory providers.
public protocol UnifiedUser: Identifiable, Sendable {
    /// Unique identifier within the provider.
    var id: String { get }
    
    /// Provider that owns this user (e.g., "entra", "snipe", "okta").
    var provider: String { get }
    
    /// Display name.
    var displayName: String { get }
    
    /// Email address.
    var email: String? { get }
    
    /// Username/login.
    var username: String? { get }
    
    /// First name.
    var firstName: String? { get }
    
    /// Last name.
    var lastName: String? { get }
    
    /// Job title.
    var jobTitle: String? { get }
    
    /// Department.
    var department: String? { get }
    
    /// Manager.
    var manager: String? { get }
    
    /// Phone number.
    var phone: String? { get }
    
    /// Location/office.
    var location: String? { get }
    
    /// Whether the account is active/enabled.
    var isActive: Bool { get }
    
    /// URL to view in provider's web UI.
    var externalUrl: String? { get }
    
    /// Creates a composite key for cross-provider identification.
    var compositeKey: String { get }
}

extension UnifiedUser {
    public var compositeKey: String { "\(provider):\(id)" }
}

// MARK: - Unified Group Protocol

/// Protocol for unified group representation across directory providers.
public protocol UnifiedGroup: Identifiable, Sendable {
    /// Unique identifier within the provider.
    var id: String { get }
    
    /// Provider that owns this group (e.g., "entra", "okta").
    var provider: String { get }
    
    /// Group display name.
    var displayName: String { get }
    
    /// Group description.
    var groupDescription: String? { get }
    
    /// Group email (if mail-enabled).
    var email: String? { get }
    
    /// Whether this is a security group.
    var isSecurityGroup: Bool { get }
    
    /// Whether this is a mail-enabled group.
    var isMailEnabled: Bool { get }
    
    /// Group type (security, M365, distribution, etc.).
    var groupType: String? { get }
    
    /// Member count (if known).
    var memberCount: Int? { get }
    
    /// URL to view in provider's web UI.
    var externalUrl: String? { get }
    
    /// Creates a composite key for cross-provider identification.
    var compositeKey: String { get }
}

extension UnifiedGroup {
    public var compositeKey: String { "\(provider):\(id)" }
}

// MARK: - Group Member

/// Represents a member of a group.
public struct GroupMember: Identifiable, Codable, Sendable {
    public let id: String
    public let displayName: String?
    public let type: MemberType
    public let email: String?
    
    public enum MemberType: String, Codable, Sendable {
        case user
        case device
        case group
        case servicePrincipal
        case unknown
    }
    
    public init(id: String, displayName: String?, type: MemberType, email: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.email = email
    }
}

// MARK: - Filter Types

/// Filter criteria for listing assets.
public struct AssetFilter: Sendable {
    public var category: String?
    public var status: String?
    public var location: String?
    public var assignedTo: String?
    public var searchText: String?
    public var limit: Int?
    public var includeArchived: Bool
    
    public init(
        category: String? = nil,
        status: String? = nil,
        location: String? = nil,
        assignedTo: String? = nil,
        searchText: String? = nil,
        limit: Int? = nil,
        includeArchived: Bool = false
    ) {
        self.category = category
        self.status = status
        self.location = location
        self.assignedTo = assignedTo
        self.searchText = searchText
        self.limit = limit
        self.includeArchived = includeArchived
    }
}

/// Filter criteria for listing managed devices.
public struct ManagedDeviceFilter: Sendable {
    public var operatingSystem: String?
    public var complianceState: String?
    public var isManaged: Bool?
    public var primaryUser: String?
    public var searchText: String?
    public var limit: Int?
    
    public init(
        operatingSystem: String? = nil,
        complianceState: String? = nil,
        isManaged: Bool? = nil,
        primaryUser: String? = nil,
        searchText: String? = nil,
        limit: Int? = nil
    ) {
        self.operatingSystem = operatingSystem
        self.complianceState = complianceState
        self.isManaged = isManaged
        self.primaryUser = primaryUser
        self.searchText = searchText
        self.limit = limit
    }
}

/// Filter criteria for listing tickets.
public struct TicketFilter: Sendable {
    public var status: String?
    public var priority: String?
    public var type: String?
    public var assignedTo: String?
    public var responsibleGroupId: Int?
    public var requestor: String?
    public var searchText: String?
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var limit: Int?
    public var includeClosed: Bool
    
    public init(
        status: String? = nil,
        priority: String? = nil,
        type: String? = nil,
        assignedTo: String? = nil,
        responsibleGroupId: Int? = nil,
        requestor: String? = nil,
        searchText: String? = nil,
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        limit: Int? = nil,
        includeClosed: Bool = false
    ) {
        self.status = status
        self.priority = priority
        self.type = type
        self.assignedTo = assignedTo
        self.responsibleGroupId = responsibleGroupId
        self.requestor = requestor
        self.searchText = searchText
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.limit = limit
        self.includeClosed = includeClosed
    }
}

/// Filter criteria for listing users.
public struct UserFilter: Sendable {
    public var department: String?
    public var location: String?
    public var manager: String?
    public var isActive: Bool?
    public var searchText: String?
    public var limit: Int?
    
    public init(
        department: String? = nil,
        location: String? = nil,
        manager: String? = nil,
        isActive: Bool? = nil,
        searchText: String? = nil,
        limit: Int? = nil
    ) {
        self.department = department
        self.location = location
        self.manager = manager
        self.isActive = isActive
        self.searchText = searchText
        self.limit = limit
    }
}

/// Filter criteria for listing groups.
public struct GroupFilter: Sendable {
    public var namePrefix: String?
    public var isSecurityGroup: Bool?
    public var isMailEnabled: Bool?
    public var searchText: String?
    public var limit: Int?
    
    public init(
        namePrefix: String? = nil,
        isSecurityGroup: Bool? = nil,
        isMailEnabled: Bool? = nil,
        searchText: String? = nil,
        limit: Int? = nil
    ) {
        self.namePrefix = namePrefix
        self.isSecurityGroup = isSecurityGroup
        self.isMailEnabled = isMailEnabled
        self.searchText = searchText
        self.limit = limit
    }
}

// MARK: - Supporting Types

/// Represents an asset location.
public struct AssetLocation: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let address: String?
    
    public init(id: String, name: String, address: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
    }
}

/// Represents an asset category.
public struct AssetCategory: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let type: String?
    
    public init(id: String, name: String, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// Represents an asset status.
public struct AssetStatus: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let type: StatusType
    
    public enum StatusType: String, Codable, Sendable {
        case deployable
        case deployed
        case pending
        case undeployable
        case archived
    }
    
    public init(id: String, name: String, type: StatusType) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// Represents compliance status for a managed device.
public struct ComplianceStatus: Codable, Sendable {
    public let isCompliant: Bool
    public let state: String
    public let details: [ComplianceDetail]
    
    public struct ComplianceDetail: Codable, Sendable {
        public let settingName: String
        public let state: String
        public let errorCode: Int?
        public let errorDescription: String?
    }
    
    public init(isCompliant: Bool, state: String, details: [ComplianceDetail] = []) {
        self.isCompliant = isCompliant
        self.state = state
        self.details = details
    }
}

/// Represents a device profile/configuration policy.
public struct DeviceProfile: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let platform: String?
    
    public init(id: String, name: String, description: String? = nil, platform: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.platform = platform
    }
}

/// Represents a ticket status.
public struct TicketStatus: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let isClosed: Bool
    
    public init(id: String, name: String, isDefault: Bool = false, isClosed: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.isClosed = isClosed
    }
}

/// Represents a ticket category/type.
public struct TicketCategory: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    
    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

// MARK: - Request Types

/// Unified request to create a new ticket (provider-agnostic).
public struct UnifiedCreateTicketRequest: Codable, Sendable {
    public var title: String
    public var description: String?
    public var type: String?
    public var priority: String?
    public var requestor: String?
    public var assignedTo: String?
    public var responsibleGroupId: Int?
    
    public init(
        title: String,
        description: String? = nil,
        type: String? = nil,
        priority: String? = nil,
        requestor: String? = nil,
        assignedTo: String? = nil,
        responsibleGroupId: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.type = type
        self.priority = priority
        self.requestor = requestor
        self.assignedTo = assignedTo
        self.responsibleGroupId = responsibleGroupId
    }
}

/// Unified request to update an existing ticket (provider-agnostic).
public struct UnifiedUpdateTicketRequest: Codable, Sendable {
    public var title: String?
    public var status: String?
    public var priority: String?
    public var assignedTo: String?
    public var responsibleGroupId: Int?
    
    public init(
        title: String? = nil,
        status: String? = nil,
        priority: String? = nil,
        assignedTo: String? = nil,
        responsibleGroupId: Int? = nil
    ) {
        self.title = title
        self.status = status
        self.priority = priority
        self.assignedTo = assignedTo
        self.responsibleGroupId = responsibleGroupId
    }
}
