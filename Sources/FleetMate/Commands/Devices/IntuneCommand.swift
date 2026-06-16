import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct IntuneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "intune",
        abstract: "Query Intune managed devices",
        subcommands: [
            IntuneDevicesSubcommand.self,
            IntuneDeviceSubcommand.self,
            ComplianceSubcommand.self,
            NonCompliantSubcommand.self,
            IntuneWipeSubcommand.self,
            IntuneRetireSubcommand.self,
            IntuneCimianPushSubcommand.self
        ],
        defaultSubcommand: IntuneDevicesSubcommand.self
    )
}

// MARK: - List Devices

struct IntuneDevicesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List managed devices from Intune"
    )

    @Option(name: .shortAndLong, help: "Filter expression (OData)")
    var filter: String?

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID.".red)
            throw ExitCode.failure
        }

        let devices = try await service.getManagedDevices(filter: filter, limit: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(devices)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printDevicesTable(devices)
        }
    }

    /// Truncate-and-pad to a fixed column width. (Avoids `String(format: "%s")`,
    /// which treats a Swift String as a C `char*` and crashes in `strlen`.)
    private func pad(_ value: String, _ width: Int) -> String {
        let truncated = value.count > width ? String(value.prefix(width)) : value
        return truncated + String(repeating: " ", count: max(0, width - truncated.count))
    }

    private func printDevicesTable(_ devices: [IntuneDevice]) {
        print("\n" + "Intune Managed Devices".bold + " (\(devices.count) shown)\n")

        let header = pad("Serial", 15) + " " + pad("Name", 20) + " " + pad("Compliance", 12) + " " + pad("OS", 15) + " " + pad("User", 20)
        print(header.underline)

        for device in devices {
            let complianceState = device.complianceState ?? "Unknown"
            // Pad the plain text first, then color the cell — ANSI codes are
            // zero-width on screen so columns stay aligned.
            let compCell = pad(complianceState, 12)
            let complianceColored: String
            switch complianceState.lowercased() {
            case "compliant": complianceColored = compCell.green
            case "noncompliant": complianceColored = compCell.red
            case "ingraceperiod": complianceColored = compCell.yellow
            default: complianceColored = compCell.lightBlack
            }

            let row = pad(device.serialNumber ?? "-", 15) + " "
                + pad(device.deviceName ?? "-", 20) + " "
                + complianceColored + " "
                + pad(device.operatingSystem ?? "-", 15) + " "
                + pad(device.userDisplayName ?? device.userPrincipalName ?? "-", 20)
            print(row)
        }
        print("")
    }
}

// MARK: - Single Device

struct IntuneDeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Get details for a specific device"
    )

    @Argument(help: "Serial number or device name")
    var identifier: String

    @Flag(name: .shortAndLong, help: "Search by name instead of serial")
    var name: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let device: IntuneDevice?
        if name {
            device = try await service.getDeviceByName(identifier)
        } else {
            device = try await service.getDeviceBySerial(identifier)
        }

        guard let device = device else {
            print("Device not found: \(identifier)".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(device)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printDeviceDetails(device)
        }
    }

    private func printDeviceDetails(_ device: IntuneDevice) {
        print("\n" + "Device: \(device.deviceName ?? "Unknown")".bold.green + "\n")
        print("  Serial:".lightBlue + "         \(device.serialNumber ?? "-")")
        print("  Name:".lightBlue + "           \(device.deviceName ?? "-")")
        print("  Model:".lightBlue + "          \(device.model ?? "-")")
        print("  Manufacturer:".lightBlue + "   \(device.manufacturer ?? "-")")
        print("  OS:".lightBlue + "             \(device.operatingSystem ?? "-") \(device.osVersion ?? "")")
        print("  Compliance:".lightBlue + "     \(device.complianceState ?? "-")")
        print("  Management:".lightBlue + "     \(device.managementState ?? "-")")
        print("  User:".lightBlue + "           \(device.userDisplayName ?? device.userPrincipalName ?? "-")")
        print("  Enrolled:".lightBlue + "       \(device.enrolledDateTime ?? "-")")
        print("  Last Sync:".lightBlue + "      \(device.lastSyncDateTime ?? "-")")

        if let total = device.totalStorageSpaceInBytes, let free = device.freeStorageSpaceInBytes {
            let totalGB = Double(total) / 1_073_741_824
            let freeGB = Double(free) / 1_073_741_824
            print("  Storage:".lightBlue + "        \(String(format: "%.1f", freeGB)) GB free of \(String(format: "%.1f", totalGB)) GB")
        }
        print("")
    }
}

// MARK: - Compliance

struct ComplianceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compliance",
        abstract: "Get compliance policy states for a device"
    )

    @Argument(help: "Device ID (from Intune)")
    var deviceId: String

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let states = try await service.getDeviceCompliance(deviceId: deviceId)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(states)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Compliance Policy States".bold + " (\(states.count) policies)\n")

            for state in states {
                let stateStr = state.state ?? "Unknown"
                let stateColor: String
                switch stateStr.lowercased() {
                case "compliant": stateColor = stateStr.green
                case "noncompliant": stateColor = stateStr.red
                default: stateColor = stateStr.yellow
                }

                print("[\(stateColor)] ".bold + (state.displayName ?? "Unknown Policy"))
                print("    Platform: \(state.platformType ?? "-")")
            }
            print("")
        }
    }
}

// MARK: - Non-Compliant

struct NonCompliantSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "noncompliant",
        abstract: "List non-compliant devices"
    )

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let devices = try await service.getNonCompliantDevices(limit: limit)

        if devices.isEmpty {
            print("\n" + "No non-compliant devices found!".green + "\n")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(devices)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Non-Compliant Devices".bold.red + " (\(devices.count) found)\n")

            for device in devices {
                print("[\(device.serialNumber ?? "-")]".cyan + " " + (device.deviceName ?? "Unnamed").bold)
                print("  User: \(device.userDisplayName ?? device.userPrincipalName ?? "-")")
                print("  Last Sync: \(device.lastSyncDateTime ?? "-")")
                print("")
            }
        }
    }
}
