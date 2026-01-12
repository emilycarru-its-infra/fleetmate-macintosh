import Foundation

// MARK: - Intune Device Models

struct IntuneDevice: Codable {
    let id: String?
    let deviceName: String?
    let serialNumber: String?
    let operatingSystem: String?
    let osVersion: String?
    let complianceState: String?
    let managementState: String?
    let enrolledDateTime: String?
    let lastSyncDateTime: String?
    let userPrincipalName: String?
    let userDisplayName: String?
    let model: String?
    let manufacturer: String?
    let deviceEnrollmentType: String?
    let managedDeviceOwnerType: String?
    let azureADDeviceId: String?
    let totalStorageSpaceInBytes: Int64?
    let freeStorageSpaceInBytes: Int64?
}

struct IntuneDeviceListResponse: Codable {
    let value: [IntuneDevice]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

struct DeviceCompliancePolicyState: Codable {
    let id: String?
    let displayName: String?
    let state: String?
    let platformType: String?
    let version: Int?
}

struct CompliancePolicyStatesResponse: Codable {
    let value: [DeviceCompliancePolicyState]
}

// MARK: - Entra User Models

struct EntraUser: Codable {
    let id: String?
    let displayName: String?
    let userPrincipalName: String?
    let mail: String?
    let jobTitle: String?
    let department: String?
    let officeLocation: String?
    let mobilePhone: String?
    let accountEnabled: Bool?
    var memberOf: [EntraGroup]?

    var email: String {
        mail ?? userPrincipalName ?? ""
    }
}

struct EntraUserListResponse: Codable {
    let value: [EntraUser]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Entra Group Models

struct EntraGroup: Codable {
    let id: String?
    let displayName: String?
    let description: String?
    let mail: String?
    let mailEnabled: Bool?
    let securityEnabled: Bool?
    let groupTypes: [String]?
}

struct EntraGroupListResponse: Codable {
    let value: [EntraGroup]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Membership Check Models

struct DirectoryObject: Codable {
    let id: String?
    let displayName: String?
    let description: String?
    let odataType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case description
        case odataType = "@odata.type"
    }

    var isGroup: Bool {
        odataType?.contains("group") == true
    }
}

struct UserMemberOfResponse: Codable {
    let value: [DirectoryObject]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

struct GroupMembersResponse: Codable {
    let value: [EntraUser]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

struct CheckMemberGroupsResponse: Codable {
    let value: [String]
}
