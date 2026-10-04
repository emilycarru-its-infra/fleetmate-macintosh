import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// `fleetmate deadline` — audit which account each Windows render node renders
/// as, by reading its Deadline.ini files over SSH. Mirrors the Windows CLI.
struct DeadlineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deadline",
        abstract: "Audit Deadline render farm configurations",
        subcommands: [DeadlineAuditSubcommand.self, DeadlineCheckSubcommand.self]
    )
}

struct DeadlineIniInfo: Codable {
    let path: String
    let user: String
    let content: String?

    enum CodingKeys: String, CodingKey { case path = "Path", user = "User", content = "Content" }
}

struct DeadlineAuditResult: Codable {
    var device: String
    var currentUser: String?
    var expectedUser: String?
    var isViolation = false
    var iniFilesFound = 0
    var iniFiles: [DeadlineIniInfo]?
    var error: String?
    var checkedAt = Date()
}

enum DeadlineProbe {
    /// Finds every per-user and system Deadline.ini and returns them as JSON.
    static let script = """
    $iniFiles = @()
    Get-ChildItem 'C:\\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $userPath = Join-Path $_.FullName 'AppData\\Local\\Thinkbox\\Deadline10\\deadline.ini'
        if (Test-Path $userPath) { $iniFiles += @{ Path = $userPath; User = $_.Name; Content = Get-Content $userPath -Raw } }
    }
    $sysPath = 'C:\\ProgramData\\Thinkbox\\Deadline10\\deadline.ini'
    if (Test-Path $sysPath) { $iniFiles += @{ Path = $sysPath; User = 'SYSTEM'; Content = Get-Content $sysPath -Raw } }
    $iniFiles | ConvertTo-Json -Depth 3
    """

    /// PowerShell's -EncodedCommand takes UTF-16LE base64, which survives the
    /// SSH hop without any quoting.
    static var command: String {
        let utf16 = script.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        return "powershell -NoProfile -EncodedCommand \(Data(utf16).base64EncodedString())"
    }

    static func check(_ shell: SecureShellService, device: String) async -> DeadlineAuditResult {
        var result = DeadlineAuditResult(device: device)
        do {
            let r = try await shell.execute(host: device, command: command)
            guard r.success else {
                result.error = r.errorMessage ?? "SSH connection failed"
                return result
            }
            var output = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                result.error = "No Deadline.ini files found"
                return result
            }
            if output.hasPrefix("{") { output = "[\(output)]" }
            let infos = try JSONDecoder().decode([DeadlineIniInfo].self, from: Data(output.utf8))
            guard !infos.isEmpty else {
                result.error = "No Deadline.ini files found"
                return result
            }
            result.iniFiles = infos
            result.iniFilesFound = infos.count
            result.currentUser = infos.first { $0.user != "SYSTEM" }?.user
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }
}

private func secureShellOrExit() throws -> SecureShellService {
    let config = try FleetMateConfig.load()
    guard config.secureShell != nil else {
        print("SecureShell is not configured.".red)
        print("Add SecureShell configuration to your config file (~/.fleetmate/config.yaml):")
        print("  secureShell:".cyan)
        print("    privateKeyPath: ~/.ssh/id_rsa".cyan)
        throw ExitCode.failure
    }
    return SecureShellService(fleetConfig: config)
}

struct DeadlineAuditSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit", abstract: "Audit Deadline.ini files across render nodes")

    @Option(name: [.short, .long], parsing: .upToNextOption, help: "Target devices (comma-separated hostnames or IPs)")
    var devices: [String] = []

    @Option(name: [.short, .long], help: "Expected render user account (default: dl-worker)")
    var expectedUser: String = "dl-worker"

    @Flag(help: "Output results as JSON")
    var json: Bool = false

    @Flag(name: [.customShort("v"), .long], help: "Show only devices with violations (non-expected users)")
    var violationsOnly: Bool = false

    func run() async throws {
        let shell = try secureShellOrExit()
        let targets = devices.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
        guard !targets.isEmpty else {
            print("No devices specified. Use --devices to specify render nodes.".yellow)
            print("Example: fleetmate deadline audit --devices RENDER-01,RENDER-02".dim)
            throw ExitCode.failure
        }

        var results: [DeadlineAuditResult] = []
        await withTaskGroup(of: DeadlineAuditResult.self) { group in
            var pending = targets.makeIterator()
            func next() -> Bool {
                guard let device = pending.next() else { return false }
                group.addTask { await DeadlineProbe.check(shell, device: device) }
                return true
            }
            for _ in 0..<10 { if !next() { break } } // at most 10 concurrent
            for await var r in group {
                r.expectedUser = expectedUser
                r.isViolation = (r.currentUser.map { $0.caseInsensitiveCompare(expectedUser) != .orderedSame }) ?? false
                results.append(r)
                _ = next()
            }
        }

        let shown = violationsOnly ? results.filter { $0.isViolation || $0.error != nil } : results
        let violations = results.filter(\.isViolation).count
        let errors = results.filter { $0.error != nil }.count

        if json {
            struct Audit: Encodable {
                let auditedAt: Date; let expectedUser: String; let totalDevices: Int
                let violations: Int; let errors: Int; let results: [DeadlineAuditResult]
            }
            try printLifecycleJSON(Audit(auditedAt: Date(), expectedUser: expectedUser, totalDevices: results.count,
                                         violations: violations, errors: errors, results: shown))
            return
        }

        print("\n" + "Deadline Render Farm Audit".cyan)
        print("Expected user: ".dim + expectedUser.cyan + "\n")
        print("Device".col(24) + "Current User".col(28) + "Status".col(11) + "INI Files")
        for r in shown.sorted(by: { $0.device < $1.device }) {
            let status = r.error != nil ? "ERROR".red : (r.isViolation ? "VIOLATION".yellow : "OK".green)
            let user = r.error ?? r.currentUser ?? "none"
            print(r.device.col(24) + user.col(28) + status + "    " + "\(r.iniFilesFound)")
        }
        let ok = results.count - violations - errors
        print("\n" + "Total: ".dim + "\(results.count) | " + "OK: ".green + "\(ok) | " + "Violations: ".yellow + "\(violations) | " + "Errors: ".red + "\(errors)")
        if violations > 0 { print("\n" + "Found \(violations) device(s) with non-\(expectedUser) users rendering!".yellow) }
    }
}

struct DeadlineCheckSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Check Deadline user on a single device")

    @Argument(help: "Device hostname or IP address")
    var device: String

    @Flag(help: "Output result as JSON")
    var json: Bool = false

    func run() async throws {
        let shell = try secureShellOrExit()
        let result = await DeadlineProbe.check(shell, device: device)
        if json {
            try printLifecycleJSON(result)
            return
        }
        print("Deadline Config: \(result.device)".cyan)
        if let error = result.error {
            print("Error: ".red + error)
            throw ExitCode.failure
        }
        print("Device".col(18) + result.device)
        print("Current User".col(18) + (result.currentUser ?? "none"))
        print("INI Files Found".col(18) + "\(result.iniFilesFound)")
        if let files = result.iniFiles, !files.isEmpty {
            print("\n" + "Deadline.ini locations:".dim)
            for ini in files { print("  • " + ini.user.cyan + ": \(ini.path)") }
        }
    }
}
