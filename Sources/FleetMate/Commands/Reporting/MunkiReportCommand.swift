import ArgumentParser
import Foundation
import Rainbow
import FleetMateCore

/// MunkiReport command - Query MunkiReport database via SSH
struct MunkiReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "munkireport",
        abstract: "Query MunkiReport database",
        discussion: """
            Access MunkiReport data via SSH connection to the database server.
            Requires SSH access configured (keys in Keychain or ~/.ssh/).
            """,
        subcommands: [
            MunkiDevicesSubcommand.self,
            MunkiDeviceSubcommand.self,
            InfoSubcommand.self,
            InstallsSubcommand.self,
            MunkiErrorsSubcommand.self,
            StaleSubcommand.self,
            QuerySubcommand.self
        ],
        defaultSubcommand: MunkiDevicesSubcommand.self
    )
}

// MARK: - List Devices

struct MunkiDevicesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List all devices in MunkiReport"
    )
    
    @Option(name: .shortAndLong, help: "Filter by machine model type")
    var type: String?
    
    @Option(name: .shortAndLong, help: "Maximum number of devices to show")
    var limit: Int = 50
    
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        var devices = try await service.getDevices()
        
        if let type = type {
            devices = devices.filter { $0.machineModel.lowercased().contains(type.lowercased()) }
        }
        
        if devices.count > limit {
            devices = Array(devices.prefix(limit))
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(devices)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printDevicesTable(devices)
        }
    }
    
    private func printDevicesTable(_ devices: [MunkiDevice]) {
        print("\n" + "MunkiReport Devices".bold + " (\(devices.count) total)\n")
        
        let header = String(format: "%-20s %-30s %-15s %-20s",
            "Serial", "Computer Name", "OS Version", "Last Check-in")
        print(header.underline)
        
        for device in devices {
            let lastCheckin = device.lastSeenFormatted
            let row = String(format: "%-20s %-30s %-15s %-20s",
                device.serialNumber,
                String(device.displayName.prefix(28)),
                device.osVersion,
                String(lastCheckin.prefix(18)))
            print(row)
        }
        print("")
    }
}

// MARK: - Single Device

struct MunkiDeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Get details for a specific device"
    )
    
    @Argument(help: "Device serial number or hostname")
    var serial: String
    
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        guard let device = try await service.getDevice(serial) else {
            print("Device not found: \(serial)".red)
            throw ExitCode.failure
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(device)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printDeviceDetails(device)
            
            if let munkiInfo = try await service.getMunkiInfo(serial: device.serialNumber) {
                printMunkiInfo(munkiInfo)
            }
        }
    }
    
    private func printDeviceDetails(_ device: MunkiDevice) {
        print("\n" + "Device: \(device.displayName)".bold.green + "\n")
        print("  Serial Number:".lightBlue + "  \(device.serialNumber)")
        print("  Computer Name:".lightBlue + "  \(device.machineName.isEmpty ? device.hostname : device.machineName)")
        print("  OS Version:".lightBlue + "    \(device.osVersion)")
        print("  Machine Model:".lightBlue + " \(device.machineModel)")
        print("  CPU Type:".lightBlue + "      \(device.cpuType)")
        print("  Memory:".lightBlue + "        \(formatBytes(device.physicalMemory))")
        print("  Last Check-in:".lightBlue + " \(device.lastSeenFormatted)")
    }
    
    private func printMunkiInfo(_ info: MunkiInfo) {
        print("\n" + "Munki Information".bold + "\n")
        print("  Munki Version:".lightBlue + "     \(info.version)")
        print("  Manifest:".lightBlue + "          \(info.manifest)")
        print("  Run Type:".lightBlue + "          \(info.runType)")
        print("  Duration:".lightBlue + "          \(info.duration)")
        print("")
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }
}

// MARK: - Munki Info

