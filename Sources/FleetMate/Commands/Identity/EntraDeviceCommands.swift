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
        abstract: "Delete an Entra device object (DESTRUCTIVE)",
        discussion: """
        Takes a deviceId or object id only. A display name is not accepted: two \
        machines can share one, and `fleetmate entra device <name>` lists the ids \
        to choose from. A deviceId that matches more than one object is refused.
        """
    )

    @Argument(help: "deviceId or object id (GUID)")
    var id: String

    @Flag(help: "Required to actually delete")
    var confirm: Bool = false

    func run() async throws {
        let service = try lifecycleGraphService()
        let devices: [EntraDevice]
        do {
            devices = try await service.findEntraDevices(id: id)
        } catch let error as DeviceIdentifierError {
            print(error.message.red)
            print("Look the id up with: fleetmate entra device <name>".dim)
            throw ExitCode.failure
        }

        let match = ExactMatch.resolve(devices, matching: id.lowercased()) { device in
            [device.id, device.deviceId].compactMap { $0?.lowercased() }.first { $0 == id.lowercased() }
        }
        switch match {
        case .none:
            print("No Entra device object has id \(id).".yellow)
            throw ExitCode.failure
        case .many(let all):
            // Refuse to guess between duplicates: deleting the wrong one of a
            // matched pair unenrolls a working machine.
            print("\(all.count) objects match \(id); refusing to choose one. Re-run with an object id:".red)
            for d in all { print("  \(d.id ?? "-")  \(d.displayName ?? "-")  trust=\(d.trustType ?? "-")  last sign-in \(String((d.approximateLastSignInDateTime ?? "-").prefix(10)))") }
            throw ExitCode.failure
        case .one(let device):
            guard let objectId = device.id else { throw ExitCode.failure }
            print("Target: ".bold + "\(device.displayName ?? "-")  \(device.operatingSystem ?? "-")  trust=\(device.trustType ?? "-")")
            print("  object \(objectId)  deviceId \(device.deviceId ?? "-")".dim)
            guard confirm else {
                print("Dry run. ".yellow + "Re-run with --confirm to delete this object.")
                return
            }
            let result = try await service.deleteEntraDeviceObjects([objectId]).first
            if result?.success == true {
                print("Deleted ".green + "\(device.displayName ?? objectId) (\(objectId))")
            } else {
                print("Failed ".red + "\(device.displayName ?? objectId) (\(objectId)): \(result?.error ?? "not deleted")")
                throw ExitCode.failure
            }
        }
    }
}
