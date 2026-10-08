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
            AutopilotUnassignUserSubcommand.self,
            AutopilotPruneAssignmentsSubcommand.self
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

// MARK: - Prune assignments to deleted groups

struct AutopilotPruneAssignmentsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune-assignments",
        abstract: "Find, and with --confirm remove, Autopilot and ESP assignments to deleted groups",
        discussion: """
        A deployment profile or Enrollment Status Page assigned to a group \
        that no longer exists makes assignment fail for devices that are \
        otherwise grouped correctly. This reads every Autopilot deployment \
        profile and ESP, resolves each target group, and reports the rows \
        whose group is gone. It is a dry run unless --confirm is given.

        A group counts as gone only when two reads, --recheck-delay seconds \
        apart, both return HTTP 404 and the group is not in the directory's \
        deleted items. A soft-deleted group can still be restored, and a \
        throttled or failed read proves nothing, so neither is pruned. \
        --confirm deletes only the assignment rows; it never touches a group.
        """
    )

    @Flag(help: "Delete the assignment rows whose group is confirmed deleted")
    var confirm: Bool = false

    @Option(help: "Seconds to wait before re-reading a group that returned 404")
    var recheckDelay: Double = 10

    @Option(help: "Refuse to delete when more rows than this would go")
    var maxDeletes: Int = 10

    @Flag(name: .shortAndLong, help: "Output the plan as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try autopilotServiceOrExit()
        let plan = try await service.planEnrollmentAssignmentPrune(recheckDelay: max(0, recheckDelay))
        let prunable = plan.prunable

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(plan), encoding: .utf8) ?? "{}")
        } else {
            printPrunePlan(plan)
        }

        guard confirm else {
            if !prunable.isEmpty && !json {
                print("Dry run — nothing was deleted. Re-run with --confirm to remove the \(prunable.count) row(s) above.".cyan)
            }
            return
        }
        guard !prunable.isEmpty else { return }
        guard prunable.count <= maxDeletes else {
            print("Refusing to delete \(prunable.count) rows, more than --max-deletes \(maxDeletes). Check the list, then raise the limit if it is right.".red)
            throw ExitCode.failure
        }

        var failed = 0
        for row in prunable {
            do {
                try await service.deleteEnrollmentAssignment(row)
                print("Removed ".green + "\(row.source.label) \"\(row.configurationName)\" → group \(row.groupId)")
            } catch {
                failed += 1
                print("Failed ".red + "\(row.source.label) \"\(row.configurationName)\" → group \(row.groupId): \(error.localizedDescription)")
            }
        }
        if failed > 0 { throw ExitCode.failure }
    }
}

private func printPrunePlan(_ plan: AssignmentPrunePlan) {
    let goneCount = plan.prunable.count
    let heldCount = plan.held.count
    print("\n" + "Enrollment assignments".bold
        + " — \(plan.rows.count) group-targeted rows, \(plan.verdicts.count) groups\n")
    if goneCount == 0 && heldCount == 0 {
        print("Every target group resolves.".green + "\n")
        return
    }

    let header = "Verdict".col(12) + " " + "Type".col(22) + " " + "Configuration".col(32) + " " + "Group".col(38)
    print(header.underline)
    for row in plan.prunable + plan.held {
        let verdict = plan.verdict(for: row)
        let tag = verdict.isPrunable ? "deleted".col(12).red
            : (verdict == .softDeleted ? "restorable" : "unresolved").col(12).yellow
        let group = row.groupId + (row.isExclusion ? " (exclusion)" : "")
        print(tag + " " + row.source.label.col(22) + " " + row.configurationName.col(32) + " " + group.col(38))
        if case .unresolved(let reason) = verdict { print("             " + reason.dim) }
    }
    print("")
    if heldCount > 0 {
        print("\(heldCount) row(s) are left alone: their group is restorable or could not be confirmed gone.".yellow)
    }
}

/// Autopilot ids are GUIDs; anything else must be a valid serial matching
/// exactly one identity. Duplicates are refused with their ids listed.
private func resolveAutopilotId(_ service: GraphService, _ identifier: String) async throws -> String {
    if let id = try? DeviceIdentifier.validateGuid(identifier) { return id }
    let identities: [WindowsAutopilotDevice]
    do {
        identities = try await service.autopilotDevices(exactSerial: identifier)
    } catch let error as DeviceIdentifierError {
        print(error.message.red)
        throw ExitCode.failure
    }
    switch identities.count {
    case 0:
        print("No Autopilot registration for \(identifier)".red)
        throw ExitCode.failure
    case 1:
        guard let id = identities[0].id else { throw ExitCode.failure }
        print("Target: ".bold + "serial=\(identities[0].serialNumber ?? "-")  Autopilot \(id)  model=\(identities[0].model ?? "-")")
        return id
    default:
        print("\(identities.count) Autopilot identities have serial \(identifier); refusing to choose one. Re-run with the id:".red)
        for ap in identities { print("  \(ap.id ?? "-")  enrollmentState=\(ap.enrollmentState ?? "-")") }
        throw ExitCode.failure
    }
}
