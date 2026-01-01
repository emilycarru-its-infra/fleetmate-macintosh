import Foundation

/// Device information from MunkiReport
struct MunkiDevice: Codable {
    var serialNumber: String
    var hostname: String
    var machineName: String
    var osVersion: String
    var buildVersion: String
    var machineModel: String
    var cpuType: String
    var physicalMemory: Int64
    var remoteIp: String
    var timestamp: Date?
    
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
    
    var displayName: String {
        if !machineName.isEmpty {
            return machineName
        }
        return hostname.isEmpty ? serialNumber : hostname
    }
    
    var lastSeenFormatted: String {
        guard let ts = timestamp else { return "Unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: ts, relativeTo: Date())
    }
}

/// Munki run information
struct MunkiInfo: Codable {
    var serialNumber: String
    var version: String
    var manifest: String
    var manifestUrl: String
    var runType: String
    var startTime: Date?
    var endTime: Date?
    
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
    
    var duration: String {
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
struct ManagedInstall: Codable {
    var serialNumber: String
    var name: String
    var displayName: String
    var version: String
    var installedVersion: String
    var status: String
    var installed: Bool
    
    init(from row: [String: String]) {
        self.serialNumber = row["serial_number"] ?? ""
        self.name = row["name"] ?? ""
        self.displayName = row["display_name"] ?? ""
        self.version = row["version"] ?? ""
        self.installedVersion = row["installed_version"] ?? ""
        self.status = row["status"] ?? ""
        self.installed = row["installed"] == "1"
    }
    
    var isError: Bool {
        return !status.isEmpty && status != "installed"
    }
    
    var statusEmoji: String {
        switch status.lowercased() {
        case "installed": return "✓"
        case "": return "-"
        default: return "✗"
        }
    }
}

/// Installation error record
struct InstallError: Codable {
    var serialNumber: String
    var hostname: String
    var itemName: String
    var displayName: String
    var version: String
    var status: String
    
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
struct InstallStats: Codable {
    var name: String
    var totalDevices: Int
    var installedCount: Int
    var failedCount: Int
    
    init(from row: [String: String]) {
        self.name = row["name"] ?? ""
        self.totalDevices = Int(row["total_devices"] ?? "0") ?? 0
        self.installedCount = Int(row["installed"] ?? "0") ?? 0
        self.failedCount = Int(row["failed"] ?? "0") ?? 0
    }
    
    var successRate: Double {
        guard totalDevices > 0 else { return 0 }
        return Double(installedCount) / Double(totalDevices) * 100
    }
}
