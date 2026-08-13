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

// MARK: - Device Platform

/// The platform a managed device runs, derived from `operatingSystem`.
///
/// Wipe semantics diverge sharply by platform — `obliterationBehavior` is macOS
/// only, Fresh Start and protected wipe are Windows only, and Autopilot
/// registrations exist for Windows alone — so every lifecycle action gates on
/// this rather than trusting the caller to pass a coherent option set.
public enum DevicePlatform: String, Sendable, CaseIterable {
    case macOS
    case windows
    case ios
    case android
    case other

    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .windows: return "Windows"
        case .ios: return "iOS/iPadOS"
        case .android: return "Android"
        case .other: return "Other"
        }
    }

    public init(operatingSystem: String?) {
        switch (operatingSystem ?? "").lowercased() {
        case let os where os.contains("macos") || os.contains("mac os") || os.contains("osx"):
            self = .macOS
        case let os where os.contains("windows"):
            self = .windows
        case let os where os.contains("ios") || os.contains("ipados"):
            self = .ios
        case let os where os.contains("android"):
            self = .android
        default:
            self = .other
        }
    }
}

public extension IntuneDevice {
    var platform: DevicePlatform { DevicePlatform(operatingSystem: operatingSystem) }
}

// MARK: - Wipe Options

/// Options for the Intune `wipe` action.
///
/// Only the keys that apply to the target platform are sent — Graph rejects a
/// macOS `obliterationBehavior` on a Windows device and vice versa, so the body
/// is assembled per platform in `GraphService.wipeDevices`.
public struct WipeOptions: Sendable, Equatable {
    /// macOS 12+ Erase All Content and Settings behaviour. `doNotObliterate`
    /// fails the wipe rather than falling back to the slower full erase.
    public enum ObliterationBehavior: String, Sendable, CaseIterable, Identifiable {
        case `default`
        case doNotObliterate
        case obliterateWithWarning
        case always

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .default: return "Default (EACS, fall back to erase)"
            case .doNotObliterate: return "EACS only (fail if unavailable)"
            case .obliterateWithWarning: return "Erase, warn first"
            case .always: return "Always full erase"
            }
        }
    }

    /// Leave the device enrolled after the wipe (Windows/macOS).
    public var keepEnrollmentData: Bool
    /// Preserve user data — a "reset" rather than a full erase (Windows).
    public var keepUserData: Bool
    /// Windows protected wipe: retries until it succeeds and cannot be
    /// circumvented by the user, at the cost of possibly leaving the device
    /// unbootable if interrupted.
    public var useProtectedWipe: Bool
    /// Keep the eSIM data plan on cellular devices.
    public var persistEsimDataPlan: Bool
    /// Six-digit recovery lock / firmware PIN applied on macOS and iOS wipes.
    public var macOsUnlockCode: String?
    /// macOS 12+ only.
    public var obliterationBehavior: ObliterationBehavior?

    public init(
        keepEnrollmentData: Bool = false,
        keepUserData: Bool = false,
        useProtectedWipe: Bool = false,
        persistEsimDataPlan: Bool = false,
        macOsUnlockCode: String? = nil,
        obliterationBehavior: ObliterationBehavior? = nil
    ) {
        self.keepEnrollmentData = keepEnrollmentData
        self.keepUserData = keepUserData
        self.useProtectedWipe = useProtectedWipe
        self.persistEsimDataPlan = persistEsimDataPlan
        self.macOsUnlockCode = macOsUnlockCode
        self.obliterationBehavior = obliterationBehavior
    }

    /// The request body for `POST managedDevices/{id}/wipe`, trimmed to the keys
    /// the given platform accepts.
    public func requestBody(for platform: DevicePlatform) -> [String: Any] {
        var body: [String: Any] = [
            "keepEnrollmentData": keepEnrollmentData,
            "keepUserData": keepUserData
        ]

        switch platform {
        case .windows:
            if useProtectedWipe { body["useProtectedWipe"] = true }
        case .macOS:
            // macOS has no notion of keeping user data — the erase is total.
            body["keepUserData"] = false
            if let code = macOsUnlockCode, !code.isEmpty { body["macOsUnlockCode"] = code }
            if let behavior = obliterationBehavior { body["obliterationBehavior"] = behavior.rawValue }
        case .ios:
            body["keepUserData"] = false
            if let code = macOsUnlockCode, !code.isEmpty { body["macOsUnlockCode"] = code }
            if persistEsimDataPlan { body["persistEsimDataPlan"] = true }
        case .android, .other:
            break
        }

        return body
    }
}

