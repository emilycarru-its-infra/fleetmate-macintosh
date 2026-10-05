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
            IntuneLAPSSubcommand.self,
            ComplianceSubcommand.self,
            NonCompliantSubcommand.self,
            IntuneWipeSubcommand.self,
            IntuneRetireSubcommand.self,
            IntuneFreshStartSubcommand.self,
            IntuneDeleteRecordSubcommand.self,
            IntuneDeleteSubcommand.self,
            IntuneAutopilotResetSubcommand.self,
            IntuneAutopilotRecordsSubcommand.self,
            IntuneCleanupSubcommand.self,
            IntuneSyncSubcommand.self,
            IntuneRebootSubcommand.self,
            IntuneLockSubcommand.self,
            IntuneOffboardSubcommand.self,
            IntuneCimianPushSubcommand.self,
            IntuneSettingsSubcommand.self,
            IntuneUpdatesSubcommand.self
        ],
        defaultSubcommand: IntuneDevicesSubcommand.self
    )
}

// MARK: - macOS Local Administrator Password

struct IntuneLAPSSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "laps",
        abstract: "Retrieve the Intune-managed local administrator password for a Mac"
    )

    @Argument(help: "Mac serial number")
    var serialNumber: String

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        do {
            let credential = try await service.getMacOSLocalAdminCredential(
                serialNumber: serialNumber
            )
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(credential)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            print("\n" + "macOS local administrator credential".bold + "\n")
            print("  Serial:".lightBlue + "        \(serialNumber)")
            print("  Password:".lightBlue + "      \(credential.adminAccountPassword)")
            print("  Last rotated:".lightBlue + "  \(credential.passwordLastRotatedDateTime ?? "-")")
            print("")
        } catch {
            print("Unable to retrieve the macOS local administrator password: \(error)".red)
            throw ExitCode.failure
        }
    }
}

// MARK: - Settings Catalog

struct IntuneSettingsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Search the Intune Settings Catalog for a setting definition id"
    )

    @Argument(help: "Words to match against setting id, name, description and keywords")
    var query: String?

    @Option(name: .shortAndLong, help: "Applicability platform: windows10, macOS, iOS, android")
    var platform: String?

    @Option(name: .shortAndLong, help: "Maximum matches to show")
    var limit: Int = 25

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let settings = try await service.searchSettingsCatalog(
            query: query, platform: platform, limit: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        guard !settings.isEmpty else {
            print("No matching settings.".yellow)
            // The most common reason to run this is holding an id Graph already
            // rejected. Nothing found is then the answer, not a failure.
            print("If you searched for a setting id, no definition by that name exists - which is what".lightBlack)
            print("\"Setting Id is not found in the Settings Catalog\" means. Try a word from the name instead.".lightBlack)
            return
        }

        print("")
        for setting in settings {
            print(setting.id.green)
            print("  name:".lightBlue + "     \(setting.displayName ?? "-")")
            print("  kind:".lightBlue + "     \(setting.kind)")
            if let platform = setting.applicability?.platform {
                print("  platform:".lightBlue + " \(platform)")
            }
            if let description = setting.description, !description.isEmpty {
                let trimmed = description.count > 160
                    ? String(description.prefix(160)) + "..."
                    : description
                print("  about:".lightBlue + "    \(trimmed)")
            }
            print("")
        }

        print("\(settings.count) match(es). Use the id above verbatim as a profile's definitionId.".lightBlack)
    }
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

    /// Fixed-width column. Delegates to the shared `String.col` formatter.
    private func pad(_ value: String, _ width: Int) -> String { value.col(width) }

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

// MARK: - Windows build inventory

struct IntuneUpdatesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "updates",
        abstract: "Summarize observed Windows OS builds across Intune devices"
    )

    @Option(name: .long, help: "Only include devices synced on or after this UTC date/time (default: 7 days ago)")
    var since: String?

    @Option(name: [.customShort("b"), .long], parsing: .upToNextOption, help: "Builds to measure, such as 26100.9457 (repeatable)")
    var build: [String] = []

    @Flag(name: .long, help: "List devices on the selected builds (all builds when --build is omitted)")
    var list = false

    @Option(name: [.customShort("n"), .long], help: "Maximum Intune devices to read")
    var limit = 5000

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    func run() async throws {
        let cutoff: Date
        if let since {
            guard let parsed = Self.parseSince(since) else {
                print("Invalid --since value: ".red + since)
                throw ExitCode(2)
            }
            cutoff = parsed
        } else {
            cutoff = Date().addingTimeInterval(-7 * 86_400)
        }

        let service = GraphService(config: try FleetMateConfig.load())
        guard service.isConfigured else {
            print("Microsoft Graph not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID.".red)
            throw ExitCode.failure
        }

        let devices = try await service.getManagedDevices(filter: ODataFilter.equals("operatingSystem", "Windows"), limit: limit)
        let inventory = WindowsUpdateInventory.build(from: devices, since: cutoff, selectedBuilds: build)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(inventory), encoding: .utf8) ?? "{}")
            return
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        stamp.timeZone = TimeZone(identifier: "UTC")

        print("\n\(inventory.totalDevices)".bold + " Windows devices synced since " + "\(stamp.string(from: inventory.since)) UTC".cyan)
        if !inventory.selectedBuilds.isEmpty {
            print("\(inventory.matchingDevices)".green + " of " + "\(inventory.totalDevices)".bold
                  + " (" + String(format: "%.1f%%", inventory.coveragePercentage).bold + ") report "
                  + inventory.selectedBuilds.joined(separator: ", "))
        }
        print("")
        print(("Observed build".col(20) + " " + "Devices".col(8) + " " + "Fleet".col(8)).underline)
        for row in inventory.builds {
            print(row.build.col(20) + " " + row.count.col(8) + " " + String(format: "%.1f%%", row.percentage).col(8))
        }

        guard list else { print(""); return }
        print("")
        print(("Device".col(28) + " " + "Serial".col(16) + " " + "Build".col(14) + " " + "Last sync (UTC)".col(17)).underline)
        for device in inventory.devices {
            print(device.deviceName.col(28) + " " + (device.serialNumber ?? "-").col(16) + " "
                  + device.build.col(14) + " " + stamp.string(from: device.lastSyncDateTime).col(17))
        }
        print("")
    }

    /// A date (`2026-10-01`, read as UTC midnight) or a full ISO 8601 time.
    static func parseSince(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            day.dateFormat = format
            if let d = day.date(from: raw) { return d }
        }
        return nil
    }
}
