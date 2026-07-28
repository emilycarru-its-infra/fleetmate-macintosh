import Foundation

// MARK: - Entra User Models

public struct EntraUser: Codable, Identifiable, Hashable, Sendable {
    public let id: String?
    // Identity
    public let displayName: String?
    public let givenName: String?
    public let surname: String?
    public let userPrincipalName: String?
    public let userType: String?
    public let accountEnabled: Bool?
    public let createdDateTime: String?
    public let lastPasswordChangeDateTime: String?
    public let passwordPolicies: String?
    // Job information
    public let jobTitle: String?
    public let companyName: String?
    public let department: String?
    public let employeeId: String?
    public let employeeType: String?
    public let officeLocation: String?
    // Contact information
    public let mail: String?
    public let otherMails: [String]?
    public let mobilePhone: String?
    public let businessPhones: [String]?
    public let streetAddress: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let country: String?
    public let proxyAddresses: [String]?
    // Settings
    public let usageLocation: String?
    public let preferredLanguage: String?
    // On-premises
    public let onPremisesSyncEnabled: Bool?
    public let onPremisesLastSyncDateTime: String?
    public let onPremisesDistinguishedName: String?
    public let onPremisesSamAccountName: String?
    public let onPremisesSecurityIdentifier: String?
    public let onPremisesImmutableId: String?
    public let onPremisesUserPrincipalName: String?
    public let onPremisesDomainName: String?
    // Augmented after fetch (navigation properties / related objects)
    public var memberOf: [EntraGroup]?
    public var manager: EntraUserRef?
    public var devices: [EntraDevice]?

    public var email: String {
        mail ?? userPrincipalName ?? ""
    }
}

/// Lightweight reference to another user (e.g. a manager), fetched with a
/// minimal projection so it doesn't recurse the full user object.
public struct EntraUserRef: Codable, Identifiable, Hashable, Sendable {
    public let id: String?
    public let displayName: String?
    public let userPrincipalName: String?
    public let jobTitle: String?
}

extension EntraUser {
    /// The explicit $select fields required to populate the full inspector —
    /// Graph returns almost none of these by default.
    public static let inspectorSelect = [
        "id", "displayName", "givenName", "surname", "userPrincipalName", "userType",
        "accountEnabled", "createdDateTime", "lastPasswordChangeDateTime", "passwordPolicies",
        "jobTitle", "companyName", "department", "employeeId", "employeeType", "officeLocation",
        "mail", "otherMails", "mobilePhone", "businessPhones", "streetAddress", "city", "state",
        "postalCode", "country", "proxyAddresses", "usageLocation", "preferredLanguage",
        "onPremisesSyncEnabled", "onPremisesLastSyncDateTime", "onPremisesDistinguishedName",
        "onPremisesSamAccountName", "onPremisesSecurityIdentifier", "onPremisesImmutableId",
        "onPremisesUserPrincipalName", "onPremisesDomainName",
    ].joined(separator: ",")

    /// The lean projection for search-result rows (enough for the row + the
    /// correct enabled/disabled state).
    public static let rowSelect = [
        "id", "displayName", "givenName", "surname", "userPrincipalName",
        "mail", "jobTitle", "department", "accountEnabled",
    ].joined(separator: ",")
}

public struct EntraUserListResponse: Codable {
    public let value: [EntraUser]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Entra Group Models

public struct EntraGroup: Codable, Identifiable, Hashable, Sendable {
    public let id: String?
    public let displayName: String?
    public let description: String?
    public let mail: String?
    public let mailEnabled: Bool?
    public let securityEnabled: Bool?
    public let groupTypes: [String]?
}

public struct EntraGroupListResponse: Codable {
    public let value: [EntraGroup]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Membership Check Models

public struct DirectoryObject: Codable, Sendable {
    public let id: String?
    public let displayName: String?
    public let description: String?
    public let odataType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case description
        case odataType = "@odata.type"
    }

    public var isGroup: Bool {
        odataType?.contains("group") == true
    }
}

public struct UserMemberOfResponse: Codable {
    public let value: [DirectoryObject]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct GroupMembersResponse: Codable {
    public let value: [EntraUser]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

/// Response for group members as DirectoryObjects (supports both users and devices)
public struct GroupMembersDirectoryResponse: Codable {
    public let value: [DirectoryObject]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

/// Entra ID device (Azure AD joined or registered device)
public struct EntraDevice: Codable, Identifiable, Hashable, Sendable {
    public let id: String?
    public let displayName: String?
    public let deviceId: String?
    public let operatingSystem: String?
    public let operatingSystemVersion: String?
    public let isCompliant: Bool?
    public let isManaged: Bool?
    public let trustType: String?
    public let approximateLastSignInDateTime: String?
}

public struct EntraDeviceListResponse: Codable {
    public let value: [EntraDevice]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct CheckMemberGroupsResponse: Codable {
    public let value: [String]
}
