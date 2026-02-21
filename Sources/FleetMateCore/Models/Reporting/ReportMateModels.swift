import Foundation

// MARK: - Device Models

/// Device information from ReportMate API
public struct ReportMateDevice: Codable {
    public var id: String
    public var deviceId: String
    public var serialNumber: String
    public var deviceName: String
    public var name: String
    public var hostname: String
    public var owner: String
    public var assetTag: String
    public var location: String
    public var catalog: String
    public var ipAddress: String
    public var macAddress: String
    public var osVersion: String
    public var osBuild: String
    public var architecture: String
    public var manufacturer: String
    public var model: String
    public var lastSeen: Date?
    public var collectedAt: Date?
    
    // Munki-specific fields (Mac equivalent of Cimian)
    public var munkiVersion: String
    public var manifestUrl: String
    public var catalogUrl: String
    
    /// Display name for the device (prefers DeviceName, falls back to Name/Hostname)
    public var displayName: String {
        if !deviceName.isEmpty { return deviceName }
        if !name.isEmpty { return name }
        if !hostname.isEmpty { return hostname }
        return serialNumber
    }
    
    public init() {
        id = ""
        deviceId = ""
        serialNumber = ""
        deviceName = ""
        name = ""
        hostname = ""
        owner = ""
        assetTag = ""
        location = ""
        catalog = ""
        ipAddress = ""
        macAddress = ""
        osVersion = ""
        osBuild = ""
        architecture = ""
        manufacturer = ""
        model = ""
        lastSeen = nil
        collectedAt = nil
        munkiVersion = ""
        manifestUrl = ""
        catalogUrl = ""
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case serialNumber = "serial_number"
        case deviceName = "device_name"
        case name
        case hostname
        case owner
        case assetTag = "asset_tag"
        case location
        case catalog
        case ipAddress = "ip_address"
        case macAddress = "mac_address"
        case osVersion = "os_version"
        case osBuild = "os_build"
        case architecture
        case manufacturer
        case model
        case lastSeen = "last_seen"
        case collectedAt = "collected_at"
        case munkiVersion = "munki_version"
        case manifestUrl = "manifest_url"
        case catalogUrl = "catalog_url"
    }
}

/// Response wrapper from ReportMate /api/devices endpoint
public struct DevicesResponse: Codable {
    public var devices: [ReportMateDevice]
    public var total: Int
    public var offset: Int
    public var limit: Int
    
    public init() {
        devices = []
        total = 0
        offset = 0
        limit = 0
    }
    
    enum CodingKeys: String, CodingKey {
        case devices
        case total
        case offset
        case limit
    }
}

// MARK: - Install Record Models

/// Represents an installation record from ReportMate /api/devices/installs endpoint
public struct InstallRecord: Codable {
    public var id: String
    public var deviceId: String
    public var deviceName: String
    public var serialNumber: String
    public var lastSeen: Date?
    public var collectedAt: Date?
    public var itemName: String
    public var currentStatus: String
    public var latestVersion: String
    public var installedVersion: String
    public var installDate: Date?
    public var usage: String
    public var catalog: String
    public var location: String
    
    /// Raw nested object containing detailed error info
    public var raw: InstallRawInfo?
    
    /// Convenience property to get the error message
    public var lastError: String? { raw?.lastError }
    
    /// Convenience property to get the warning message
    public var lastWarning: String? { raw?.lastWarning }
    
    /// Whether this record represents an error state
    public var isError: Bool {
        let status = currentStatus.lowercased()
        return status == "failed" || status == "error" || status == "needs_reinstall"
    }
    
    /// Categorizes the error type for grouping/analysis
    public var category: ErrorCategory {
        categorizeError()
    }
    
    private func categorizeError() -> ErrorCategory {
        guard let error = lastError?.lowercased(), !error.isEmpty else {
            return .unknown
        }
        
        if error.contains("404") || error.contains("file not found") || error.contains("resource may have been moved") {
            return .notFound
        }
        if error.contains("hash validation failed") || error.contains("checksum") {
            return .hashMismatch
        }
        if error.contains("action failed after") || error.contains("download") {
            return .downloadFailed
        }
        if error.contains("pkg installation failed") || error.contains("installer error") {
            return .pkgFailure
        }
        if error.contains("not signed") || error.contains("signature verification") || error.contains("gatekeeper") {
            return .signatureRequired
        }
        if error.contains("not found in any catalog") {
            return .catalogMissing
        }
        if error.contains("verification failed") || error.contains("cancelled") || error.contains("failed silently") {
            return .installVerificationFailed
        }
        if error.contains("no installer location") || error.contains("missing installer") {
            return .missingInstallerLocation
        }
        if error.contains("disk full") || error.contains("no space") {
            return .diskFull
        }
        
        return .other
    }
    