struct InfoSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Get Munki info for a device"
    )
    
    @Argument(help: "Device serial number")
    var serial: String
    
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        guard let info = try await service.getMunkiInfo(serial: serial) else {
            print("Munki info not found for: \(serial)".red)
            throw ExitCode.failure
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(info)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("\n" + "Munki Info for \(serial)".bold.green + "\n")
            print("  Version:".lightBlue + "      \(info.version)")
            print("  Manifest:".lightBlue + "     \(info.manifest)")
            print("  Manifest URL:".lightBlue + " \(info.manifestUrl)")
            print("  Run Type:".lightBlue + "     \(info.runType)")
            print("  Duration:".lightBlue + "     \(info.duration)")
            print("")
        }
    }
}

// MARK: - Installs

struct InstallsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "installs",
        abstract: "List managed installs for a device"
    )
    
    @Argument(help: "Device serial number")
    var serial: String
    
    @Option(name: .shortAndLong, help: "Filter by package name")
    var filter: String?
    
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        var installs = try await service.getManagedInstalls(serial: serial)
        
        if let filter = filter {
            installs = installs.filter { 
                $0.name.lowercased().contains(filter.lowercased())
            }
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(installs)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Managed Installs for \(serial)".bold + " (\(installs.count) packages)\n")
            
            let header = String(format: "%-35s %-20s %-10s", "Name", "Version", "Status")
            print(header.underline)
            
            for install in installs {
                let status = install.status
                let statusColor: String
                switch status.lowercased() {
                case "installed": statusColor = "✓ installed".green
                case "": statusColor = "-"
                default: statusColor = "✗ \(status)".red
                }
                
                let row = String(format: "%-35s %-20s %-10s",
                    String(install.name.prefix(33)),
                    String((install.installedVersion.isEmpty ? install.version : install.installedVersion).prefix(18)),
                    statusColor)
                print(row)
            }
            print("")
        }
    }
}

// MARK: - Errors

struct MunkiErrorsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "errors",
        abstract: "List install errors across all devices"
    )
    
    @Option(name: .shortAndLong, help: "Maximum number of errors to show")
    var limit: Int = 50
    
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        var errors = try await service.getErrors()
        
        if errors.count > limit {
            errors = Array(errors.prefix(limit))
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(errors)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Install Errors".bold.red + " (\(errors.count) total)\n")
            
            let header = String(format: "%-35s %-25s %-20s", "Package", "Device", "Status")
            print(header.underline)
            
            for error in errors {
                let row = String(format: "%-35s %-25s %-20s",
                    String(error.itemName.prefix(33)),
                    String((error.hostname.isEmpty ? error.serialNumber : error.hostname).prefix(23)),
                    String(error.status.prefix(18)))
                print(row)
            }
            print("")
        }
    }
}

// MARK: - Stale Devices

struct StaleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stale",
        abstract: "List devices that haven't checked in recently"
    )
    
    @Option(name: .shortAndLong, help: "Days since last check-in (default: 7)")
    var days: Int = 7
    
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        let devices = try await service.getDevices()
        let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        
        let staleDevices = devices.filter { device in
            guard let ts = device.timestamp else { return true }
            return ts < cutoffDate
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(staleDevices)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Stale Devices".bold.yellow + " (no check-in for \(days)+ days): \(staleDevices.count)\n")
            
            let header = String(format: "%-20s %-30s %-20s", "Serial", "Computer Name", "Last Check-in")
            print(header.underline)
            
            for device in staleDevices {
                let row = String(format: "%-20s %-30s %-20s",
                    device.serialNumber,
                    String(device.displayName.prefix(28)),
                    device.lastSeenFormatted)
                print(row)
            }
            print("")
        }
    }
}

// MARK: - Raw Query

struct QuerySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Execute a raw SQL query"
    )
    
    @Argument(help: "SQL query to execute")
    var sql: String
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        print("\n" + "Executing Query:".bold + " \(sql)\n")
        
        let result = try await service.rawQuery(sql)
        
        if result.isEmpty {
            print("No results".yellow)
        } else {
            // Print headers
            if let first = result.first {
                let headers = first.keys.sorted()
                print(headers.joined(separator: " | "))
                print(String(repeating: "-", count: headers.joined(separator: " | ").count))
                
                // Print rows
                for row in result {
                    let values = headers.map { row[$0] ?? "" }
                    print(values.joined(separator: " | "))
                }
            }
        }
        print("")
    }
}
