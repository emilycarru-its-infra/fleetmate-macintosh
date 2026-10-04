import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// Fleet reset — the whole re-provisioning operation for one machine or a lab in
/// one command: a reset plus the directory cleanup that keeps the next OOBE from
/// failing at "Registering your device for mobile management". Mirrors the
/// Windows CLI's `fleetmate wipe`.
struct WipeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wipe",
        abstract: "Reset devices back to OOBE and clean up the records that block re-enrollment (DESTRUCTIVE)"
    )

    /// A targeting mistake — a location typo that matches every asset — should
    /// stop at a refusal, not wipe a campus.
    static let defaultMaxTargets = 25

    enum Mode: String, ExpressibleByArgument, CaseIterable {
        case autopilotReset = "autopilot-reset"
        case factory
        case retire

        init?(argument: String) {
            switch argument.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "autopilot-reset", "autopilot", "reset": self = .autopilotReset
            case "factory", "wipe": self = .factory
            case "retire", "unenroll": self = .retire
            default: return nil
            }
        }
    }

    @Argument(help: "One or more device serial numbers")
    var serials: [String] = []

    @Option(name: [.short, .long], help: "Target every Snipe-IT asset at this location (name or id)")
    var location: String?

    @Option(help: "Target every Snipe-IT asset of this model (name or id)")
    var model: String?

    @Option(help: "Read serials from a file, one per line")
    var file: String?

    @Option(name: [.short, .long], help: "autopilot-reset (keeps OS + enrollment), factory (full reinstall), retire (unenroll only)")
    var mode: Mode = .autopilotReset

    @Flag(help: "Keep user data (rarely wanted on shared devices)")
    var keepUserData: Bool = false

    @Flag(help: "Skip the reset; only clean directory records for the resolved targets")
    var recordsOnly: Bool = false

    @Option(help: "Refuse batches larger than this (default \(WipeCommand.defaultMaxTargets))")
    var max: Int = WipeCommand.defaultMaxTargets

    @Flag(help: "Required to actually act; without it this is a dry run")
    var confirm: Bool = false

    @Flag(help: "Output as JSON")
    var json: Bool = false

    func validate() throws {
        // A mistyped flag must not become a target: `-confirm` would otherwise
        // read as one more serial and keep the run a dry run without saying so.
        if let bad = serials.first(where: { $0.hasPrefix("-") }) {
            throw ValidationError("'\(bad)' is not a serial. Flags take two dashes; run 'fleetmate wipe --help' for the list.")
        }
    }

    func run() async throws {
        let service = try lifecycleGraphService()
        let modeText = recordsOnly ? "records-only" : mode.rawValue

        let targets = try await resolveTargets()
        guard !targets.isEmpty else {
            print("No targets resolved. ".yellow + "Pass serials, or --location/--model/--file.")
            throw ExitCode.failure
        }
        guard targets.count <= max else {
            print("\(targets.count) targets exceeds the --max ceiling of \(max).".red)
            print("Narrow the targeting, or raise --max deliberately.".dim)
            throw ExitCode.failure
        }

        // Read every target's records up front: it is the dry-run report and the
        // "why did this one fail" answer.
        var states: [DeviceRecordState] = []
        for serial in targets { states.append(await service.getDeviceRecordState(serial: serial)) }

        // A failed lookup reports every record as absent, which is
        // indistinguishable from a machine that is already clean — so stop.
        let unreadable = states.filter(\.lookupFailed)
        if !unreadable.isEmpty {
            if json {
                struct LookupFailed: Encodable { let error: String; let message: String; let detail: String?; let serials: [String] }
                try printLifecycleJSON(LookupFailed(error: "lookup-failed",
                                                    message: "Could not read device records; no state is reported and nothing was changed.",
                                                    detail: unreadable[0].lookupError, serials: unreadable.map(\.serial)))
            } else {
                print("Could not read records for \(unreadable.count) of \(states.count) device(s).".red)
                print("Not showing device state: a failed lookup reports every record as absent, which is indistinguishable from a machine that is already clean.".dim)
                print("")
                print((unreadable[0].lookupError ?? "reason unavailable").dim)
                print("")
                print("This is usually an elevation problem, not a device problem. ".yellow + "Check az login, then retry.")
            }
            throw ExitCode.failure
        }

        guard confirm else {
            if json {
                struct DryRun: Encodable { let dryRun: Bool; let mode: String; let targets: [DeviceRecordState] }
                try printLifecycleJSON(DryRun(dryRun: true, mode: modeText, targets: states))
                return
            }
            displayPlan(states, modeText: modeText)
            print("")
            print("Dry run. ".yellow + "Re-run with --confirm to act on \(states.count) device(s).")
            return
        }

        struct Outcome: Encodable { let serial: String; let actions: [String]; let changed: Bool }
        var outcomes: [Outcome] = []
        var failures = 0, changed = 0, inertOrphans = 0

        for state in states {
            let serial = state.serial
            var actions: [String] = []
            var acted = false
            var resetSent = false

            if !recordsOnly {
                if let intune = state.intune {
                    let results: [BulkActionResult]
                    switch mode {
                    case .autopilotReset:
                        results = try await service.autopilotResetDevices([intune.id], keepUserData: keepUserData)
                    case .factory:
                        results = try await service.wipeDevices([intune], options: WipeOptions(keepEnrollmentData: false, keepUserData: keepUserData))
                    case .retire:
                        results = try await service.retireDevices([intune.id])
                    }
                    if results.first?.success == true {
                        actions.append("\(modeText) sent")
                        acted = true
                        resetSent = true
                        print(serial.green + " \(modeText) sent to \(intune.deviceName ?? serial)")
                    } else {
                        failures += 1
                        let message = results.first?.error ?? "unknown error"
                        actions.append("\(modeText) FAILED: \(message)")
                        print(serial.red + " \(modeText) failed: \(message)")
                    }
                } else {
                    // Nothing to send the reset to — not an error when the point is
                    // to clean up after a machine already wiped.
                    actions.append("reset skipped: no Intune record")
                    print(serial.yellow + " no Intune record — no reset can be sent")
                }
            }

            // Cleanup is not optional, but never strand a device whose reset failed.
            var deleted: [String] = []
            var errors: [String] = []
            var resyncRisk: [String] = []
            if !recordsOnly && state.intune != nil && !resetSent {
                actions.append("cleanup skipped: reset was not sent")
            } else if resetSent && mode == .autopilotReset {
                // AutoPilot Reset returns the device enrolled to its bound
                // records, so only the stale twins go. Names come from the state
                // read before the reset renamed the bound object.
                let cleanup = await service.cleanStaleEntraTwins(
                    serial: serial,
                    knownNames: state.entraDevices.compactMap(\.displayName) + [state.intune?.deviceName].compactMap { $0 },
                    liveAzureADDeviceId: state.intune?.azureADDeviceId)
                deleted = cleanup.deleted
                errors = cleanup.failed
                resyncRisk = cleanup.resyncRisk
            } else {
                let cleanup = await service.cleanDeviceRecords(serial: serial)
                deleted = cleanup.deleted
                errors = cleanup.errors
                resyncRisk = cleanup.resyncRisk
            }

            for d in deleted {
                actions.append("deleted \(d)")
                acted = true
                print(serial.green + " deleted \(d)")
            }
            for e in errors {
                failures += 1
                actions.append("cleanup FAILED: \(e)")
                print(serial.red + " \(e)")
            }
            if deleted.isEmpty && errors.isEmpty && !actions.contains("cleanup skipped: reset was not sent") {
                print("\(serial) no stale records to remove".dim)
            }
            for name in resyncRisk {
                actions.append("warning: \(name) was synced from on-prem AD and returns until its computer object is removed")
                print(serial.yellow + " \(name) came from on-prem AD. Remove its computer object, or Entra Connect re-creates the twin on the next sync.")
            }

            if acted { changed += 1 } else if state.intune == nil && !recordsOnly { inertOrphans += 1 }
            outcomes.append(Outcome(serial: serial, actions: actions, changed: acted))
        }

        if json {
            struct Summary: Encodable { let mode: String; let changed: Int; let results: [Outcome] }
            try printLifecycleJSON(Summary(mode: modeText, changed: changed, results: outcomes))
        }

        print("")
        print(Self.outcomeSummary(changed: changed, failures: failures, total: states.count))
        if inertOrphans > 0 {
            print("\(inertOrphans) device(s) had no Intune record, so no reset reached them.".yellow)
            print("A leftover Entra object is what fails a machine's next OOBE at \"Registering your device for mobile management\". Clear it with --records-only.".dim)
        }
        if failures > 0 { throw ExitCode.failure }
    }

    // MARK: - Targeting

    private func resolveTargets() async throws -> [String] {
        var targets: [String] = []
        var seen = Set<String>()
        func add(_ serial: String?) {
            guard let s = serial?.trimmingCharacters(in: .whitespaces), !s.isEmpty, seen.insert(s.lowercased()).inserted else { return }
            targets.append(s)
        }

        serials.forEach(add)

        if let file {
            guard let contents = try? String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) else {
                print("Serial file not found: \(file)".red)
                return targets
            }
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") { add(trimmed) }
            }
        }

        if location != nil || model != nil {
            let config = try FleetMateConfig.load()
            let snipe = SnipeService(config: config)
            guard snipe.isConfigured else {
                print("Snipe-IT is not configured ".red + "— inventory targeting needs it. Run fleetmate configure.")
                return targets
            }

            var locationId: Int?
            if let location {
                if let id = Int(location) { locationId = id } else {
                    let matches = try await snipe.getLocations().filter { ($0.name ?? "").localizedCaseInsensitiveContains(location) }
                    locationId = (matches.first { $0.name?.caseInsensitiveCompare(location) == .orderedSame } ?? matches.first)?.id
                }
                guard locationId != nil else {
                    print("No Snipe-IT location matches '\(location)'".red)
                    return targets
                }
            }

            var modelId: Int?
            if let model {
                if let id = Int(model) { modelId = id } else {
                    let matches = try await snipe.getModels().filter { ($0.name ?? "").localizedCaseInsensitiveContains(model) }
                    modelId = (matches.first { $0.name?.caseInsensitiveCompare(model) == .orderedSame } ?? matches.first)?.id
                }
                guard modelId != nil else {
                    print("No Snipe-IT model matches '\(model)'".red)
                    return targets
                }
            }

            let assets = try await snipe.getAssets(locationId: locationId, modelId: modelId)
            let withSerials = assets.filter { !($0.serial ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            if withSerials.count < assets.count {
                print("\(assets.count - withSerials.count) asset(s) skipped — no serial recorded in Snipe-IT".yellow)
            }
            withSerials.forEach { add($0.serial) }
        }

        return targets
    }

    // MARK: - Plan output

    private func displayPlan(_ states: [DeviceRecordState], modeText: String) {
        print(Self.planSummary(states, mode: modeText, twinsOnly: mode == .autopilotReset, recordsOnly: recordsOnly))
        print("")
        print("Serial".col(16) + "Device".col(24) + "Intune".col(9) + "Entra".col(7) + "AutoPilot".col(11) + "Note")
        for s in states {
            var note = s.isOrphaned ? "orphaned — Entra object with no Intune record"
                : (s.intune == nil && s.entraDevices.isEmpty ? "no directory records" : "")
            let twins = s.staleEntraTwins.count
            if twins > 0 { note = note.isEmpty ? "\(twins) stale twin(s) will be deleted" : "\(note) (\(twins) stale twin(s))" }
            print(s.serial.col(16)
                  + (s.intune?.deviceName ?? s.entraDevices.first?.displayName ?? "-").col(24)
                  + (s.intune == nil ? "none" : "present").col(9)
                  + (s.entraDevices.isEmpty ? "none" : "\(s.entraDevices.count)").col(7)
                  + (s.autopilot == nil ? "missing" : "present").col(11)
                  + note)
        }
        let noAutopilot = states.filter { $0.autopilot == nil }.count
        if noAutopilot > 0 {
            print("\(noAutopilot) device(s) have no AutoPilot identity ".yellow + "— those will not find a deployment profile at OOBE.")
        }
    }

    static func planSummary(_ states: [DeviceRecordState], mode: String, twinsOnly: Bool, recordsOnly: Bool) -> String {
        if recordsOnly { return "Plan: ".bold + "clean directory records only — no reset is sent." }
        let resettable = states.filter { $0.intune != nil }.count
        if resettable == 0 {
            return "Plan: ".bold + "no reset can be sent".yellow + " — no target has an Intune record. Stale Intune and Entra records will still be deleted."
        }
        let cleanup = twinsOnly
            ? "then delete stale Entra twins (the enrollment it returns to is kept)"
            : "then delete stale Intune and Entra records"
        return "Plan: ".bold + "\(mode) for \(resettable) of \(states.count) device(s), \(cleanup). The AutoPilot identity is always kept."
    }

    /// A run that changed nothing must not report "Done".
    static func outcomeSummary(changed: Int, failures: Int, total: Int) -> String {
        if failures > 0 { return "\(failures) failure(s)".red + " across \(total) device(s)." }
        return changed == 0
            ? "Nothing to do. ".yellow + "No change was made to \(total) device(s)."
            : "Done. ".green + "\(changed) of \(total) device(s) changed."
    }
}