    public init() {
        id = ""
        deviceId = ""
        deviceName = ""
        serialNumber = ""
        lastSeen = nil
        collectedAt = nil
        itemName = ""
        currentStatus = ""
        latestVersion = ""
        installedVersion = ""
        installDate = nil
        usage = ""
        catalog = ""
        location = ""
        raw = nil
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case deviceName = "device_name"
        case serialNumber = "serial_number"
        case lastSeen = "last_seen"
        case collectedAt = "collected_at"
        case itemName = "item_name"
        case currentStatus = "current_status"
        case latestVersion = "latest_version"
        case installedVersion = "installed_version"
        case installDate = "install_date"
        case usage
        case catalog
        case location
        case raw
    }
}

/// Raw installation details from ReportMate API
public struct InstallRawInfo: Codable {
    public var id: String
    public var itemName: String
    public var itemType: String
    public var displayName: String
    public var lastError: String
    public var lastWarning: String
    public var lastUpdate: Date?
    public var lastAttemptTime: Date?
    public var lastAttemptStatus: String
    public var currentStatus: String
    public var mappedStatus: String
    public var installMethod: String
    public var latestVersion: String
    public var installedVersion: String
    public var updateCount: Int
    public var installCount: Int
    public var failureCount: Int
    public var warningCount: Int
    public var totalSessions: Int
    public var hasInstallLoop: Bool
    public var installLoopDetected: Bool
    public var lastSeenInSession: Date?
    
    public init() {
        id = ""
        itemName = ""
        itemType = ""
        displayName = ""
        lastError = ""
        lastWarning = ""
        lastUpdate = nil
        lastAttemptTime = nil
        lastAttemptStatus = ""
        currentStatus = ""
        mappedStatus = ""
        installMethod = ""
        latestVersion = ""
        installedVersion = ""
        updateCount = 0
        installCount = 0
        failureCount = 0
        warningCount = 0
        totalSessions = 0
        hasInstallLoop = false
        installLoopDetected = false
        lastSeenInSession = nil
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case itemName = "item_name"
        case itemType = "item_type"
        case displayName = "display_name"
        case lastError = "last_error"
        case lastWarning = "last_warning"
        case lastUpdate = "last_update"
        case lastAttemptTime = "last_attempt_time"
        case lastAttemptStatus = "last_attempt_status"
        case currentStatus = "current_status"
        case mappedStatus = "mapped_status"
        case installMethod = "install_method"
        case latestVersion = "latest_version"
        case installedVersion = "installed_version"
        case updateCount = "update_count"
        case installCount = "install_count"
        case failureCount = "failure_count"
        case warningCount = "warning_count"
        case totalSessions = "total_sessions"
        case hasInstallLoop = "has_install_loop"
        case installLoopDetected = "install_loop_detected"
        case lastSeenInSession = "last_seen_in_session"
    }
}

// MARK: - Error Categories

/// Categorization of error types for analysis and remediation
public enum ErrorCategory: String, Codable, CaseIterable {
    case unknown = "Unknown"
    case notFound = "Not Found"                         // 404 - package file missing from CDN
    case hashMismatch = "Hash Mismatch"                 // Downloaded file hash doesn't match pkginfo
    case downloadFailed = "Download Failed"             // Generic download failure after retries
    case pkgFailure = "PKG Failure"                     // PKG installer error (macOS equivalent of MSI)
    case signatureRequired = "Signature Required"        // Package not signed but signature required
    case catalogMissing = "Catalog Missing"             // Item not found in any catalog
    case installVerificationFailed = "Verification Failed"  // postinstall verification failed
    case missingInstallerLocation = "Missing Installer"     // pkginfo missing installer_location
    case diskFull = "Disk Full"                         // No space on device
    case other = "Other"                                // Uncategorized error
    
    public var emoji: String {
        switch self {
        case .unknown: return "❓"
        case .notFound: return "🔍"
        case .hashMismatch: return "🔐"
        case .downloadFailed: return "⬇️"
        case .pkgFailure: return "📦"
        case .signatureRequired: return "✍️"
        case .catalogMissing: return "📋"
        case .installVerificationFailed: return "❌"
        case .missingInstallerLocation: return "📂"
        case .diskFull: return "💾"
        case .other: return "⚠️"
        }
    }
}

// MARK: - Summary Models

/// Summary of errors grouped for display
public struct ErrorSummary: Codable {
    public var itemName: String
    public var deviceCount: Int
    public var category: ErrorCategory
    public var sampleError: String
    public var affectedDevices: [String]
    
