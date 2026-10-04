import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

// Commands that match the Windows CLI's `intune` lifecycle verbs, so the same
// runbook line works on either platform.

func lifecycleGraphService() throws -> GraphService {
    let config = try FleetMateConfig.load()
    let service = GraphService(config: config)
    guard service.isConfigured else {
        print("Microsoft Graph not configured.".red)
        throw ExitCode.failure
    }
    return service
}

/// Serial number or managedDevice id → managedDevice id. A GUID passes through.
func lifecycleDeviceId(_ service: GraphService, _ identifier: String) async throws -> String {
    if UUID(uuidString: identifier) != nil { return identifier }
    if let device = try await service.getDeviceBySerial(identifier), !device.id.isEmpty { return device.id }
    return identifier
}

func reportLifecycleAction(_ results: [BulkActionResult], action: String) throws {
    guard let result = results.first else {
        print("\(action) failed: not authenticated, or no device matched".red)
        throw ExitCode.failure
    }
    if result.success {
        print("Sent \(action)".green)
    } else {
        print("\(action) failed: ".red + (result.error ?? "unknown error"))
        throw ExitCode.failure
    }
}

func printLifecycleJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(value), encoding: .utf8) ?? "{}")
}

// MARK: - autopilot-reset

struct IntuneAutopilotResetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot-reset",
        abstract: "AutoPilot Reset a device back to OOBE, keeping OS and enrollment (DESTRUCTIVE)"
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Keep user data (rarely wanted on shared devices)")
    var keepUserData: Bool = false

    @Flag(help: "Required to actually reset")
    var confirm: Bool = false

    func run() async throws {
        guard confirm else {
            print("This will reset \(identifier) to OOBE, removing profiles, apps and settings. Re-run with --confirm to proceed.".yellow)
            throw ExitCode.failure
        }
        let service = try lifecycleGraphService()
        let id = try await lifecycleDeviceId(service, identifier)
        try reportLifecycleAction(try await service.autopilotResetDevices([id], keepUserData: keepUserData), action: "AutoPilot Reset")
    }
}

// MARK: - delete

struct IntuneDeleteSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a device's Intune record (server-side only; sends nothing to the device)"
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Required to actually delete")
    var confirm: Bool = false

    func run() async throws {
        guard confirm else {
            print("This will delete the Intune record for \(identifier), leaving it unmanaged until it re-enrolls. Re-run with --confirm to proceed.".yellow)
            throw ExitCode.failure
        }
        let service = try lifecycleGraphService()
        let id = try await lifecycleDeviceId(service, identifier)
        try reportLifecycleAction(try await service.deleteIntuneRecords([id]), action: "delete")
    }
}

// MARK: - autopilot (record state)

struct IntuneAutopilotRecordsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot",
        abstract: "Show the AutoPilot identity and directory records for a serial"
    )

    @Argument(help: "Device serial number")
    var serial: String

    @Flag(help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try lifecycleGraphService()
        let state = await service.getDeviceRecordState(serial: serial)
        if json {
            try printLifecycleJSON(state)
            if state.lookupFailed { throw ExitCode.failure }
            return
        }
        guard displayRecordState(state) else { throw ExitCode.failure }
    }
}

