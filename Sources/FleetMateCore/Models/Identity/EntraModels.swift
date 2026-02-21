import Foundation

// MARK: - Entra User Models

public struct EntraUser: Codable, Identifiable, Hashable, Sendable {
    public let id: String?
    public let displayName: String?
    public let userPrincipalName: String?
    public let mail: String?
    public let jobTitle: String?
    public let department: String?
    public let officeLocation: String?
    public let mobilePhone: String?
    public let accountEnabled: Bool?
    public var memberOf: [EntraGroup]?

    public var email: String {
        mail ?? userPrincipalName ?? ""
    }
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
