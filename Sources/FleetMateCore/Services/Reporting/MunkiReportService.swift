import Foundation

/// Service for interacting with MunkiReport via SSH
/// Since MunkiReport doesn't have a native API, we SSH into the instance
/// and query the SQLite database directly
public class MunkiReportService {
    let config: FleetMateConfig
    private var sshProcess: Process?
    
    public init(config: FleetMateConfig) {
        self.config = config
    }
    
    public var isConfigured: Bool {
        return config.munkiReportSshHost != nil
    }
    
    // MARK: - SSH Execution
    
    /// Execute a command on the MunkiReport server via SSH
    public func executeSSH(_ command: String) async throws -> String {
        guard let host = config.munkiReportSshHost else {
            throw MunkiReportError.notConfigured
        }
        
        var sshArgs = ["-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
        
        if let keyPath = config.munkiReportSshKeyPath {
            let expandedPath = NSString(string: keyPath).expandingTildeInPath
            sshArgs.append(contentsOf: ["-i", expandedPath])
        }
        
        sshArgs.append("\(config.munkiReportSshUser ?? "root")@\(host)")
        sshArgs.append(command)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArgs
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        if process.terminationStatus != 0 {
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw MunkiReportError.sshFailed(errorString)
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    /// Execute a SQL query on the MunkiReport database
    public func executeSQL(_ query: String) async throws -> [[String: String]] {
        let escapedQuery = query.replacingOccurrences(of: "'", with: "'\"'\"'")
        let dbPath = config.munkiReportDbPath ?? "/var/munkireport/db/db.sqlite"
        let command = "sqlite3 -header -separator '|' '\(dbPath)' '\(escapedQuery)'"
        
        let output = try await executeSSH(command)
        return parseCSV(output)
    }
    
    private func parseCSV(_ output: String) -> [[String: String]] {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }
        
        let headers = lines[0].components(separatedBy: "|")
        var results: [[String: String]] = []
        
        for line in lines.dropFirst() {
            let values = line.components(separatedBy: "|")
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                if index < values.count {
                    row[header] = values[index]
                }
            }
            results.append(row)
        }
        
        return results
    }
    
    // MARK: - Munki Data Queries
    
    /// Get all devices (reportdata)
    public func getDevices() async throws -> [MunkiDevice] {
        let query = """
            SELECT 
                serial_number, hostname, machine_name, os_version, 
                buildversion, machine_model, cpu_type, physical_memory,
                remote_ip, timestamp
            FROM reportdata
            ORDER BY hostname
        """
        
        let rows = try await executeSQL(query)
        return rows.map { MunkiDevice(from: $0) }
    }
    
    /// Get device by serial number or hostname
    public func getDevice(_ identifier: String) async throws -> MunkiDevice? {
        let query = """
            SELECT 
                serial_number, hostname, machine_name, os_version,
                buildversion, machine_model, cpu_type, physical_memory,
                remote_ip, timestamp
            FROM reportdata
            WHERE serial_number = '\(identifier)' OR hostname = '\(identifier)'
            LIMIT 1
        """
        
        let rows = try await executeSQL(query)
        return rows.first.map { MunkiDevice(from: $0) }
    }
    
    /// Get Munki info for a device
    public func getMunkiInfo(serial: String) async throws -> MunkiInfo? {
        let query = """
            SELECT 
                serial_number, version, manifest, manifesturl,
                runtype, starttime, endtime
            FROM munkiinfo
            WHERE serial_number = '\(serial)'
            ORDER BY starttime DESC
            LIMIT 1
        """
        
        let rows = try await executeSQL(query)
        return rows.first.map { MunkiInfo(from: $0) }
    }
    
    /// Get managed installs for a device
    public func getManagedInstalls(serial: String) async throws -> [ManagedInstall] {
        let query = """
            SELECT 
                serial_number, name, display_name, version, installed_version,
                status, installed
            FROM managedinstalls
            WHERE serial_number = '\(serial)'
            ORDER BY name
        """
        
        let rows = try await executeSQL(query)
        return rows.map { ManagedInstall(from: $0) }
    }
    
    /// Get install errors across all devices
    public func getErrors() async throws -> [InstallError] {
        let query = """
            SELECT 
                m.serial_number, r.hostname, m.name, m.display_name,
                m.version, m.status
            FROM managedinstalls m
            JOIN reportdata r ON m.serial_number = r.serial_number
            WHERE m.status != 'installed' AND m.status != ''
            ORDER BY m.name, r.hostname
        """
        
        let rows = try await executeSQL(query)
        return rows.map { InstallError(from: $0) }
    }
    
    /// Get install statistics by item
    public func getInstallStats() async throws -> [InstallStats] {
        let query = """
            SELECT 
                name,
                COUNT(*) as total_devices,
                SUM(CASE WHEN status = 'installed' THEN 1 ELSE 0 END) as installed,
                SUM(CASE WHEN status != 'installed' AND status != '' THEN 1 ELSE 0 END) as failed
            FROM managedinstalls
            GROUP BY name
            HAVING failed > 0
            ORDER BY failed DESC, name
        """
        
        let rows = try await executeSQL(query)
        return rows.map { InstallStats(from: $0) }
    }
    
    /// Get devices with stale check-ins
    public func getStaleDevices(days: Int = 7) async throws -> [MunkiDevice] {
        let query = """
            SELECT 
                serial_number, hostname, machine_name, os_version,
                buildversion, machine_model, cpu_type, physical_memory,
                remote_ip, timestamp
            FROM reportdata
            WHERE timestamp < datetime('now', '-\(days) days')
            ORDER BY timestamp DESC
        """
        
        let rows = try await executeSQL(query)
        return rows.map { MunkiDevice(from: $0) }
    }
    
    /// Execute arbitrary SQL (for advanced queries)
    public func rawQuery(_ sql: String) async throws -> [[String: String]] {
        return try await executeSQL(sql)
    }
    
    /// Run a shell command on the MunkiReport server
    public func runCommand(_ command: String) async throws -> String {
        return try await executeSSH(command)
    }
}

// MARK: - Errors

enum MunkiReportError: LocalizedError {
    case notConfigured
    case sshFailed(String)
    case queryFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "MunkiReport SSH is not configured. Set MUNKIREPORT_SSH_HOST."
        case .sshFailed(let message):
            return "SSH failed: \(message)"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        }
    }
}
