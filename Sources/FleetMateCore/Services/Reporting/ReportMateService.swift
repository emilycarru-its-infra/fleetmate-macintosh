import Foundation
import Alamofire
import Logging

/// Client for ReportMate API - fleet monitoring and device inventory
/// This is the shared reporting system for both Mac (Munki) and Windows (Cimian) devices
public class ReportMateService {
    private let baseUrl: String
    private let passphrase: String?
    /// When set, authenticate with an Entra bearer token for this audience
    /// (SSO / az model) instead of the passphrase. See FleetMateConfig.
    private let oidcAudience: String?
    private let session: Session
    private let logger = Logger(label: "com.fleetmate.reportmate")
    
    // Caches
    private var deviceCache: [ReportMateDevice]?
    private var deviceCacheExpiry: Date = .distantPast
    private var installCache: [InstallRecord]?
    private var installCacheExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval
    
    /// Check if service is configured with required credentials
    public var isConfigured: Bool {
        return !baseUrl.isEmpty
    }
    
    public init(baseUrl: String?, passphrase: String?, oidcAudience: String? = nil, cacheMinutes: Int = 5) {
        self.baseUrl = (baseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.passphrase = passphrase
        self.oidcAudience = (oidcAudience?.isEmpty == false) ? oidcAudience : nil
        self.cacheDuration = TimeInterval(cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120

        self.session = Session(configuration: configuration)
    }

    /// Convenience initializer from config
    public convenience init(config: FleetMateConfig) {
        self.init(
            baseUrl: config.reportMateUrl,
            passphrase: config.reportMatePassphrase,
            oidcAudience: config.reportMateOidcAudience,
            cacheMinutes: config.cacheMinutes
        )
    }

    /// True when configured to use Entra bearer (SSO) auth rather than the passphrase.
    public var usesOidc: Bool { oidcAudience != nil }

    private let baseHeaders: HTTPHeaders = [
        "Accept": "application/json",
        "Content-Type": "application/json",
    ]

    /// Resolve the auth headers for a request: an Entra bearer token minted off
    /// the operator's az/login session when an OIDC audience is configured
    /// (prefer-bearer), otherwise the legacy X-Client-Passphrase. Both are
    /// accepted by the API, so unset audience is a safe no-op fallback.
    private func authHeaders() async throws -> HTTPHeaders {
        var hdrs = baseHeaders
        if let audience = oidcAudience {
            let token = try await AzTokenSource.shared.token(forResource: audience)
            hdrs.add(name: "Authorization", value: "Bearer \(token)")
        } else if let passphrase = passphrase, !passphrase.isEmpty {
            hdrs.add(name: "X-Client-Passphrase", value: passphrase)
        }
        return hdrs
    }
    
    // MARK: - Devices
    
    /// Get all devices from the fleet
    public func getDevices(forceRefresh: Bool = false) async throws -> [ReportMateDevice] {
        if !forceRefresh, let cache = deviceCache, Date() < deviceCacheExpiry {
            return cache
        }
        
        logger.debug("Fetching devices from ReportMate...")
        
        var allDevices: [ReportMateDevice] = []
        var offset = 0
        let limit = 100
        
        while true {
            let url = "\(baseUrl)/api/v1/devices?offset=\(offset)&limit=\(limit)"
            
            let response: DevicesResponse? = try await fetch(url)
            guard let wrapper = response, !wrapper.devices.isEmpty else {
                break
            }
            
            allDevices.append(contentsOf: wrapper.devices)
            
            if wrapper.devices.count < limit {
                break
            }
            
            offset += limit
        }
        
        deviceCache = allDevices
        deviceCacheExpiry = Date().addingTimeInterval(cacheDuration)
        logger.info("Cached \(allDevices.count) devices from ReportMate")
        
        return allDevices
    }
    
    /// Find a device by serial, hostname, asset tag, or other identifier
    public func findDevice(_ query: String) async throws -> ReportMateDevice? {
        let devices = try await getDevices()
        let normalized = query.trimmingCharacters(in: .whitespaces).uppercased()
        
        return devices.first { device in
            device.serialNumber.uppercased() == normalized ||
            device.deviceName.uppercased() == normalized ||
            device.name.uppercased() == normalized ||
            device.hostname.uppercased() == normalized ||
            device.assetTag.uppercased() == normalized ||
            device.owner.uppercased() == normalized ||
            device.ipAddress == query ||
            normalizeMac(device.macAddress) == normalizeMac(query)
        }
    }
    
    // MARK: - Installs
    
    /// Get all install records
    public func getInstalls(forceRefresh: Bool = false) async throws -> [InstallRecord] {
        if !forceRefresh, let cache = installCache, Date() < installCacheExpiry {
            return cache
        }
        
        logger.debug("Fetching install records from ReportMate...")
        
        let url = "\(baseUrl)/api/devices/installs"
        let installs: [InstallRecord]? = try await fetch(url)
        
        installCache = installs ?? []
        installCacheExpiry = Date().addingTimeInterval(cacheDuration)
        logger.info("Cached \(installCache?.count ?? 0) install records from ReportMate")
        
        return installCache ?? []
    }
    
    /// Get only install records with errors
    public func getErrors(forceRefresh: Bool = false) async throws -> [InstallRecord] {
        let installs = try await getInstalls(forceRefresh: forceRefresh)
        return installs.filter { $0.isError }
    }
    
    /// Get errors grouped by item name
    public func getErrorsByItem(forceRefresh: Bool = false) async throws -> [ErrorSummary] {
        let errors = try await getErrors(forceRefresh: forceRefresh)
        
        var grouped: [String: [InstallRecord]] = [:]
        for error in errors {
            grouped[error.itemName, default: []].append(error)
        }
        
        return grouped.map { (itemName, records) in
            ErrorSummary(
                itemName: itemName,
                deviceCount: records.count,
                category: records.first?.category ?? .unknown,
                sampleError: records.first?.lastError ?? "",
                affectedDevices: records.map { "\($0.deviceName) (\($0.serialNumber))" }
            )
        }.sorted { $0.deviceCount > $1.deviceCount }
    }
    
    /// Get errors grouped by device
    public func getErrorsByDevice(forceRefresh: Bool = false) async throws -> [DeviceErrorSummary] {
        let errors = try await getErrors(forceRefresh: forceRefresh)
        
        var grouped: [String: [InstallRecord]] = [:]
        for error in errors {
            grouped[error.serialNumber, default: []].append(error)
        }
        
        return grouped.map { (serial, records) in
            DeviceErrorSummary(
                deviceName: records.first?.deviceName ?? "",
                serialNumber: serial,
                location: records.first?.location ?? "",
                errorCount: records.count,
                failedItems: records.map { $0.itemName },
                lastSeen: records.compactMap { $0.lastSeen }.max()
            )
        }.sorted { $0.errorCount > $1.errorCount }
    }
    
    /// Get install records for a specific device
    public func getDeviceInstalls(_ serialOrName: String) async throws -> [InstallRecord] {
        let installs = try await getInstalls()
        let normalized = serialOrName.trimmingCharacters(in: .whitespaces).uppercased()
        
        return installs.filter { install in
            install.serialNumber.uppercased() == normalized ||
            install.deviceName.uppercased() == normalized
        }
    }
    
    /// Get install records for a specific item across all devices
    public func getItemInstalls(_ itemName: String) async throws -> [InstallRecord] {
        let installs = try await getInstalls()
        return installs.filter { $0.itemName.lowercased() == itemName.lowercased() }
    }
    
    // MARK: - Device Details
    
    /// Get device installation log (Munki log entries)
    public func getDeviceLog(_ serialNumber: String) async throws -> DeviceLog? {
        logger.debug("Fetching install log for device \(serialNumber)")
        
        let url = "\(baseUrl)/api/device/\(serialNumber)/installs/log"
        return try await fetch(url)
    }
    
    /// Get device network information including IP addresses
    public func getDeviceNetwork(_ serialNumber: String) async throws -> NetworkInfo? {
        logger.debug("Fetching network info for device \(serialNumber)")
        
        let url = "\(baseUrl)/api/device/\(serialNumber)/modules/network"
        
        // The API returns wrapped data, need to decode appropriately
        if let wrapper: ModuleDataWrapper = try await fetch(url),
           let data = wrapper.data {
            // Parse network info from the data dict
            return parseNetworkInfo(from: data)
        }
        
        return nil
    }
    
    /// Get fleet-wide network data (all devices with network info)
    public func getFleetNetwork() async throws -> [DeviceNetworkInfo] {
        logger.debug("Fetching fleet network data...")
        
        let url = "\(baseUrl)/api/devices/network"
        return try await fetch(url) ?? []
    }
    
    /// Get full device details with all modules
    public func getFullDevice(_ serialNumber: String) async throws -> FullDevice? {
        logger.debug("Fetching full device data for \(serialNumber)")
        
        let url = "\(baseUrl)/api/device/\(serialNumber)"
        return try await fetch(url)
    }
    
    // MARK: - Statistics
    
    /// Get fleet statistics
    public func getFleetStats() async throws -> FleetStats {
        let devices = try await getDevices()
        let installs = try await getInstalls()
        let errors = installs.filter { $0.isError }
        
        // Calculate stale devices (not seen in 7 days)
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let stale = devices.filter { device in
            guard let lastSeen = device.lastSeen else { return true }
            return lastSeen < sevenDaysAgo
        }
        
        // Pending installs (items not yet installed)
        let pending = installs.filter { install in
            install.currentStatus.lowercased() == "pending" || 
            install.installedVersion.isEmpty
        }
        
        return FleetStats(
            totalDevices: devices.count,
            staleDevices: stale.count,
            totalInstalls: installs.count,
            pendingInstalls: pending.count,
            totalErrors: errors.count
        )
    }
    
    // MARK: - Private Helpers
    
    private func fetch<T: Decodable>(_ url: String) async throws -> T? {
        let hdrs = try await authHeaders()
        return try await withCheckedThrowingContinuation { continuation in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                
                // Try multiple date formats
                let formats = [
                    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                    "yyyy-MM-dd'T'HH:mm:ssZ",
                    "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd"
                ]
                
                for format in formats {
                    let formatter = DateFormatter()
                    formatter.dateFormat = format
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                }
                
                // Try ISO8601
                if let date = ISO8601DateFormatter().date(from: dateString) {
                    return date
                }
                
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
            }
            
            session.request(url, headers: hdrs)
                .validate()
                .responseDecodable(of: T.self, decoder: decoder) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        if case .responseValidationFailed(reason: .unacceptableStatusCode(code: 404)) = error {
                            continuation.resume(returning: nil)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
        }
    }
    
    private func normalizeMac(_ mac: String?) -> String {
        guard let mac = mac else { return "" }
        return mac.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .uppercased()
    }
    
    private func parseNetworkInfo(from data: [String: Any]) -> NetworkInfo {
        // Parse network data from the module response
        // Structure depends on ReportMate API format
        var interfaces: [NetworkInterface] = []
        
        if let ifaceList = data["interfaces"] as? [[String: Any]] {
            for iface in ifaceList {
                interfaces.append(NetworkInterface(
                    name: iface["name"] as? String ?? "",
                    macAddress: iface["mac_address"] as? String ?? "",
                    ipv4Addresses: iface["ipv4_addresses"] as? [String] ?? [],
                    ipv6Addresses: iface["ipv6_addresses"] as? [String] ?? [],
                    isPrimary: iface["is_primary"] as? Bool ?? false
                ))
            }
        }
        
        return NetworkInfo(interfaces: interfaces)
    }
}

// MARK: - Fleet Stats

public struct FleetStats: Codable {
    public var totalDevices: Int
    public var staleDevices: Int
    public var totalInstalls: Int
    public var pendingInstalls: Int
    public var totalErrors: Int
    
    public init(totalDevices: Int = 0, staleDevices: Int = 0, totalInstalls: Int = 0,
                pendingInstalls: Int = 0, totalErrors: Int = 0) {
        self.totalDevices = totalDevices
        self.staleDevices = staleDevices
        self.totalInstalls = totalInstalls
        self.pendingInstalls = pendingInstalls
        self.totalErrors = totalErrors
    }
}
