import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

// MARK: - entra device

struct EntraDeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Get Entra device object(s) by name, deviceId or object id"
    )

    @Argument(help: "Display name, deviceId or object id")
    var query: String

    @Flag(help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try lifecycleGraphService()
        let devices = try await service.findEntraDevices(query)

        if json {
            try printLifecycleJSON(devices)
            return
        }
        guard !devices.isEmpty else {
            print("No Entra device object found: \(query)".yellow)
            return
        }

        print("Name".col(28) + "Object id".col(38) + "Trust".col(10) + "Managed".col(9) + "Compliant".col(11) + "Last sign-in")
        for d in devices {
            print((d.displayName ?? "-").col(28)
                  + (d.id ?? "-").col(38)
                  + (d.trustType ?? "-").col(10)
                  + (d.isManaged == true ? "yes" : "no").col(9)
                  + (d.isCompliant == true ? "yes" : "no").col(11)
                  + String((d.approximateLastSignInDateTime ?? "-").prefix(10)))
        }
    }
}

// MARK: - entra delete-device

struct EntraDeleteDeviceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-device",
        abstract: "Delete an Entra device object (DESTRUCTIVE)"
    )

    @Argument(help: "Display name, deviceId or object id")
    var query: String

    @Flag(help: "Required to actually delete")
    var confirm: Bool = false

    @Flag(help: "Delete every object matching the query, not just a unique match")
    var all: Bool = false

    func run() async throws {
        let service = try lifecycleGraphService()
        let devices = try await service.findEntraDevices(query)

        guard !devices.isEmpty else {
            print("No Entra device object found: \(query)".yellow)
            return
        }

        // Refuse to guess between duplicates: deleting the wrong one of a matched
        // pair unenrolls a working machine.
        if devices.count > 1 && !all {
            print("\(devices.count) objects match \(query). ".yellow + "Pass an object id, or --all to delete every match:")
            for d in devices {
                print("  \((d.id ?? "-").dim)  \(d.displayName ?? "-")  trust=\(d.trustType ?? "-")  last sign-in \(String((d.approximateLastSignInDateTime ?? "-").prefix(10)))")
            }
            throw ExitCode.failure
        }

        guard confirm else {
            print("This will delete \(devices.count) Entra device object(s):".yellow)
            for d in devices { print("  \((d.id ?? "-").dim)  \(d.displayName ?? "-")") }
            print("Re-run with --confirm to proceed.")
            throw ExitCode.failure
        }

        var failed = false
        for d in devices {
            guard let id = d.id else { continue }
            let result = try await service.deleteEntraDeviceObjects([id]).first
            if result?.success == true {
                print("Deleted ".green + "\(d.displayName ?? id) (\(id))")
            } else {
                failed = true
                print("Failed ".red + "\(d.displayName ?? id) (\(id)): \(result?.error ?? "not deleted")")
            }
        }
        if failed { throw ExitCode.failure }
    }
}
