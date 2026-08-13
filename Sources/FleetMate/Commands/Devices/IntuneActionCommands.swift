import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

// MARK: - Shared helpers

private func graphServiceOrExit() throws -> GraphService {
    let config = try FleetMateConfig.load()
    let service = GraphService(config: config)
    guard service.isConfigured else {
        print("Microsoft Graph not configured.".red)
        throw ExitCode.failure
    }
    return service
}

/// Resolve a serial number to a managedDevice id; if no device matches, assume
/// the identifier already is a managedDevice id and pass it through.
private func resolveDeviceId(_ service: GraphService, _ identifier: String) async throws -> String {
    if let device = try await service.getDeviceBySerial(identifier), !device.id.isEmpty {
        return device.id
    }
    return identifier
}

/// Resolve to the full record so platform-specific options can be applied.
/// Returns nil when nothing matches, which every caller that needs a platform
/// treats as fatal.
private func resolveDevice(_ service: GraphService, _ identifier: String) async throws -> IntuneDevice? {
    try await service.resolveManagedDevice(identifier)
}

private func reportBulk(_ results: [BulkActionResult], action: String) throws {
    guard !results.isEmpty else {
        print("\(action): no devices acted on (not authenticated, or no match)".red)
        throw ExitCode.failure
    }
    let ok = results.filter { $0.success }.count
    let failed = results.count - ok
    if failed == 0 {
        print("Sent \(action) to \(ok) device(s)".green)
    } else {
        print("\(action): \(ok) ok, \(failed) failed".yellow)
        for r in results where !r.success {
            print("  \(r.deviceId): \(r.error ?? "unknown error")".red)
        }
        throw ExitCode.failure
    }
}

extension WipeOptions.ObliterationBehavior: ExpressibleByArgument {}
extension OffboardPlan.TerminalAction: ExpressibleByArgument {}
extension OffboardPlan.EntraAction: ExpressibleByArgument {}

// MARK: - Wipe