    public init(itemName: String = "", deviceCount: Int = 0, category: ErrorCategory = .unknown, 
                sampleError: String = "", affectedDevices: [String] = []) {
        self.itemName = itemName
        self.deviceCount = deviceCount
        self.category = category
        self.sampleError = sampleError
        self.affectedDevices = affectedDevices
    }
}

/// Summary of errors by device
public struct DeviceErrorSummary: Codable {
    public var deviceName: String
    public var serialNumber: String
    public var location: String
    public var errorCount: Int
    public var failedItems: [String]
    public var lastSeen: Date?
    
    public init(deviceName: String = "", serialNumber: String = "", location: String = "",
                errorCount: Int = 0, failedItems: [String] = [], lastSeen: Date? = nil) {
        self.deviceName = deviceName
        self.serialNumber = serialNumber
        self.location = location
        self.errorCount = errorCount
        self.failedItems = failedItems
        self.lastSeen = lastSeen
    }
}

// MARK: - Network Models

/// Network information for a device
public struct NetworkInfo: Codable {
    public var interfaces: [NetworkInterface]
    
    public var primaryIpv4: String? {
        // Find primary interface (usually en0 on Mac)
        for iface in interfaces {
            if iface.name == "en0" || iface.isPrimary {
                if let ipv4 = iface.ipv4Addresses.first {
                    return ipv4
                }
            }
        }
        // Fallback to any non-loopback IPv4
        for iface in interfaces where iface.name != "lo0" {
            if let ipv4 = iface.ipv4Addresses.first {
                return ipv4
            }
        }
        return nil
    }
    
    public init(interfaces: [NetworkInterface] = []) {
        self.interfaces = interfaces
    }
}

public struct NetworkInterface: Codable {
    public var name: String
    public var macAddress: String
    public var ipv4Addresses: [String]
    public var ipv6Addresses: [String]
    public var isPrimary: Bool
    
    public init(name: String = "", macAddress: String = "", ipv4Addresses: [String] = [],
                ipv6Addresses: [String] = [], isPrimary: Bool = false) {
        self.name = name
        self.macAddress = macAddress
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
        self.isPrimary = isPrimary
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case macAddress = "mac_address"
        case ipv4Addresses = "ipv4_addresses"
        case ipv6Addresses = "ipv6_addresses"
        case isPrimary = "is_primary"
    }
}

/// Device network info summary for fleet-wide queries
public struct DeviceNetworkInfo: Codable {
    public var serialNumber: String
    public var deviceName: String
    public var primaryIp: String
    public var macAddress: String
    
    public init(serialNumber: String = "", deviceName: String = "", primaryIp: String = "", macAddress: String = "") {
        self.serialNumber = serialNumber
        self.deviceName = deviceName
        self.primaryIp = primaryIp
        self.macAddress = macAddress
    }
    
    enum CodingKeys: String, CodingKey {
        case serialNumber = "serial_number"
        case deviceName = "device_name"
        case primaryIp = "primary_ip"
        case macAddress = "mac_address"
    }
}

// MARK: - Device Log

/// Device installation log entries
public struct DeviceLog: Codable {
    public var serialNumber: String
    public var entries: [LogEntry]
    
    public init(serialNumber: String = "", entries: [LogEntry] = []) {
        self.serialNumber = serialNumber
        self.entries = entries
    }
    
    enum CodingKeys: String, CodingKey {
        case serialNumber = "serial_number"
        case entries
    }
}

public struct LogEntry: Codable {
    public var timestamp: Date?
    public var level: String
    public var message: String
    public var item: String?
    
    public init(timestamp: Date? = nil, level: String = "", message: String = "", item: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.item = item
    }
}

// MARK: - Full Device (with modules)

public struct FullDevice: Codable {
    public var device: ReportMateDevice
    public var installs: [InstallRecord]
    public var network: NetworkInfo?
    public var log: DeviceLog?
    
    public init(device: ReportMateDevice = ReportMateDevice(), installs: [InstallRecord] = [],
                network: NetworkInfo? = nil, log: DeviceLog? = nil) {
        self.device = device
        self.installs = installs
        self.network = network
        self.log = log
    }
}

// MARK: - Module Data Wrapper (for network/log endpoints)

public struct ModuleDataWrapper: Codable {
    public var data: [String: Any]?
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            self.data = dict.mapValues { $0.value }
        } else {
            self.data = nil
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let data = data {
            try container.encode(data.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }
}

// Helper for encoding/decoding Any values
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            value = ""
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
}