/// Renders the three records, or refuses when the lookup never reached Graph:
/// absent and unreadable records look identical in this table, and reporting
/// "none" for an enrolled machine sends people chasing a hash that was never missing.
@discardableResult
func displayRecordState(_ state: DeviceRecordState) -> Bool {
    if state.lookupFailed {
        print("Could not read the records for \(state.serial).".red)
        print((state.lookupError ?? "reason unavailable").dim)
        print("")
        print("This is usually an elevation problem, not a device problem. ".yellow + "Check az login, then retry.")
        return false
    }

    print("Record".col(22) + "Status".col(10) + "Detail")
    if let ap = state.autopilot {
        print("AutoPilot identity".col(22) + "present".green.col(10) + "\(ap.id ?? "-")  enrollmentState=\(ap.enrollmentState ?? "-")")
    } else {
        print("AutoPilot identity".col(22) + "missing".red.col(10) + "no hardware hash registered".red)
    }
    if let intune = state.intune {
        print("Intune managedDevice".col(22) + "present".green.col(10) + "\(intune.id)  \(intune.deviceName ?? "-")  \(intune.complianceState ?? "-")")
    } else {
        print("Intune managedDevice".col(22) + "none".yellow.col(10) + "no enrollment record".dim)
    }
    if state.entraDevices.isEmpty {
        print("Entra device object".col(22) + "none".yellow.col(10) + "no directory object".dim)
    }
    for entra in state.entraDevices {
        print("Entra device object".col(22) + "present".green.col(10) + "\(entra.id ?? "-")  \(entra.displayName ?? "-")  trust=\(entra.trustType ?? "-")  managed=\(entra.isManaged.map(String.init) ?? "-")")
    }

    if state.isOrphaned {
        print("Orphaned: ".red + "Entra still holds a device object but Intune has no record.")
        print("The next OOBE pass re-binds to the stale object by ZTDID and fails at \"Registering your device for mobile management\".".dim)
    }
    if state.hasDanglingManagedDeviceId, let id = state.autopilot?.managedDeviceId {
        print("AutoPilot identity still points at deleted managedDevice \(id) — Intune clears this on re-enrollment.".dim)
    }
    return true
}

// MARK: - cleanup

struct IntuneCleanupSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Delete the stale Intune and Entra records blocking re-enrollment (keeps the AutoPilot identity)"
    )

    @Argument(help: "Device serial number")
    var serial: String

    @Flag(help: "Required to actually delete")
    var confirm: Bool = false

    @Flag(help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try lifecycleGraphService()

        // Without --confirm this is the dry run: show exactly which records would
        // go, which is also the answer to "why did this machine fail".
        guard confirm else {
            let preview = await service.getDeviceRecordState(serial: serial)
            if json {
                try printLifecycleJSON(preview)
                if preview.lookupFailed { throw ExitCode.failure }
                return
            }
            guard displayRecordState(preview) else { throw ExitCode.failure }
            print("")
            print("Dry run. ".yellow + "Re-run with --confirm to delete the Intune and Entra records above. The AutoPilot identity is kept.")
            return
        }

        let result = await service.cleanDeviceRecords(serial: serial)
        if json {
            try printLifecycleJSON(result)
            if !result.success { throw ExitCode.failure }
            return
        }

        for d in result.deleted { print("Deleted ".green + d) }
        for s in result.skipped { print("Skipped \(s)".dim) }
        for e in result.errors { print("Error ".red + e) }
        for r in result.resyncRisk {
            print("\(r) was synced from on-prem AD; retire its computer object or Entra Connect re-creates it.".yellow)
        }

        if let id = result.retainedAutopilotId, !id.isEmpty {
            print("Kept AutoPilot identity \(id)".dim)
        } else if !result.lookupFailed {
            print("No AutoPilot identity found for this serial — the machine will not find a deployment profile at OOBE.".yellow)
        } else {
            print("This is usually an elevation problem, not a device problem. ".yellow + "Check az login, then retry.")
        }

        print(result.success ? "Records cleaned. The device can now enroll fresh.".green : "Cleanup incomplete — see errors above.".red)
        if !result.success { throw ExitCode.failure }
    }
}

// MARK: - sync / reboot / lock

struct IntuneSyncSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Force a device to sync with Intune")

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    func run() async throws {
        let service = try lifecycleGraphService()
        let id = try await lifecycleDeviceId(service, identifier)
        try reportLifecycleAction(try await service.syncDevices([id]), action: "sync")
    }
}

struct IntuneRebootSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reboot", abstract: "Reboot a device")

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    func run() async throws {
        let service = try lifecycleGraphService()
        let id = try await lifecycleDeviceId(service, identifier)
        try reportLifecycleAction(try await service.rebootDevices([id]), action: "reboot")
    }
}

struct IntuneLockSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "Remotely lock a device")

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Option(help: "Optional PIN (macOS)")
    var pin: String?

    func run() async throws {
        let service = try lifecycleGraphService()
        let id = try await lifecycleDeviceId(service, identifier)
        try reportLifecycleAction(try await service.remoteLockDevices([id], pin: pin), action: "lock")
    }
}
