import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// `fleetmate cimian` — triggering Cimian runs on Windows devices from a Mac.
/// Cimian itself is Windows-only; these commands reach it the same two ways the
/// Windows CLI does: an Intune proactive remediation, or a trigger file over SSH.
struct CimianCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cimian",
        abstract: "Cimian deployment system - push triggers, device management",
        subcommands: [CimianPushSubcommand.self]
    )
}

struct CimianPushResult: Codable {
    let deviceIdentifier: String
    let deviceName: String?
    let channel: String
    let success: Bool
    let message: String
}

struct CimianPushSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Trigger an immediate Cimian run on target devices"
    )

    static let triggerFile = #"C:\ProgramData\ManagedInstalls\.cimian.headless"#

    @Option(name: [.short, .customLong("serial")], parsing: .upToNextOption,
            help: "Target device serial numbers (comma-separated or multiple flags)")
    var serials: [String] = []

    @Option(name: [.short, .long], help: "Target Intune/Entra group name or ID")
    var group: String?

    @Flag(help: "Use SSH channel (direct, near-instant). Default is Intune.")
    var ssh: Bool = false

    @Flag(help: "Skip forcing Intune sync after deploying remediation (Intune channel only)")
    var noSync: Bool = false

    @Flag(help: "Show what would happen without executing")
    var dryRun: Bool = false

    @Flag(help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let serialList = serials.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
        guard !serialList.isEmpty || group != nil else {
            print("Specify --serial or --group to target devices".red)
            print("  fleetmate cimian push --serial SERIAL1".cyan)
            print("  fleetmate cimian push --group \"Lab group\"".cyan)
            print("  fleetmate cimian push --serial SERIAL1 --ssh".cyan)
            throw ExitCode.failure
        }
        let channel = ssh ? "SSH" : "Intune"

        if dryRun {
            print("DRY RUN - No changes will be made".yellow)
            print("Channel".col(18) + channel)
            if !serialList.isEmpty { print("Serials".col(18) + serialList.joined(separator: ", ")) }
            if let group { print("Group".col(18) + group) }
            if ssh {
                print("Method".col(18) + "SSH: Create trigger file directly on device")
                print("Trigger file".col(18) + Self.triggerFile)
                print("Expected latency".col(18) + "<10 seconds (CimianWatcher polling)")
            } else {
                print("Method".col(18) + "Deploy proactive remediation + force Intune sync")
                print("Trigger file".col(18) + Self.triggerFile)
                print("Expected latency".col(18) + "Minutes (after Intune sync)")
            }
            return
        }

        let started = Date()
        let results: [CimianPushResult]
        if ssh {
            guard !serialList.isEmpty else {
                print("SSH channel requires --serial (cannot resolve group members via SSH)".red)
                print("Use --group without --ssh to push via Intune.")
                throw ExitCode.failure
            }
            results = try await pushViaSsh(serialList)
        } else {
            let service = try lifecycleGraphService()
            results = if let group {
                try await pushViaIntune(service, group: group)
            } else {
                try await pushViaIntune(service, serials: serialList)
            }
        }

        let ok = results.filter(\.success).count
        if json {
            struct Batch: Encodable { let channel: String; let totalCount: Int; let successCount: Int; let durationSeconds: Double; let results: [CimianPushResult] }
            try printLifecycleJSON(Batch(channel: channel, totalCount: results.count, successCount: ok,
                                         durationSeconds: Date().timeIntervalSince(started), results: results))
        } else {
            let summary = "Push complete: \(ok)/\(results.count) succeeded via \(channel) (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)"
            print("\n" + (ok == results.count ? summary.green : summary.yellow))
            for r in results {
                let label = r.deviceName.map { "\(r.deviceIdentifier) (\($0))" } ?? r.deviceIdentifier
                print("  " + (r.success ? "✓ ".green : "✗ ".red) + label + "  " + r.message.dim)
            }
        }
        if ok < results.count { throw ExitCode.failure }
    }

    private func pushViaSsh(_ serials: [String]) async throws -> [CimianPushResult] {
        let config = try FleetMateConfig.load()
        let shell = SecureShellService(fleetConfig: config)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let content = "Bootstrap triggered at: \(stamp)\\nMode: Headless\\nTriggered by: FleetMate CLI (SSH)"
        let command = #"powershell -c "$dir = 'C:\ProgramData\ManagedInstalls'; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }; Set-Content -Path (Join-Path $dir '.cimian.headless') -Value '"# + content + #"' -Force; Write-Output 'OK'""#
        let batch = try await shell.executeBatch(hosts: serials, command: command)
        return batch.results.map { r in
            let triggered = r.success && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
            return CimianPushResult(
                deviceIdentifier: r.host, deviceName: r.deviceName, channel: "SSH", success: triggered,
                message: r.success ? "Trigger file created, CimianWatcher will pick up within 10s"
                    : (r.errorMessage ?? (r.stderr.isEmpty ? "SSH connection failed" : r.stderr)))
        }
    }

    private func pushViaIntune(_ service: GraphService, group: String) async throws -> [CimianPushResult] {
        let deployed: String
        do {
            deployed = try await service.deployCimianPushRemediation(group: group)
        } catch {
            return [CimianPushResult(deviceIdentifier: group, deviceName: nil, channel: "Intune", success: false,
                                     message: "Failed to deploy remediation: \(error.localizedDescription)")]
        }

        // Group members are Entra objects; their managed devices are what sync.
        var devices: [IntuneDevice] = []
        if let groupId = try await service.getGroupByName(group)?.id ?? (UUID(uuidString: group) != nil ? group : nil) {
            for member in try await service.getGroupDeviceMembers(groupId, limit: 500) {
                guard let deviceId = member.deviceId, !deviceId.isEmpty else { continue }
                devices += try await service.getManagedDevices(filter: "azureADDeviceId eq '\(deviceId)'", limit: 1)
            }
        }
        guard !devices.isEmpty else {
            return [CimianPushResult(deviceIdentifier: group, deviceName: nil, channel: "Intune", success: true,
                                     message: "Remediation deployed (\(deployed)) but no managed devices found in group")]
        }
        guard !noSync else {
            return devices.map {
                CimianPushResult(deviceIdentifier: $0.serialNumber ?? $0.id, deviceName: $0.deviceName, channel: "Intune",
                                 success: true, message: "Remediation deployed, will execute at next Intune check-in")
            }
        }
        let synced = try await service.syncDevices(devices.map(\.id))
        return devices.map { device in
            let r = synced.first { $0.deviceId == device.id }
            return CimianPushResult(deviceIdentifier: device.serialNumber ?? device.id, deviceName: device.deviceName, channel: "Intune",
                                    success: r?.success ?? true,
                                    message: r?.success == false ? "Remediation deployed but sync failed: \(r?.error ?? "")" : "Remediation deployed + sync forced")
        }
    }

    /// A serial-targeted push forces those devices to check in; a remediation
    /// already deployed to a group they belong to then runs.
    private func pushViaIntune(_ service: GraphService, serials: [String]) async throws -> [CimianPushResult] {
        var results: [CimianPushResult] = []
        var resolved: [IntuneDevice] = []
        for serial in serials {
            if let device = try await service.getDeviceBySerial(serial) { resolved.append(device) } else {
                results.append(CimianPushResult(deviceIdentifier: serial, deviceName: nil, channel: "Intune", success: false, message: "Device not found in Intune"))
            }
        }
        guard !resolved.isEmpty, !noSync else { return results }
        let synced = try await service.syncDevices(resolved.map(\.id))
        for device in resolved {
            let r = synced.first { $0.deviceId == device.id }
            results.append(CimianPushResult(deviceIdentifier: device.serialNumber ?? device.id, deviceName: device.deviceName, channel: "Intune",
                                            success: r?.success ?? true,
                                            message: r?.success == false ? "Sync failed: \(r?.error ?? "")" : "Intune sync forced, remediation will execute on check-in"))
        }
        return results
    }
}
