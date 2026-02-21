import Foundation

/// Device information from MunkiReport
public struct MunkiDevice: Codable {
    public var serialNumber: String
    public var hostname: String
    public var machineName: String
    public var osVersion: String
    public var buildVersion: String
    public var machineModel: String
    public var cpuType: String
    public var physicalMemory: Int64
    public var remoteIp: String
    public var timestamp: Date?
    
    init(from row: [String: String]) {
        self.serialNumber = row["serial_number"] ?? ""
        self.hostname = row["hostname"] ?? ""
        self.machineName = row["machine_name"] ?? ""
        self.osVersion = row["os_version"] ?? ""
        self.buildVersion = row["buildversion"] ?? ""
        self.machineModel = row["machine_model"] ?? ""
        self.cpuType = row["cpu_type"] ?? ""
        self.physicalMemory = Int64(row["physical_memory"] ?? "0") ?? 0
        self.remoteIp = row["remote_ip"] ?? ""
        
        if let ts = row["timestamp"] {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            self.timestamp = formatter.date(from: ts)
        }
    }
    
    public var displayName: String {
        if !machineName.isEmpty {
            return machineName
        }
        return hostname.isEmpty ? serialNumber : hostname
    }
    
    public var lastSeenFormatted: String {
        guard let ts = timestamp else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: ts, relativeTo: Date())
    }
}

/// Munki run information
public struct MunkiInfo: Codable {
    public var serialNumber: String
    public var version: String
    public var manifest: String
    public var manifestUrl: String
    public var runType: String
    public var startTime: Date?
    public var endTime: Date?
    
    init(from row: [String: String]) {
        self.serialNumber = row["serial_number"] ?? ""
        self.version = row["version"] ?? ""
        self.manifest = row["manifest"] ?? ""
        self.manifestUrl = row["manifesturl"] ?? ""
        self.runType = row["runtype"] ?? ""
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        if let ts = row["starttime"] {
            self.startTime = formatter.date(from: ts)
        }
        if let ts = row["endtime"] {
            self.endTime = formatter.date(from: ts)
        }
    }
    
    public var duration: String {
        guard let start = startTime, let end = endTime else { return "Unknown" }
        let interval = end.timeIntervalSince(start)
        if interval < 60 {
            return "\(Int(interval)) seconds"
        } else if interval < 3600 {
            return "\(Int(interval / 60)) minutes"
        } else {
            return "\(Int(interval / 3600)) hours"
        }
    }
}

/// Managed install record
public struct ManagedInstall: Codable {
    public var serialNumber: String
    public var name: String
    public var displayName: String
    public var version: String
    public var installedVersion: String
    public var status: String
    public var installed: Bool
    
    init(from row: [String: String]) {
        self.serialNumber = row["serial_number"] ?? ""
        self.name = row["name"] ?? ""
        self.displayName = row["display_name"] ?? ""
        self.version = row["version"] ?? ""
        self.installedVersion = row["installed_version"] ?? ""
        self.status = row["status"] ?? ""
        self.installed = row["installed"] == "1"
    }
    
    public var isError: Bool {
        return !status.isEmpty && status != "installed"
    }
    
    public var statusEmoji: String {
        switch status.lowercased() {
        case "installed": return "✓"
        case "": return "-"
        default: return "✗"
        }
    }
}

/// Installation error record
public struct InstallError: Codable {
    public var serialNumber: String
    public var hostname: String
    public var itemName: String
    public var displayName: String
    public var version: String
    public var status: String
    
    init(from row: [String: String]) {
        self.serialNumber = row["serial_number"] ?? ""
        self.hostname = row["hostname"] ?? ""
        self.itemName = row["name"] ?? ""
        self.displayName = row["display_name"] ?? ""
        self.version = row["version"] ?? ""
        self.status = row["status"] ?? ""
    }
}

/// Install statistics by item
public struct InstallStats: Codable {
    public var name: String
    public var totalDevices: Int
    public var installedCount: Int
    public var failedCount: Int
    
    init(from row: [String: String]) {
        self.name = row["name"] ?? ""
        self.totalDevices = Int(row["total_devices"] ?? "0") ?? 0
        self.installedCount = Int(row["installed"] ?? "0") ?? 0
        self.failedCount = Int(row["failed"] ?? "0") ?? 0
    }
    
    public var successRate: Double {
        guard totalDevices > 0 else { return 0 }
        return Double(installedCount) / Double(totalDevices) * 100
    }
}
