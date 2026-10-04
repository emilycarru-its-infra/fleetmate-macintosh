import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// `fleetmate reportmate` — the same fleet reporting verbs as the Windows CLI.
struct ReportMateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reportmate",
        abstract: "ReportMate fleet reporting commands",
        subcommands: [
            ReportMateDevicesSubcommand.self,
            ReportMateDeviceSubcommand.self,
            ReportMateInstallsSubcommand.self,
            ReportMateErrorsSubcommand.self,
            ReportMateNetworkSubcommand.self,
        ]
    )
}

private func reportMateServiceOrExit() throws -> ReportMateService {
    let service = ReportMateService(config: try FleetMateConfig.load())
    guard service.isConfigured else {
        print("ReportMate is not configured. Run fleetmate configure.".red)
        throw ExitCode.failure
    }
    return service
}

private func day(_ date: Date?) -> String {
    guard let date else { return "-" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

private func minute(_ date: Date?) -> String {
    guard let date else { return "-" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

private func dash(_ s: String) -> String { s.isEmpty ? "-" : s }

struct ReportMateDevicesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "List all fleet devices from ReportMate")

    func run() async throws {
        let devices = try await reportMateServiceOrExit().getDevices()
        guard !devices.isEmpty else { print("No devices found.".yellow); return }
        print("Fleet Devices (\(devices.count))".cyan)
        print("Serial".col(16) + "Hostname".col(26) + "Model".col(28) + "OS Version".col(14) + "Last Check-In")
        for d in devices.sorted(by: { $0.hostname.lowercased() < $1.hostname.lowercased() }) {
            print(dash(d.serialNumber).col(16) + dash(d.hostname).col(26) + dash(d.model).col(28) + dash(d.osVersion).col(14) + minute(d.lastSeen))
        }
    }
}

struct ReportMateDeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "device", abstract: "Get full details for a specific device")

    @Argument(help: "Serial number, hostname, or search term")
    var query: String

    func run() async throws {
        let service = try reportMateServiceOrExit()
        guard let device = try await service.findDevice(query) else {
            print("Device not found.".red)
            throw ExitCode.failure
        }
        print(dash(device.hostname.isEmpty ? device.serialNumber : device.hostname).cyan)
        print("Serial".col(14) + dash(device.serialNumber))
        print("Hostname".col(14) + dash(device.hostname))
        print("Model".col(14) + dash(device.model))
        print("OS Version".col(14) + dash(device.osVersion))
        print("Last Seen".col(14) + minute(device.lastSeen))

        if let full = try? await service.getFullDevice(device.serialNumber) {
            print("\n" + "IP Address: ".bold + (full.network?.primaryIpv4 ?? "-"))
        }

        let installs = (try? await service.getDeviceInstalls(device.serialNumber)) ?? []
        if !installs.isEmpty {
            print("\n" + "Installs (\(installs.count))".cyan)
            print("Name".col(34) + "Version".col(18) + "Status".col(14) + "Date")
            for i in installs.prefix(50) {
                print(dash(i.itemName).col(34) + dash(i.installedVersion).col(18) + dash(i.currentStatus).col(14) + day(i.installDate))
            }
        }
    }
}

struct ReportMateInstallsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "installs", abstract: "List recent installs across the fleet")

    func run() async throws {
        let installs = try await reportMateServiceOrExit().getInstalls()
        guard !installs.isEmpty else { print("No install records found.".yellow); return }
        print("Recent Installs (\(installs.count))".cyan)
        print("Name".col(34) + "Version".col(18) + "Status".col(14) + "Device".col(16) + "Date")
        for i in installs.prefix(100) {
            print(dash(i.itemName).col(34) + dash(i.installedVersion).col(18) + dash(i.currentStatus).col(14) + dash(i.serialNumber).col(16) + day(i.installDate))
        }
    }
}

struct ReportMateErrorsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "errors", abstract: "Show fleet installation errors")

    @Flag(help: "Group errors by device") var byDevice: Bool = false
    @Flag(help: "Group errors by item name") var byItem: Bool = false

    func run() async throws {
        let service = try reportMateServiceOrExit()
        if byDevice {
            let errors = try await service.getErrorsByDevice()
            print("Errors by Device (\(errors.count))".cyan)
            print("Serial".col(16) + "Hostname".col(26) + "Error Count")
            for e in errors.sorted(by: { $0.errorCount > $1.errorCount }) {
                print(dash(e.serialNumber).col(16) + dash(e.deviceName).col(26) + "\(e.errorCount)")
            }
        } else if byItem {
            let errors = try await service.getErrorsByItem()
            print("Errors by Item (\(errors.count))".cyan)
            print("Name".col(40) + "Error Count")
            for e in errors.sorted(by: { $0.deviceCount > $1.deviceCount }) {
                print(dash(e.itemName).col(40) + "\(e.deviceCount)")
            }
        } else {
            let errors = try await service.getErrors()
            print("Installation Errors (\(errors.count))".cyan)
            print("Name".col(34) + "Version".col(18) + "Device".col(16) + "Date")
            for e in errors.prefix(100) {
                print(dash(e.itemName).col(34) + dash(e.installedVersion).col(18) + dash(e.serialNumber).col(16) + day(e.installDate))
            }
        }
    }
}

struct ReportMateNetworkSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "network", abstract: "Show fleet or device network information")

    @Argument(help: "Serial number (omit for fleet overview)")
    var serial: String?

    func run() async throws {
        let service = try reportMateServiceOrExit()
        if let serial {
            guard let info = try await service.getDeviceNetwork(serial) else {
                print("No network info for \(serial).".red)
                throw ExitCode.failure
            }
            print("Network: \(serial)".cyan)
            print("IP Address".col(16) + (info.primaryIpv4 ?? "-"))
            print("MAC Address".col(16) + (info.activeMac ?? "-"))
        } else {
            let fleet = try await service.getFleetNetwork()
            print("Fleet Network (\(fleet.count))".cyan)
            print("Serial".col(16) + "Device".col(26) + "IP Address")
            for d in fleet {
                print(dash(d.serialNumber).col(16) + dash(d.deviceName).col(26) + dash(d.primaryIp))
            }
        }
    }
}
