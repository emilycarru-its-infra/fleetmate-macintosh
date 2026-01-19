import Foundation

// MARK: - Intune Device Models

public struct IntuneDevice: Codable, Identifiable {
    private let _id: String?
    public let deviceName: String?
    public let serialNumber: String?
    public let operatingSystem: String?
    public let osVersion: String?
    public let complianceState: String?
    public let managementState: String?
    public let enrolledDateTime: String?
    public let lastSyncDateTime: String?
    public let userPrincipalName: String?
    public let userDisplayName: String?
    public let model: String?
    public let manufacturer: String?
    public let deviceEnrollmentType: String?
    public let managedDeviceOwnerType: String?
    public let azureADDeviceId: String?
    public let totalStorageSpaceInBytes: Int64?
    public let freeStorageSpaceInBytes: Int64?
    
    public var id: String { _id ?? serialNumber ?? UUID().uuidString }
    
    private enum CodingKeys: String, CodingKey {
        case _id = "id"
        case deviceName, serialNumber, operatingSystem, osVersion
        case complianceState, managementState, enrolledDateTime, lastSyncDateTime
        case userPrincipalName, userDisplayName, model, manufacturer
        case deviceEnrollmentType, managedDeviceOwnerType, azureADDeviceId
        case totalStorageSpaceInBytes, freeStorageSpaceInBytes
    }
}

public struct IntuneDeviceListResponse: Codable {
    public let value: [IntuneDevice]
    public let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct DeviceCompliancePolicyState: Codable {
    public let id: String?
    public let displayName: String?
    public let state: String?
    public let platformType: String?
    public let version: Int?
}

public struct CompliancePolicyStatesResponse: Codable {
    public let value: [DeviceCompliancePolicyState]
}

// MARK: - Entra User Models

public struct EntraUser: Codable, Identifiable, Hashable {
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

public struct EntraGroup: Codable, Identifiable, Hashable {
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

public struct DirectoryObject: Codable {
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

public struct CheckMemberGroupsResponse: Codable {
    public let value: [String]
}