// MARK: - Offboard

/// A device decommission run: the terminal Intune action plus whichever
/// downstream records should be cleaned up with it.
public struct OffboardPlan: Sendable, Equatable {
    public enum TerminalAction: String, Sendable, CaseIterable, Identifiable {
        case wipe
        case retire
        case none

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .wipe: return "Wipe (factory reset)"
            case .retire: return "Retire (remove company data)"
            case .none: return "Leave the device alone"
            }
        }
    }

    public enum EntraAction: String, Sendable, CaseIterable, Identifiable {
        case none
        case disable
        case delete

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .none: return "Leave the Entra device object"
            case .disable: return "Disable the Entra device object"
            case .delete: return "Delete the Entra device object"
            }
        }
    }

    public var terminalAction: TerminalAction
    public var wipeOptions: WipeOptions
    /// Delete the Intune managedDevice record. Destructive to a *pending* wipe:
    /// if the device has not checked in and picked the command up, removing the
    /// record cancels it.
    public var deleteIntuneRecord: Bool
    /// Delete the Windows Autopilot registration so the hardware hash is
    /// released and the device can be re-registered elsewhere. Windows only.
    public var deleteAutopilotRegistration: Bool
    public var entraAction: EntraAction

    public init(
        terminalAction: TerminalAction = .wipe,
        wipeOptions: WipeOptions = WipeOptions(),
        deleteIntuneRecord: Bool = false,
        deleteAutopilotRegistration: Bool = false,
        entraAction: EntraAction = .none
    ) {
        self.terminalAction = terminalAction
        self.wipeOptions = wipeOptions
        self.deleteIntuneRecord = deleteIntuneRecord
        self.deleteAutopilotRegistration = deleteAutopilotRegistration
        self.entraAction = entraAction
    }
}

public struct OffboardStepResult: Sendable, Identifiable {
    public enum Outcome: String, Sendable {
        case succeeded
        case failed
        case skipped
    }

    public let step: String
    public let outcome: Outcome
    public let detail: String?

    public var id: String { step }

    public init(step: String, outcome: Outcome, detail: String? = nil) {
        self.step = step
        self.outcome = outcome
        self.detail = detail
    }
}

/// One step of a dry run: what would be sent, or why the step drops out.
public struct OffboardPlannedStep: Sendable, Identifiable {
    public let step: String
    public let willRun: Bool
    public let detail: String

    public var id: String { step }

    public init(step: String, willRun: Bool, detail: String) {
        self.step = step
        self.willRun = willRun
        self.detail = detail
    }
}

public struct OffboardResult: Sendable, Identifiable {
    public let identifier: String
    public let deviceName: String?
    public let platform: DevicePlatform
    public let steps: [OffboardStepResult]

    public var id: String { identifier }

    /// A run is a success when nothing failed — skipped steps are expected
    /// (Autopilot on a Mac, an Entra object that was already gone).
    public var success: Bool { !steps.contains { $0.outcome == .failed } }

    public init(identifier: String, deviceName: String?, platform: DevicePlatform, steps: [OffboardStepResult]) {
        self.identifier = identifier
        self.deviceName = deviceName
        self.platform = platform
        self.steps = steps
    }
}
