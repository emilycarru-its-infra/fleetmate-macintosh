import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

// `fleetmate lock` / `fleetmate unlock` — a reversible lock for a Windows device,
// which Intune does not offer (its Lock action is iOS/Android/macOS only).
//
// The lock is an Intune remediation assigned to one Entra group: being in the
// group is being locked. These commands change exactly one thing — the device's
// membership of that group — and record why on the device's Intune notes. One
// device per run, dry run until --confirm.

/// The group whose membership is the lock. Same default as the Windows CLI;
/// FLEETMATE_LOCK_GROUP overrides it.
let defaultLockGroup = ProcessInfo.processInfo.environment["FLEETMATE_LOCK_GROUP"] ?? "Devices-Lock"

struct LockPlan: Codable {
    let verb: String
    let serial: String
    let deviceName: String
    let operatingSystem: String?
    let user: String?
    let lastSync: String?
    let group: String
    let inLockGroup: Bool
    let ticket: String?

    var isNoOp: Bool { verb == "lock" ? inLockGroup : !inLockGroup }
}

enum DeviceLock {
    /// The one Entra object to change: the one the Intune record points at, since
    /// that is what the remediation assignment is evaluated against.
    static func target(_ state: DeviceRecordState) -> (EntraDevice?, String?) {
        guard let intune = state.intune else {
            return (nil, "\(state.serial) has no Intune record. The lock is an Intune remediation, so it cannot reach this device.")
        }
        guard intune.operatingSystem?.caseInsensitiveCompare("Windows") == .orderedSame else {
            return (nil, "\(intune.deviceName ?? state.serial) runs \(intune.operatingSystem ?? "an unknown OS"). This lock is for Windows only.")
        }
        let match = state.entraDevices.first {
            guard let bound = intune.azureADDeviceId, !bound.isEmpty else { return false }
            return $0.deviceId?.caseInsensitiveCompare(bound) == .orderedSame
        }
        guard let match else {
            return (nil, "\(intune.deviceName ?? state.serial) has no Entra device object matching its Intune record, so group membership cannot target it.")
        }
        return (match, nil)
    }

