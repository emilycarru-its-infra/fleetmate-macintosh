import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct AutopilotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot",
        abstract: "Windows Autopilot device registrations",
        discussion: """
        Autopilot registrations are the hardware-hash records that survive a \
        wipe. A device stays claimed by this tenant until its registration is \
        deleted, so decommissioning hardware means clearing this alongside the \
        Intune and Entra records.
        """,
        subcommands: [
            AutopilotListSubcommand.self,
            AutopilotGetSubcommand.self,
            AutopilotDeleteSubcommand.self,
            AutopilotAssignUserSubcommand.self,
            AutopilotUnassignUserSubcommand.self
        ],
        defaultSubcommand: AutopilotListSubcommand.self
    )
}

private func autopilotServiceOrExit() throws -> GraphService {
    let config = try FleetMateConfig.load()
    let service = GraphService(config: config)
    guard service.isConfigured else {
        print("Microsoft Graph not configured.".red)
        throw ExitCode.failure
    }
    return service
}

private func printAutopilotTable(_ devices: [WindowsAutopilotDevice]) {
    print("\n" + "Windows Autopilot Registrations".bold + " (\(devices.count) shown)\n")

    let header = "Serial".col(18) + " " + "Model".col(24) + " " + "Enrollment".col(14) + " "
        + "Profile".col(20) + " " + "User".col(24)
    print(header.underline)

    for device in devices {
        let row = (device.serialNumber ?? "-").col(18) + " "
            + (device.model ?? "-").col(24) + " "
            + (device.enrollmentState ?? "-").col(14) + " "
            + (device.deploymentProfileAssignmentStatus ?? "-").col(20) + " "
            + (device.userPrincipalName ?? "-").col(24)
        print(row)
    }
    print("")
}

// MARK: - List

struct AutopilotListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Autopilot device registrations"
    )

    @Option(name: .shortAndLong, help: "Filter expression (OData)")
    var filter: String?

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try autopilotServiceOrExit()
        let devices = try await service.getAutopilotDevices(filter: filter, limit: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(devices), encoding: .utf8) ?? "[]")
        } else {
            printAutopilotTable(devices)
        }
    }
}

// MARK: - Get

struct AutopilotGetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show the Autopilot registration for a serial number"
    )

    @Argument(help: "Serial number")
    var serial: String

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try autopilotServiceOrExit()
        guard let device = try await service.getAutopilotDeviceBySerial(serial) else {
            print("No Autopilot registration for \(serial)".yellow)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(device), encoding: .utf8) ?? "{}")
            return
        }

        print("\n" + (device.displayName ?? device.serialNumber ?? serial).bold)
        print("  Serial:      \(device.serialNumber ?? "-")")
        print("  Model:       \(device.manufacturer ?? "-") \(device.model ?? "")")
        print("  Enrollment:  \(device.enrollmentState ?? "-")")
        print("  Profile:     \(device.deploymentProfileAssignmentStatus ?? "-")")
        print("  Assigned to: \(device.userPrincipalName ?? "-")")
        print("  Entra id:    \(device.azureActiveDirectoryDeviceId ?? "-")")
        print("  Intune id:   \(device.managedDeviceId ?? "-")")
        print("  Last seen:   \(device.lastContactedDateTime ?? "-")\n")
    }
}

// MARK: - Delete

struct AutopilotDeleteSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an Autopilot registration, releasing the hardware hash"
    )

    @Argument(help: "Serial number or Autopilot device id")
    var identifier: String

    @Flag(help: "Resolve the registration and print the request without sending it")
    var dryRun: Bool = false

    @Flag(help: "Required to actually delete the registration")
    var confirm: Bool = false

    func run() async throws {
        guard dryRun || confirm else {
            print("This will release the Autopilot registration for \(identifier). Re-run with --confirm to proceed, or --dry-run to see what would be sent.".yellow)
            throw ExitCode.failure
        }
        let service = try autopilotServiceOrExit()
        let autopilotId = try await resolveAutopilotId(service, identifier)

        if dryRun {
            print("\n" + "Dry run".bold + " — Autopilot \(identifier)")
            print("  DELETE windowsAutopilotDeviceIdentities/\(autopilotId)")
            print("\nDry run — nothing was sent.".cyan)
            return
        }

        let results = try await service.deleteAutopilotDevices([autopilotId])

        guard let result = results.first else {
            print("delete: no registration acted on (not authenticated?)".red)
            throw ExitCode.failure
        }
        guard result.success else {
            print("delete failed: \(result.error ?? "unknown error")".red)
            throw ExitCode.failure
        }
        print("Deleted Autopilot registration \(autopilotId)".green)
    }
}

// MARK: - Assign / unassign user

struct AutopilotAssignUserSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assign-user",
        abstract: "Assign a user to an Autopilot device for the out-of-box experience"
    )

    @Argument(help: "Serial number or Autopilot device id")
    var identifier: String

    @Argument(help: "User principal name to assign")
    var userPrincipalName: String

    @Option(help: "Friendly name shown during setup")
    var displayName: String?

    func run() async throws {
        let service = try autopilotServiceOrExit()
        let autopilotId = try await resolveAutopilotId(service, identifier)
        try await service.assignAutopilotUser(
            autopilotId: autopilotId,
            userPrincipalName: userPrincipalName,
            addressableUserName: displayName
        )
        print("Assigned \(userPrincipalName) to \(identifier)".green)
    }
}

struct AutopilotUnassignUserSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unassign-user",
        abstract: "Remove the assigned user from an Autopilot device"
    )

    @Argument(help: "Serial number or Autopilot device id")
    var identifier: String

    func run() async throws {
        let service = try autopilotServiceOrExit()
        let autopilotId = try await resolveAutopilotId(service, identifier)
        try await service.unassignAutopilotUser(autopilotId: autopilotId)
        print("Removed the assigned user from \(identifier)".green)
    }
}

/// Autopilot ids are GUIDs; anything else is treated as a serial and looked up.
private func resolveAutopilotId(_ service: GraphService, _ identifier: String) async throws -> String {
    if UUID(uuidString: identifier) != nil { return identifier }
    guard let device = try await service.getAutopilotDeviceBySerial(identifier), let id = device.id else {
        print("No Autopilot registration for \(identifier)".red)
        throw ExitCode.failure
    }
    return id
}
