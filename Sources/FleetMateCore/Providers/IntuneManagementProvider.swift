import Foundation

// MARK: - Intune Device (Unified)

/// Intune managed device conforming to UnifiedManagedDevice protocol.
public struct IntuneUnifiedDevice: UnifiedManagedDevice, Sendable {
    public let id: String
    public let provider: String = "intune"
    public let deviceName: String
    public let serialNumber: String?
    public let operatingSystem: String?
    public let osVersion: String?
    public let model: String?
    public let manufacturer: String?
    public let primaryUser: String?
    public let isCompliant: Bool
    public let isManaged: Bool
    public let lastSyncDateTime: Date?
    public let enrolledDateTime: Date?
    public let managementAgentVersion: String?
    public let externalUrl: String?
    
    /// Original Intune device for full access to all fields.
    public let rawDevice: IntuneDevice
    
    public init(from device: IntuneDevice) {
        self.id = device.id
        self.deviceName = device.deviceName ?? "Unknown"
        self.serialNumber = device.serialNumber
        self.operatingSystem = device.operatingSystem
        self.osVersion = device.osVersion
        self.model = device.model
        self.manufacturer = device.manufacturer
        self.primaryUser = device.userPrincipalName
        self.isCompliant = device.complianceState?.lowercased() == "compliant"
        self.isManaged = device.managementState?.lowercased() == "managed"
        self.lastSyncDateTime = Self.parseDate(device.lastSyncDateTime)
        self.enrolledDateTime = Self.parseDate(device.enrolledDateTime)
        self.managementAgentVersion = nil
        
        self.externalUrl = "https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/\(device.id)"
        
        self.rawDevice = device
    }
    
    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}

// MARK: - Intune Management Provider

/// Microsoft Intune management provider implementing ManagementProvider protocol.
public actor IntuneManagementProvider: ManagementProvider {
    public typealias DeviceType = IntuneUnifiedDevice
    
    private let service: GraphService
    private let config: FleetMateConfig
    private var authenticated = false
    
    public nonisolated let providerId: String = "intune"
    public nonisolated let providerName: String = "Microsoft Intune"
    
    public var isEnabled: Bool {
        config.isGraphConfigured
    }
    
    public init(config: FleetMateConfig) {
        self.config = config
        self.service = GraphService(config: config)
    }
    
    public func authenticate() async throws -> Bool {
        do {
            _ = try await service.searchDevices("test", limit: 1)
            authenticated = true
            return true
        } catch {
            authenticated = false
            throw ProviderError.unauthorized
        }
    }
    
    public func listDevices(filter: ManagedDeviceFilter?) async throws -> [IntuneUnifiedDevice] {
        let limit = filter?.limit ?? 100
        let searchText = filter?.searchText ?? ""
        
        let devices = try await service.searchDevices(searchText, limit: limit)
        
        var unified = devices.map { IntuneUnifiedDevice(from: $0) }
        
        // Apply additional filters
        if let os = filter?.operatingSystem {
            unified = unified.filter { $0.operatingSystem?.lowercased().contains(os.lowercased()) ?? false }
        }
        if let compliance = filter?.complianceState {
            let isCompliant = compliance.lowercased() == "compliant"
            unified = unified.filter { $0.isCompliant == isCompliant }
        }
        if let isManaged = filter?.isManaged {
            unified = unified.filter { $0.isManaged == isManaged }
        }
        if let primaryUser = filter?.primaryUser {
            unified = unified.filter { $0.primaryUser?.lowercased().contains(primaryUser.lowercased()) ?? false }
        }
        
        return unified
    }
    
    public func getDevice(deviceId: String) async throws -> IntuneUnifiedDevice? {
        // GraphService would need a getDevice method
        // For now search and filter
        let devices = try await service.searchDevices(deviceId, limit: 10)
        guard let device = devices.first(where: { $0.id == deviceId }) else {
            return nil
        }
        return IntuneUnifiedDevice(from: device)
    }
    
    public func getDeviceBySerial(serialNumber: String) async throws -> IntuneUnifiedDevice? {
        let devices = try await service.searchDevices(serialNumber, limit: 10)
        guard let device = devices.first(where: { $0.serialNumber?.lowercased() == serialNumber.lowercased() }) else {
            return nil
        }
        return IntuneUnifiedDevice(from: device)
    }
    
    public func syncDevice(deviceId: String) async throws {
        // Would need Graph API call to POST /deviceManagement/managedDevices/{id}/syncDevice
        throw ProviderError.apiError("Device sync not yet implemented for Intune")
    }
    
    public func wipeDevice(deviceId: String) async throws {
        // Would need Graph API call to POST /deviceManagement/managedDevices/{id}/wipe
        throw ProviderError.apiError("Device wipe not yet implemented for Intune")
    }
    
    public func getComplianceStatus(deviceId: String) async throws -> ComplianceStatus {
        guard let device = try await getDevice(deviceId: deviceId) else {
            throw ProviderError.itemNotFound(deviceId)
        }
        
        return ComplianceStatus(
            isCompliant: device.isCompliant,
            state: device.rawDevice.complianceState ?? "Unknown",
            details: []
        )
    }
    
    public func listProfiles() async throws -> [DeviceProfile] {
        // Would need Graph API calls to get device configuration profiles
        // For now return empty
        return []
    }
}
