import ArgumentParser
import Foundation
import Rainbow

struct MunkiReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "munkireport",
        abstract: "Query MunkiReport database via SSH",
        subcommands: [
            DevicesSubcommand.self,
            DeviceSubcommand.self,
            InfoSubcommand.self,
            InstallsSubcommand.self,
            ErrorsSubcommand.self,
            StaleSubcommand.self,
            QuerySubcommand.self
        ],
        defaultSubcommand: DevicesSubcommand.self
    )
}

// MARK: - Devices List

struct DevicesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List all devices in MunkiReport"
    )
    
    @Option(name: .shortAndLong, help: "Filter by machine type (Laptop, Desktop)")
    var type: String?
    
    @Option(name: .shortAndLong, help: "Maximum number of results")
    var limit: Int = 100
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        var devices = try await service.getDevices()
        
        if let type = type {
            devices = devices.filter { $0.machineModel?.lowercased().contains(type.lowercased()) ?? false }
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
            let lastCheckin = device.timestamp ?? "Never"
            let row = String(format: "%-20s %-30s %-15s %-20s",
                device.serialNumber ?? "Unknown",
                String((device.computerName ?? "Unknown").prefix(28)),
                device.osVersion ?? "Unknown",
                String(lastCheckin.prefix(18)))
            print(row)
        }
        print("")
    }
}

// MARK: - Single Device

struct DeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Get details for a specific device"
    )
    
    @Argument(help: "Serial number of the device")
    var serial: String
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        guard let device = try await service.getDevice(serial: serial) else {
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
            
            // Also fetch munki info
            if let munkiInfo = try await service.getMunkiInfo(serial: serial) {
                printMunkiInfo(munkiInfo)
            }
        }
    }
    
    private func printDeviceDetails(_ device: MunkiDevice) {
        print("\n" + "Device: \(device.computerName ?? device.serialNumber ?? "Unknown")".bold.green + "\n")
        print("  Serial Number:".lightBlue + "  \(device.serialNumber ?? "Unknown")")
        print("  Computer Name:".lightBlue + "  \(device.computerName ?? "Unknown")")
        print("  OS Version:".lightBlue + "    \(device.osVersion ?? "Unknown")")
        print("  Machine Model:".lightBlue + " \(device.machineModel ?? "Unknown")")
        print("  CPU Type:".lightBlue + "      \(device.cpuType ?? "Unknown")")
        print("  Memory:".lightBlue + "        \(device.physicalMemory ?? "Unknown")")
        print("  Last Check-in:".lightBlue + " \(device.timestamp ?? "Never")")
    }
    
    private func printMunkiInfo(_ info: MunkiInfo) {
        print("\n" + "Munki Information".bold + "\n")
        print("  Munki Version:".lightBlue + "     \(info.munkiVersion ?? "Unknown")")
        print("  Manifest:".lightBlue + "          \(info.manifest ?? "Unknown")")
        print("  Start Time:".lightBlue + "        \(info.startTime ?? "Unknown")")
        print("  End Time:".lightBlue + "          \(info.endTime ?? "Unknown")")
        print("  Errors:".lightBlue + "            \(info.errors ?? 0)")
        print("  Warnings:".lightBlue + "          \(info.warnings ?? 0)")
        print("")
    }
}

// MARK: - Munki Info

struct InfoSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Get Munki run information for a device"
    )
    
    @Argument(help: "Serial number of the device")
    var serial: String
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        guard let info = try await service.getMunkiInfo(serial: serial) else {
            print("No Munki info found for: \(serial)".red)
            throw ExitCode.failure
        }
        
        print("\n" + "Munki Info for \(serial)".bold.green + "\n")
        print("  Version:".lightBlue + "      \(info.munkiVersion ?? "Unknown")")
        print("  Manifest:".lightBlue + "     \(info.manifest ?? "Unknown")")
        print("  Last Run:".lightBlue + "     \(info.startTime ?? "Unknown") - \(info.endTime ?? "Unknown")")
        print("  Errors:".lightBlue + "       \(info.errors ?? 0)")
        print("  Warnings:".lightBlue + "     \(info.warnings ?? 0)")
        print("  Pending:".lightBlue + "      Installs: \(info.pendingInstalls ?? 0), Removals: \(info.pendingRemovals ?? 0)")
        print("  Apple Updates:".lightBlue + " \(info.appleUpdates ?? 0)")
        print("")
    }
}

