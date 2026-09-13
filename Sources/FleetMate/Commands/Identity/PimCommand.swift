import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// PIM — the `security` elevation domain, on the command line.
///
/// Unlike the other five domains this runs as the signed-in operator rather than a
/// managed identity, because a role activation is a statement about a user and a
/// service principal cannot make it on their behalf. See `PimService`.
struct PimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pim",
        abstract: "Privileged Identity Management - activate an eligible directory role",
        subcommands: [
            PimListSubcommand.self,
            PimActivateSubcommand.self,
            PimDeactivateSubcommand.self
        ],
        defaultSubcommand: PimListSubcommand.self
    )
}

// MARK: - list

struct PimListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show the directory roles you are eligible to activate, and which are active"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let pim = PimService()
        let eligible = try await pim.eligibleRoles()
        let active = try await pim.activeRoles()

        if json {
            struct Payload: Encodable { let eligible: [PimRole]; let active: [PimRole] }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(Payload(eligible: eligible, active: active))
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        if eligible.isEmpty && active.isEmpty {
            // Not an error. An operator who just hit a missing-role failure needs to
            // be told plainly that they hold no eligibility, rather than shown an
            // empty table they might read as a glitch.
            print("You hold no PIM eligibilities and no active directory roles.".yellow)
            print("Ask an administrator to grant eligibility for the role you need.".dim)
            return
        }

        let activeIds = Set(active.map(\.roleDefinitionId))
        print("ROLE".bold.padding(toLength: 44, withPad: " ", startingAt: 0)
            + "STATE".bold.padding(toLength: 22, withPad: " ", startingAt: 0)
            + "EXPIRES".bold)

        for role in eligible.sorted(by: { $0.displayName < $1.displayName }) {
            let isActive = activeIds.contains(role.roleDefinitionId)
            let expiry = isActive
                ? (active.first { $0.roleDefinitionId == role.roleDefinitionId }?.endDateTime ?? "-")
                : "-"
            let state = isActive ? "active".green : "eligible".dim
            print(role.displayName.padding(toLength: 44, withPad: " ", startingAt: 0)
                + state.padding(toLength: 22, withPad: " ", startingAt: 0)
                + expiry)
        }

        // Standing assignments are not eligibilities, but an operator wondering why
        // a call still fails needs to see them too.
        for role in active where !eligible.contains(where: { $0.roleDefinitionId == role.roleDefinitionId }) {
            print(role.displayName.padding(toLength: 44, withPad: " ", startingAt: 0)
                + "active (standing)".green.padding(toLength: 22, withPad: " ", startingAt: 0)
                + (role.endDateTime ?? "-"))
        }
    }
}

// MARK: - activate

struct PimActivateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate",
        abstract: "Activate one of your eligible directory roles"
    )

    @Argument(help: "Role display name, e.g. \"Cloud Device Administrator\"")
    var role: String

    @Option(name: [.customShort("r"), .long], help: "Justification recorded in the tenant audit log (required)")
    var reason: String

    @Option(help: "Activation duration in hours")
    var hours: Int = 8

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let pim = PimService()
        let result = try await pim.activate(role: role, justification: reason, durationHours: hours)

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try enc.encode(result), encoding: .utf8) ?? "{}")
        } else if result.status.caseInsensitiveCompare("AlreadyActive") == .orderedSame {
            let until = result.endDateTime.map { " until \($0)" } ?? ""
            print("\(result.roleName.green) is already active\(until).")
        } else if result.isActive {
            print("\("Activated".green) \(result.roleName) for \(hours)h.")
        } else {
            // Approval-gated tenants return a pending request. Calling that success
            // would send the operator straight back into a refusal.
            print("\(result.roleName): \(result.status)".yellow)
            print("Not active yet — the tenant requires approval for this role.".dim)
        }

        // Exit code follows reality, so scripts gating on activation do not proceed
        // against a request that is merely pending.
        if !result.isActive { throw ExitCode(2) }
    }
}

// MARK: - deactivate

struct PimDeactivateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deactivate",
        abstract: "Give an active role back early"
    )

    @Argument(help: "Role display name")
    var role: String

    func run() async throws {
        let name = try await PimService().deactivate(role: role)
        print("\("Deactivated".green) \(name).")
    }
}
