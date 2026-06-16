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

private func reportBulk(_ results: [BulkActionResult], action: String) throws {
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

// MARK: - Wipe

struct IntuneWipeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wipe",
        abstract: "Factory-reset a device (DESTRUCTIVE)"
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Keep user data on wipe")
    var keepUserData: Bool = false

    @Flag(help: "Required to actually perform the wipe")
    var confirm: Bool = false

    func run() async throws {
        guard confirm else {
            print("This will factory-reset \(identifier). Re-run with --confirm to proceed.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()
        let id = try await resolveDeviceId(service, identifier)
        let results = try await service.wipeDevices([id], keepUserData: keepUserData)
        try reportBulk(results, action: "wipe")
    }
}

// MARK: - Retire

struct IntuneRetireSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retire",
        abstract: "Remove company data and unenroll a device"
    )

    @Argument(help: "Serial number or managedDevice id")
    var identifier: String

    @Flag(help: "Required to actually perform the retire")
    var confirm: Bool = false

    func run() async throws {
        guard confirm else {
            print("This will unenroll \(identifier). Re-run with --confirm to proceed.".yellow)
            throw ExitCode.failure
        }
        let service = try graphServiceOrExit()
        let id = try await resolveDeviceId(service, identifier)
        let results = try await service.retireDevices([id])
        try reportBulk(results, action: "retire")
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