struct IntuneWipeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wipe",
        abstract: "Factory-reset a device (DESTRUCTIVE)",
        discussion: """
        Options are filtered to the target platform: --keep-user-data and \
        --protected apply to Windows, --unlock-code and --obliteration to \
        macOS. Anything that does not apply is dropped rather than sent, \
        because Graph rejects the whole request over one foreign key.
        """
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Windows: keep user data (reset rather than full erase)")
    var keepUserData: Bool = false

    @Flag(help: "Leave the device enrolled after the wipe")
    var keepEnrollmentData: Bool = false

    @Flag(help: "Windows: protected wipe — retries until it succeeds and cannot be circumvented")
    var protected: Bool = false

    @Option(help: "macOS/iOS: recovery lock PIN applied with the wipe")
    var unlockCode: String?

    @Option(help: "macOS 12+: Erase All Content and Settings behaviour (default, doNotObliterate, obliterateWithWarning, always)")
    var obliteration: WipeOptions.ObliterationBehavior?

    @Flag(help: "Resolve the device and print the request without sending it")
    var dryRun: Bool = false

    @Flag(help: "Required to actually perform the wipe")
    var confirm: Bool = false

    func run() async throws {
        guard dryRun || confirm else {
            print("This will factory-reset \(identifier). Re-run with --confirm to proceed, or --dry-run to see what would be sent.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()
        let options = WipeOptions(
            keepEnrollmentData: keepEnrollmentData,
            keepUserData: keepUserData,
            useProtectedWipe: protected,
            macOsUnlockCode: unlockCode,
            obliterationBehavior: obliteration
        )

        let device = try await resolveDevice(service, identifier)

        if dryRun {
            let platform = device?.platform ?? .other
            printDryRunHeader(device: device, identifier: identifier)
            if device == nil {
                print("  No Intune device matches — the request would go out with only the keys every platform accepts.".yellow)
            }
            print("  POST managedDevices/\(device?.id ?? identifier)/wipe")
            print("       \(GraphService.describe(options.requestBody(for: platform)))")
            printDroppedWipeOptions(options, platform: platform)
            print("\nDry run — nothing was sent.".cyan)
            return
        }

        let results: [BulkActionResult]
        if let device {
            print("Wiping \(device.deviceName ?? identifier) (\(device.platform.displayName))".cyan)
            results = try await service.wipeDevices([device], options: options)
        } else {
            // Unknown platform — send only the keys every platform accepts.
            results = try await service.wipeDevices([identifier], options: options)
        }
        try reportBulk(results, action: "wipe")
    }
}

/// Name the options that were asked for but dropped for this platform, so a
/// dry run explains a body that is smaller than the flags implied.
private func printDroppedWipeOptions(_ options: WipeOptions, platform: DevicePlatform) {
    let body = options.requestBody(for: platform)
    var dropped: [String] = []

    if options.keepUserData && (body["keepUserData"] as? Bool) != true {
        dropped.append("--keep-user-data (not supported on \(platform.displayName))")
    }
    if options.useProtectedWipe && body["useProtectedWipe"] == nil {
        dropped.append("--protected (Windows only)")
    }
    if let code = options.macOsUnlockCode, !code.isEmpty, body["macOsUnlockCode"] == nil {
        dropped.append("--unlock-code (macOS/iOS only)")
    }
    if options.obliterationBehavior != nil && body["obliterationBehavior"] == nil {
        dropped.append("--obliteration (macOS only)")
    }

    guard !dropped.isEmpty else { return }
    print("  Dropped for this platform:".yellow)
    for item in dropped { print("    – \(item)".yellow) }
}

private func printDryRunHeader(device: IntuneDevice?, identifier: String) {
    let name = device?.deviceName ?? identifier
    let platform = device?.platform.displayName ?? "unknown platform"
    print("\n" + "Dry run".bold + " — \(name) (\(platform))")
}

// MARK: - Retire

struct IntuneRetireSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retire",
        abstract: "Remove company data and unenroll a device"
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Resolve the device and print the request without sending it")
    var dryRun: Bool = false

    @Flag(help: "Required to actually perform the retire")
    var confirm: Bool = false

    func run() async throws {
        guard dryRun || confirm else {
            print("This will unenroll \(identifier). Re-run with --confirm to proceed, or --dry-run to see what would be sent.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()

        if dryRun {
            let device = try await resolveDevice(service, identifier)
            printDryRunHeader(device: device, identifier: identifier)
            print("  POST managedDevices/\(device?.id ?? identifier)/retire")
            print("\nDry run — nothing was sent.".cyan)
            return
        }

        let id = try await resolveDeviceId(service, identifier)
        let results = try await service.retireDevices([id])
        try reportBulk(results, action: "retire")
    }
}

// MARK: - Fresh Start (Windows)

struct IntuneFreshStartSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fresh-start",
        abstract: "Windows: reinstall Windows, keeping enrollment (DESTRUCTIVE)",
        discussion: """
        Removes preinstalled OEM apps and reinstalls Windows while the device \
        stays enrolled and Entra-joined. Windows only — Graph rejects it for \
        any other platform.
        """
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(inversion: .prefixedNo, help: "Preserve the user's data and account")
    var keepUserData: Bool = true

    @Flag(help: "Resolve the device and print the request without sending it")
    var dryRun: Bool = false

    @Flag(help: "Required to actually perform the Fresh Start")
    var confirm: Bool = false

    func run() async throws {
        guard dryRun || confirm else {
            print("This will reinstall Windows on \(identifier). Re-run with --confirm to proceed, or --dry-run to see what would be sent.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()
        let device = try await resolveDevice(service, identifier)
        if let device, device.platform != .windows {
            print("\(device.deviceName ?? identifier) is \(device.platform.displayName) — Fresh Start is Windows only.".red)
            throw ExitCode.failure
        }

        if dryRun {
            printDryRunHeader(device: device, identifier: identifier)
            print("  POST managedDevices/\(device?.id ?? identifier)/cleanWindowsDevice")
            print("       {\"keepUserData\":\(keepUserData)}")
            print("\nDry run — nothing was sent.".cyan)
            return
        }

        let results = try await service.freshStartDevices([device?.id ?? identifier], keepUserData: keepUserData)
        try reportBulk(results, action: "fresh start")
    }
}

// MARK: - Delete the Intune record

struct IntuneDeleteRecordSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-record",
        abstract: "Delete the Intune managedDevice record",
        discussion: """
        The record carries any pending device action, so deleting it before the \
        device has checked in cancels a queued wipe or retire. Use it on \
        hardware that is already gone, or after the action has run.
        """
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Resolve the device and print the request without sending it")
    var dryRun: Bool = false

    @Flag(help: "Required to actually delete the record")
    var confirm: Bool = false

    func run() async throws {
        guard dryRun || confirm else {
            print("This will delete the Intune record for \(identifier). Re-run with --confirm to proceed, or --dry-run to see what would be sent.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()

        if dryRun {
            let device = try await resolveDevice(service, identifier)
            printDryRunHeader(device: device, identifier: identifier)
            print("  DELETE managedDevices/\(device?.id ?? identifier)")
            print("\nDry run — nothing was sent.".cyan)
            return
        }

        let id = try await resolveDeviceId(service, identifier)
        let results = try await service.deleteManagedDevices([id])
        try reportBulk(results, action: "delete record")
    }
}

// MARK: - Offboard

struct IntuneOffboardSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "offboard",
        abstract: "Decommission a device across Intune, Autopilot and Entra (DESTRUCTIVE)",
        discussion: """
        Runs the terminal Intune action first, then the Autopilot registration \
        and the Entra device object, and deletes the Intune record last — \
        deleting it earlier would cancel a wipe the device has not picked up. \
        Steps that do not apply to the platform are reported as skipped.
        """
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Option(help: "Terminal Intune action: wipe, retire, or none")
    var action: OffboardPlan.TerminalAction = .wipe

    @Flag(help: "Windows: keep user data on the wipe")
    var keepUserData: Bool = false

    @Flag(help: "Windows: protected wipe")
    var protected: Bool = false

    @Option(help: "macOS/iOS: recovery lock PIN applied with the wipe")
    var unlockCode: String?

    @Option(help: "macOS 12+: Erase All Content and Settings behaviour")
    var obliteration: WipeOptions.ObliterationBehavior?

    @Flag(help: "Delete the Windows Autopilot registration")
    var deleteAutopilot: Bool = false

    @Option(help: "Entra device object: none, disable, or delete")
    var entra: OffboardPlan.EntraAction = .none

    @Flag(help: "Delete the Intune managedDevice record last")
    var deleteRecord: Bool = false

    @Flag(help: "Resolve every downstream record and print the plan without writing anything")
    var dryRun: Bool = false

    @Flag(help: "Required to actually offboard")
    var confirm: Bool = false

    func run() async throws {
        guard dryRun || confirm else {
            print("This will offboard \(identifier). Re-run with --confirm to proceed, or --dry-run to see the plan.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()
        guard let device = try await resolveDevice(service, identifier) else {
            print("No Intune device matches \(identifier)".red)
            throw ExitCode.failure
        }

        let plan = OffboardPlan(
            terminalAction: action,
            wipeOptions: WipeOptions(
                keepUserData: keepUserData,
                useProtectedWipe: protected,
                macOsUnlockCode: unlockCode,
                obliterationBehavior: obliteration
            ),
            deleteIntuneRecord: deleteRecord,
            deleteAutopilotRegistration: deleteAutopilot,
            entraAction: entra
        )

        if dryRun {
            printDryRunHeader(device: device, identifier: identifier)
            let steps = await service.previewOffboard(device, plan: plan)
            for step in steps {
                if step.willRun {
                    print("  → \(step.step)".green)
                    print("       \(step.detail)")
                } else {
                    print("  – \(step.step): \(step.detail)".yellow)
                }
            }
            printDroppedWipeOptions(plan.wipeOptions, platform: device.platform)
            print("\nDry run — nothing was sent.".cyan)
            return
        }

        print("Offboarding \(device.deviceName ?? identifier) (\(device.platform.displayName))".cyan)
        let result = await service.offboardDevice(device, plan: plan)

        for step in result.steps {
            switch step.outcome {
            case .succeeded:
                print("  ✓ \(step.step)".green)
            case .skipped:
                print("  – \(step.step): \(step.detail ?? "skipped")".yellow)
            case .failed:
                print("  ✗ \(step.step): \(step.detail ?? "unknown error")".red)
            }
        }

        guard result.success else { throw ExitCode.failure }
    }
}

// MARK: - Cimian push remediation

struct IntuneCimianPushSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cimian-push",
        abstract: "Deploy the Cimian push-trigger proactive remediation to a group"
    )

    @Argument(help: "Target group name or id")
    var group: String

    func run() async throws {
        let service = try graphServiceOrExit()
        let scriptId = try await service.deployCimianPushRemediation(group: group)
        print("Deployed Cimian push remediation to \(group) (script id \(scriptId))".green)
    }
}