    static func noteLine(verb: String, ticket: String?, reason: String?, operatorName: String, when: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm xxx"
        var parts = ["\(formatter.string(from: when)) fleetmate \(verb) by \(operatorName)"]
        if let ticket, !ticket.isEmpty { parts.append("ticket \(ticket)") }
        if let reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: " - ")
    }

    static func timeline(locking: Bool) -> String {
        locking
            ? "The device picks this up at its next Intune remediation policy check: on restart, at a user sign-in, or within 8 hours, then locks within the hour. An offline device locks when it next comes online."
            : "The device picks this up at its next Intune remediation policy check (restart, a sign-in, or within 8 hours), then unlocks within the hour. Until then it stays locked."
    }

    static func run(locking: Bool, serial rawSerial: String, ticket: String?, reason: String?, group: String, confirm: Bool, json: Bool) async throws {
        let verb = locking ? "lock" : "unlock"
        let serial = rawSerial.trimmingCharacters(in: .whitespaces)

        func fail(_ code: String, _ message: String) throws -> Never {
            if json { try? printLifecycleJSON(["error": code, "message": message]) } else { print(message.red) }
            throw ExitCode.failure
        }

        if locking && (ticket ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            try fail("ticket-required", "A lock needs --ticket <id>, so the device record says why it was locked.")
        }
        let service = try lifecycleGraphService()

        let state = await service.getDeviceRecordState(serial: serial)
        if state.lookupFailed {
            try fail("lookup-failed", "Could not read the device records, so nothing was changed. \(state.lookupError ?? "reason unavailable")")
        }
        let (entra, refusal) = target(state)
        guard let entra, let entraObjectId = entra.id, let intune = state.intune else { try fail("no-target", refusal ?? "No target device.") }

        let lockGroup: EntraGroup?
        do { lockGroup = try await service.getGroupByName(group) } catch {
            try fail("no-group", "Could not read the \(group) group: \(error.localizedDescription)")
        }
        guard let lockGroup, let lockGroupId = lockGroup.id else {
            try fail("no-group", "The \(group) group does not exist. It is created by infrastructure code, not by FleetMate.")
        }

        let memberships: [DeviceGroupMembership]
        do { memberships = try await service.getDeviceGroupMemberships(intune.azureADDeviceId ?? "") } catch {
            try fail("lookup-failed", "Could not read the device's group memberships, so nothing was changed. \(error.localizedDescription)")
        }
        let isMember = memberships.contains { $0.id?.caseInsensitiveCompare(lockGroupId) == .orderedSame }

        let plan = LockPlan(verb: verb, serial: serial, deviceName: intune.deviceName ?? serial,
                            operatingSystem: intune.operatingSystem, user: intune.userPrincipalName,
                            lastSync: intune.lastSyncDateTime, group: group, inLockGroup: isMember, ticket: ticket)
        let nothingToDo = "Nothing to do. ".yellow + "\(plan.deviceName) is \(locking ? "already" : "not") in \(group)."

        guard confirm else {
            if json {
                struct DryRun: Encodable { let dryRun: Bool; let plan: LockPlan }
                try printLifecycleJSON(DryRun(dryRun: true, plan: plan))
            } else {
                let action = locking
                    ? "add to \(group): sign-in notice, sign-out, non-admin sign-in blocked; nothing is wiped"
                    : "remove from \(group): the lock is reversed on the device"
                print("Plan: ".bold + "\(verb) - \(action).")
                print("")
                print("Serial".col(16) + "Device".col(22) + "User".col(30) + "Last sync".col(18) + "In \(group)".col(18) + "Ticket")
                print(plan.serial.col(16) + plan.deviceName.col(22) + (plan.user ?? "-").col(30)
                      + String((plan.lastSync ?? "-").prefix(16)).col(18) + (plan.inLockGroup ? "yes" : "no").col(18) + (plan.ticket ?? "-"))
                print("")
                print(plan.isNoOp ? nothingToDo : "Dry run. ".yellow + "Re-run with --confirm to act.")
            }
            return
        }

        if plan.isNoOp {
            if json {
                struct Result: Encodable { let changed: Bool; let plan: LockPlan }
                try printLifecycleJSON(Result(changed: false, plan: plan))
            } else {
                print(nothingToDo)
            }
            return
        }

        do {
            if locking {
                try await service.addGroupMember(group: lockGroupId, objectId: entraObjectId)
            } else {
                try await service.removeGroupMember(group: lockGroupId, objectId: entraObjectId)
            }
        } catch {
            try fail("membership-failed", "Could not \(locking ? "add" : "remove") \(plan.deviceName) \(locking ? "to" : "from") \(group). \(error.localizedDescription)")
        }

        let note = noteLine(verb: verb, ticket: ticket, reason: reason, operatorName: NSUserName(), when: Date())
        let noted = await service.appendManagedDeviceNote(intune.id, line: note)

        if json {
            struct Result: Encodable { let changed: Bool; let noteWritten: Bool; let note: String; let plan: LockPlan }
            try printLifecycleJSON(Result(changed: true, noteWritten: noted, note: note, plan: plan))
            return
        }
        print(locking ? "Locked. ".green + "\(plan.deviceName) is now in \(group)." : "Unlocked. ".green + "\(plan.deviceName) is out of \(group).")
        if !noted { print("The Intune notes could not be updated; ".yellow + "record the ticket on the device by hand.") }
        print(timeline(locking: locking).dim)
    }
}

struct LockCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Lock a Windows device: add it to the lock group (sign-in notice, signs out users, blocks non-admin sign-in; nothing is wiped)"
    )

    @Argument(help: "Device serial number") var serial: String
    @Option(name: [.short, .long], help: "Ticket id this lock is for (required)") var ticket: String?
    @Option(help: "Short reason, recorded on the device's Intune notes") var reason: String?
    @Option(help: "Lock group name (default: \(defaultLockGroup))") var group: String = defaultLockGroup
    @Flag(help: "Required to actually act; without it this is a dry run") var confirm: Bool = false
    @Flag(help: "Output as JSON") var json: Bool = false

    func run() async throws {
        try await DeviceLock.run(locking: true, serial: serial, ticket: ticket, reason: reason, group: group, confirm: confirm, json: json)
    }
}

struct UnlockCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Unlock a Windows device: remove it from the lock group; the lock is reversed on the device"
    )

    @Argument(help: "Device serial number") var serial: String
    @Option(name: [.short, .long], help: "Ticket id this unlock is for") var ticket: String?
    @Option(help: "Short reason, recorded on the device's Intune notes") var reason: String?
    @Option(help: "Lock group name (default: \(defaultLockGroup))") var group: String = defaultLockGroup
    @Flag(help: "Required to actually act; without it this is a dry run") var confirm: Bool = false
    @Flag(help: "Output as JSON") var json: Bool = false

    func run() async throws {
        try await DeviceLock.run(locking: false, serial: serial, ticket: ticket, reason: reason, group: group, confirm: confirm, json: json)
    }
}
