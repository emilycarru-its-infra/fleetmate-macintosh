import Foundation

// MARK: - Intune Device Models

public struct IntuneDevice: Codable, Identifiable, Sendable {
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
    // Detail fields
    public let managedDeviceName: String?
    public let enrollmentProfileName: String?
    public let isSupervised: Bool?
    public let deviceCategoryDisplayName: String?
    public let managementAgent: String?
    public let notes: String?
    public let physicalMemoryInBytes: Int64?
    public let wiFiMacAddress: String?
    public let ethernetMacAddress: String?
    public let imei: String?
    public let meid: String?
    public let phoneNumber: String?
    public let subscriberCarrier: String?
    public let joinType: String?
    public let skuFamily: String?
    public let azureADRegistered: Bool?
    public let deviceRegistrationState: String?
    
    public var id: String { _id ?? serialNumber ?? UUID().uuidString }
    
    private enum CodingKeys: String, CodingKey {
        case _id = "id"
        case deviceName, serialNumber, operatingSystem, osVersion
        case complianceState, managementState, enrolledDateTime, lastSyncDateTime
        case userPrincipalName, userDisplayName, model, manufacturer
        case deviceEnrollmentType, managedDeviceOwnerType, azureADDeviceId
        case totalStorageSpaceInBytes, freeStorageSpaceInBytes
        case managedDeviceName, enrollmentProfileName, isSupervised
        case deviceCategoryDisplayName, managementAgent, notes
        case physicalMemoryInBytes, wiFiMacAddress, ethernetMacAddress
        case imei, meid, phoneNumber, subscriberCarrier, joinType, skuFamily
        case azureADRegistered, deviceRegistrationState
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

public struct DeviceCompliancePolicyState: Codable, Sendable {
    public let id: String?
    public let displayName: String?
    public let state: String?
    public let platformType: String?
    public let version: Int?
}

public struct CompliancePolicyStatesResponse: Codable {
    public let value: [DeviceCompliancePolicyState]
}

// MARK: - Mobile App Models

public struct MobileApp: Codable, Identifiable, Sendable {
    public let id: String?
    public let displayName: String?
    public let description: String?
    public let publisher: String?
    public let createdDateTime: String?
    public let lastModifiedDateTime: String?
    public let isFeatured: Bool?
    public let privacyInformationUrl: String?
    public let informationUrl: String?
    public let owner: String?
    public let developer: String?
    public let notes: String?
    public let publishingState: String?
    public let odataType: String?
    
    enum CodingKeys: String, CodingKey {
        case id, displayName, description, publisher
        case createdDateTime, lastModifiedDateTime, isFeatured
        case privacyInformationUrl, informationUrl, owner, developer, notes
        case publishingState
        case odataType = "@odata.type"
    }
    
    /// Check if this is a macOS .pkg app
    public var isMacOSPkg: Bool {
        odataType?.contains("macOSDmgApp") == true ||
        odataType?.contains("macOSPkgApp") == true ||
        odataType?.contains("macOSLobApp") == true
    }
    
    /// Check if this is a Windows .intunewin app
    public var isWindowsApp: Bool {
        odataType?.contains("win32LobApp") == true ||
        odataType?.contains("windowsUniversalAppX") == true ||
        odataType?.contains("windowsMicrosoftEdgeApp") == true
    }
}

public struct MobileAppsResponse: Codable {
    public let value: [MobileApp]
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct MobileAppInstallStatus: Codable, Identifiable, Sendable {
    public let id: String?
    public let deviceId: String?
    public let deviceName: String?
    public let displayName: String?
    public let displayVersion: String?
    public let installState: String?
    public let installStateDetail: String?
    public let errorCode: Int?
    public let lastSyncDateTime: String?
    public let mobileAppInstallStatusValue: String?
}

public struct MobileAppInstallStatusResponse: Codable {
    public let value: [MobileAppInstallStatus]
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Detected Apps

public struct DetectedApp: Codable, Identifiable, Sendable {
    public let id: String?
    public let displayName: String?
    public let version: String?
    public let sizeInByte: Int64?
    public let deviceCount: Int?
    public let publisher: String?
    public let platform: String?
}

public struct DetectedAppsResponse: Codable {
    public let value: [DetectedApp]
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Device Detail Models

public struct DeviceGroupMembership: Codable, Identifiable, Sendable {
    public let id: String?
    public let displayName: String?
    public let description: String?
    public let odataType: String?
    
    enum CodingKeys: String, CodingKey {
        case id, displayName, description
        case odataType = "@odata.type"
    }
    
    public var isGroup: Bool {
        odataType?.contains("group") ?? false
    }
}

public struct DeviceMemberOfResponse: Codable {
    public let value: [DeviceGroupMembership]
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct ManagedAppRegistration: Codable, Identifiable, Sendable {
    public let id: String?
    public let appIdentifier: AppIdentifier?
    public let createdDateTime: String?
    public let lastSyncDateTime: String?
    public let version: String?
    public let deviceName: String?
    public let deviceTag: String?
    public let managementSdkVersion: String?
    public let platformVersion: String?
    public let userId: String?
    public let odataType: String?
    
    enum CodingKeys: String, CodingKey {
        case id, appIdentifier, createdDateTime, lastSyncDateTime
        case version, deviceName, deviceTag, managementSdkVersion
        case platformVersion, userId
        case odataType = "@odata.type"
    }
}

public struct AppIdentifier: Codable, Sendable {
    public let bundleId: String?
    public let packageId: String?
    
    public var displayId: String {
        bundleId ?? packageId ?? "Unknown"
    }
}

public struct ManagedAppRegistrationsResponse: Codable {
    public let value: [ManagedAppRegistration]
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

// MARK: - Bulk Action Results

public struct BulkActionResult: Sendable {
    public let deviceId: String
    public let success: Bool
    public let error: String?

    public init(deviceId: String, success: Bool, error: String? = nil) {
        self.deviceId = deviceId
        self.success = success
        self.error = error
    }
}

// MARK: - Windows Autopilot

public struct WindowsAutopilotDevice: Codable, Identifiable, Sendable {
    public let id: String?
    public let displayName: String?
    public let serialNumber: String?
    public let productKey: String?
    public let manufacturer: String?
    public let model: String?
    public let enrollmentState: String?
    public let lastContactedDateTime: String?
    public let addressableUserName: String?
    public let userPrincipalName: String?
    public let resourceName: String?
    public let skuNumber: String?
    public let systemFamily: String?
    public let azureActiveDirectoryDeviceId: String?
    public let managedDeviceId: String?
    public let deploymentProfileAssignmentStatus: String?
    public let deploymentProfileAssignedDateTime: String?
}

public struct WindowsAutopilotDevicesResponse: Codable {
    public let value: [WindowsAutopilotDevice]
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}