// MARK: - Managed Installs

struct InstallsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "installs",
        abstract: "List managed installs for a device"
    )
    
    @Argument(help: "Serial number of the device")
    var serial: String
    
    @Option(name: .shortAndLong, help: "Filter by package name")
    var filter: String?
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        var installs = try await service.getManagedInstalls(serial: serial)
        
        if let filter = filter {
            installs = installs.filter { 
                $0.name?.lowercased().contains(filter.lowercased()) ?? false 
            }
        }
        
        print("\n" + "Managed Installs for \(serial)".bold + " (\(installs.count) packages)\n")
        
        let header = String(format: "%-35s %-20s %-10s",
            "Name", "Version", "Status")
        print(header.underline)
        
        for install in installs {
            let status = install.status ?? "unknown"
            let statusColor: String
            switch status.lowercased() {
            case "installed": statusColor = status.green
            case "pending": statusColor = status.yellow
            case "error": statusColor = status.red
            default: statusColor = status
            }
            
            let row = String(format: "%-35s %-20s %-10s",
                String((install.name ?? "Unknown").prefix(33)),
                String((install.installedVersion ?? install.version ?? "Unknown").prefix(18)),
                statusColor)
            print(row)
        }
        print("")
    }
}

// MARK: - Errors

struct ErrorsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "errors",
        abstract: "List install errors across fleet or for a device"
    )
    
    @Option(name: .shortAndLong, help: "Serial number to filter by")
    var serial: String?
    
    @Option(name: .shortAndLong, help: "Maximum number of results")
    var limit: Int = 50
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        var errors = try await service.getErrors(serial: serial)
        
        if errors.count > limit {
            errors = Array(errors.prefix(limit))
        }
        
        if errors.isEmpty {
            print("\n" + "No errors found!".green + "\n")
            return
        }
        
        print("\n" + "Install Errors".bold.red + " (\(errors.count) total)\n")
        
        for error in errors {
            print("[\(error.serialNumber ?? "Unknown")]".lightBlue + " " + (error.name ?? "Unknown").bold)
            print("  Version: \(error.version ?? "Unknown")")
            print("  Error: \(error.errorMessage ?? "No message")")
            print("  Time: \(error.timestamp ?? "Unknown")")
            print("")
        }
    }
}

// MARK: - Stale Devices

struct StaleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stale",
        abstract: "Find devices that haven't checked in recently"
    )
    
    @Option(name: .shortAndLong, help: "Days since last check-in (default: 7)")
    var days: Int = 7
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        let devices = try await service.getStaleDevices(days: days)
        
        if devices.isEmpty {
            print("\n" + "No stale devices found!".green + " (all checked in within \(days) days)\n")
            return
        }
        
        print("\n" + "Stale Devices".bold.yellow + " (not seen in \(days)+ days, \(devices.count) total)\n")
        
        let header = String(format: "%-20s %-30s %-20s",
            "Serial", "Computer Name", "Last Check-in")
        print(header.underline)
        
        for device in devices {
            let row = String(format: "%-20s %-30s %-20s",
                device.serialNumber ?? "Unknown",
                String((device.computerName ?? "Unknown").prefix(28)),
                device.timestamp ?? "Never")
            print(row)
        }
        print("")
    }
}

// MARK: - Raw Query

struct QuerySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Execute a raw SQL query against MunkiReport database"
    )
    
    @Argument(help: "SQL query to execute")
    var sql: String
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = MunkiReportService(config: config)
        
        print("\n" + "Executing Query:".bold + " \(sql)\n")
        
        let result = try await service.rawQuery(sql)
        print(result)
    }
}
