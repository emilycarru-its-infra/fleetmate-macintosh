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

/// Resolve a destructive command's target to exactly one Intune record.
///
/// Serial numbers match with `eq` and a GUID by path; a name never matches.
/// Invalid input and more than one match exit with the candidates listed.
/// Returns nil only when nothing matches, so the caller can decide whether a
/// missing record is a refusal or the orphan case.
func resolveExactTarget(_ service: GraphService, _ identifier: String) async throws -> IntuneDevice? {
    let match: ExactMatch<IntuneDevice>
    do {
        match = try await service.resolveManagedDeviceExactly(identifier)
    } catch let error as DeviceIdentifierError {
        print(error.message.red)
        throw ExitCode.failure
    }
    switch match {
    case .one(let device):
        return device
    case .none:
        return nil
    case .many(let devices):
        print("\(devices.count) Intune records match \(identifier); refusing to choose one. Re-run with the managedDevice id:".red)
        printTargetCandidates(devices)
        throw ExitCode.failure
    }
}

/// As `resolveExactTarget`, but a missing record is also a refusal.
func requireExactTarget(_ service: GraphService, _ identifier: String) async throws -> IntuneDevice {
    guard let device = try await resolveExactTarget(service, identifier) else {
        print("No Intune record matches \(identifier) exactly. Nothing was sent.".red)
        throw ExitCode.failure
    }
    return device
}

func printTargetCandidates(_ devices: [IntuneDevice]) {
    for d in devices {
        print("  \(d.id)  \(d.deviceName ?? "-")  serial=\(d.serialNumber ?? "-")  \(d.platform.displayName)  last sync \(String((d.lastSyncDateTime ?? "-").prefix(10)))")
    }
}

/// What a destructive command is about to act on, printed before it acts.
func printTarget(_ device: IntuneDevice) {
    print("Target: ".bold + "\(device.deviceName ?? "-")  serial=\(device.serialNumber ?? "-")  \(device.platform.displayName)")
    print("  managedDevice \(device.id)  Entra deviceId \(device.azureADDeviceId ?? "-")".dim)
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
        let service = try lifecycleGraphService()
        let device = try await requireExactTarget(service, identifier)
        printTarget(device)
        guard device.platform == .windows else {
            print("AutoPilot Reset is Windows only.".red)
            throw ExitCode.failure
        }
        guard confirm else {
            print("Dry run. ".yellow + "This would reset it to OOBE, removing profiles, apps and settings. Re-run with --confirm to proceed.")
            return
        }
        try reportLifecycleAction(try await service.autopilotResetDevices([device.id], keepUserData: keepUserData), action: "AutoPilot Reset")
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
        let service = try lifecycleGraphService()
        let device = try await requireExactTarget(service, identifier)
        printTarget(device)
        guard confirm else {
            print("Dry run. ".yellow + "This would delete the Intune record, leaving it unmanaged until it re-enrolls. Re-run with --confirm to proceed.")
            return
        }
        try reportLifecycleAction(try await service.deleteIntuneRecords([device.id]), action: "delete")
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
    if let refusal = state.refusal {
        print(refusal.red)
        if !state.intuneCandidates.isEmpty { printTargetCandidates(state.intuneCandidates) }
        for ap in state.autopilotCandidates {
            print("  Autopilot \(ap.id ?? "-")  serial=\(ap.serialNumber ?? "-")  enrollmentState=\(ap.enrollmentState ?? "-")")
        }
        return false
    }
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

        // Show exactly what will be removed, and refuse on a failed or
        // ambiguous read, before deleting anything.
        let current = await service.getDeviceRecordState(serial: serial)
        guard displayRecordState(current) else { throw ExitCode.failure }
        print("")

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
        let device = try await requireExactTarget(service, identifier)
        printTarget(device)
        let id = device.id
        try reportLifecycleAction(try await service.syncDevices([id]), action: "sync")
    }
}

struct IntuneRebootSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reboot", abstract: "Reboot a device")

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    func run() async throws {
        let service = try lifecycleGraphService()
        let device = try await requireExactTarget(service, identifier)
        printTarget(device)
        let id = device.id
        try reportLifecycleAction(try await service.rebootDevices([id]), action: "reboot")
    }
}

struct IntuneLockSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "Remotely lock a device")

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Option(help: "Optional PIN (macOS)")
    var pin: String?

    @Flag(help: "Required to actually lock; without it this is a dry run")
    var confirm: Bool = false

    func run() async throws {
        let service = try lifecycleGraphService()
        let device = try await requireExactTarget(service, identifier)
        printTarget(device)
        guard confirm else {
            print("Dry run. ".yellow + "Re-run with --confirm to lock it.")
            return
        }
        try reportLifecycleAction(try await service.remoteLockDevices([device.id], pin: pin), action: "lock")
    }
}
