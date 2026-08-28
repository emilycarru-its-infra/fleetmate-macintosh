import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

// MARK: - Root

/// Apple Remote Desktop / UNIX command runner — run stock ARD scripts or custom commands
/// on individual computers or entire groups, directly from the terminal or VS Code tasks.
struct ArdCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ard",
        abstract: "Run ARD UNIX scripts or custom commands on computers via SSH",
        discussion: """
            Execute standard Mac-admin scripts over SSH, targeting one device or a whole group
            of computers. Groups come from ReportMate location names or a computers.csv file.

            TARGETING
              --device / -d   single computer: name, serial, hostname, or IP
              --group  / -g   all computers in a named group (ReportMate location name or path
                              to a CSV file of computer names/IPs)

            EXAMPLES
              fleetmate ard group scan "B1122 Studio Lab"
              fleetmate ard inventory ip --group "B1122 Studio Lab"
              fleetmate ard updates install --device Mac-Studio-01
              fleetmate ard run "uptime" --group "B1122 Studio Lab"
              fleetmate ard vnc Mac-Studio-01
              fleetmate ard security filevault --group computers.csv --json
              fleetmate ard macos erase-install --device Mac-Studio-01 --confirm
            """,
        subcommands: [
            // Group management: ping scan, list, CSV preview
            ArdGroupCommand.self,

            // Custom command runner
            ArdRunCommand.self,

            // VNC / Screen Sharing
            ArdVncCommand.self,

            // SSH-based categories
            ArdInventoryCommand.self,
            ArdSecurityCommand.self,
            ArdUpdatesCommand.self,
            ArdMunkiCommand.self,
            ArdUpkeepCommand.self,
            ArdUsersCommand.self,
            ArdProfilesCommand.self,
            ArdDockCommand.self,
            ArdPrintingCommand.self,
            ArdEnrollmentCommand.self,
            ArdLogsCommand.self,
            ArdMacOSCommand.self,
        ]
    )
}

// MARK: - Shared target options

/// Shared options injected into every ARD script subcommand via @OptionGroup.
struct ArdTargetOptions: ParsableArguments {
    @Option(name: [.customShort("d"), .long], help: "Single target: device name, serial, hostname, or IP")
    var device: String?

    @Option(name: .shortAndLong, help: "All computers in a group: ReportMate location name or path to a CSV file of computer names/IPs")
    var group: String?

    @Option(name: [.customShort("u"), .long], help: "SSH username override (default: from config)")
    var user: String?

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func validate() throws {
        if device == nil && group == nil {
            throw ValidationError("Provide --device <computer> or --group <group-name-or-csv>.")
        }
        if device != nil && group != nil {
            throw ValidationError("Use either --device or --group, not both.")
        }
    }
}

// MARK: - Runner

/// Shared SSH execution logic used by all leaf ARD subcommands.
enum ArdRunner {
    static func run(script: String, targeting: ArdTargetOptions) async throws {
        let config = try FleetMateConfig.load()

        guard config.isSecureShellConfigured else {
            print("[ERROR] SSH not configured. Set SECURE_SHELL_PRIVATE_KEY_PATH in config.".red)
            throw ExitCode.failure
        }

        let ssh = SecureShellService(fleetConfig: config)

        if let singleDevice = targeting.device {
            // ── Single computer ────────────────────────────────────────────
            print("Connecting to \(singleDevice)...".cyan)
            let result = try await ssh.execute(
                host: singleDevice,
                command: script,
                username: targeting.user
            )
            printResult(result, json: targeting.json)
            if result.exitCode != 0 { throw ExitCode(Int32(result.exitCode)) }

        } else if let groupValue = targeting.group {
            // ── All computers in a group ───────────────────────────────────
            let identifiers = try await resolveGroup(groupValue, config: config)
            guard !identifiers.isEmpty else {
                print("[ERROR] No computers found in group: \"\(groupValue)\"".red)
                print("   Run 'fleetmate ard group list' to see known groups.".dim)
                throw ExitCode.failure
            }
            print("Running on \(identifiers.count) computers in \"\(groupValue)\"...".cyan)
            let batch = try await ssh.executeBatch(
                hosts: identifiers,
                command: script,
                username: targeting.user
            )
            printBatchResults(batch, json: targeting.json)
        }
    }

    /// Resolve a group value to a list of host identifiers.
    /// Accepts a path to a CSV file of computer names/IPs, or a ReportMate location name.
    static func resolveGroup(_ groupValue: String, config: FleetMateConfig) async throws -> [String] {
        let expandedPath = (groupValue as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            return try computersFromCSV(path: expandedPath)
        }
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured — required for group targeting by name.".red)
            print("   Alternatively, pass a path to a CSV file of computer names/IPs.".dim)
            throw ExitCode.failure
        }
        let rm = ReportMateService(config: config)
        let all = try await rm.getDevices()
        let matched = all.filter { $0.location.lowercased().contains(groupValue.lowercased()) }
        return matched.map { d in d.ipAddress.isEmpty ? d.displayName : d.ipAddress }
    }

    /// Parse a CSV file — first column is the computer name or IP; lines starting with # are comments.
    static func computersFromCSV(path: String) throws -> [String] {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line -> String? in
                let first = line.components(separatedBy: ",").first ?? ""
                let stripped = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return stripped.isEmpty ? nil : stripped
            }
    }

    // ── Formatters ──────────────────────────────────────────────────────────

    private static func printResult(_ result: SecureShellResult, json: Bool) {
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(result) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
            return
        }
        let host = result.deviceName.map { "\($0) (\(result.host))" } ?? result.host
        if result.exitCode == 0 {
            print("\n[ok] ".green + host.bold)
        } else {
            print("\n[error] ".red + host.bold + " (exit \(result.exitCode))")
        }
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { print(result.stderr.yellow) }
    }

    private static func printBatchResults(_ batch: SecureShellBatchResult, json: Bool) {
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(batch) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
            return
        }
        let ok  = batch.results.filter { $0.exitCode == 0 }
        let bad = batch.results.filter { $0.exitCode != 0 }
        for r in batch.results.sorted(by: { ($0.deviceName ?? $0.host) < ($1.deviceName ?? $1.host) }) {
            printResult(r, json: false)
        }
        print("\n" + "─────────────────────────────".dim)
        print("[ok] \(ok.count) succeeded  [error] \(bad.count) failed  \(String(format: "%.1f", batch.totalDurationSeconds))s\n")
    }
}

// MARK: - ard group

struct ArdGroupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Computer group operations: ping scan, list groups, preview CSV",
        subcommands: [
            ArdGroupScanSubcommand.self,
            ArdGroupListSubcommand.self,
            ArdGroupPreviewSubcommand.self,
        ],
        defaultSubcommand: ArdGroupScanSubcommand.self
    )
}

/// Ping-table scan — shows every computer in a group with its IP and online/offline status.
/// No SSH required; data comes from ReportMate or a CSV file.
struct ArdGroupScanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Ping all computers in a group and display IP/status table"
    )

    @Argument(help: "Group name (ReportMate location) or path to CSV file of computer names/IPs")
    var group: String

    @Flag(name: .shortAndLong, help: "Only show online computers")
    var onlineOnly: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        var computers: [(name: String, ip: String)] = []

        let expandedPath = (group as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            let names = try ArdRunner.computersFromCSV(path: expandedPath)
            computers = names.map { ($0, $0) }
        } else {
            guard config.isReportMateConfigured else {
                print("[ERROR] ReportMate not configured.".red)
                throw ExitCode.failure
            }
            let rm = ReportMateService(config: config)
            let all = try await rm.getDevices()
            computers = all
                .filter { $0.location.lowercased().contains(group.lowercased()) }
                .sorted { $0.displayName < $1.displayName }
                .map { ($0.displayName, $0.ipAddress) }
        }

        guard !computers.isEmpty else {
            print("[ERROR] No computers found in group: \"\(group)\"".red)
            print("   Run 'fleetmate ard group list' to see known groups.".dim)
            throw ExitCode.failure
        }

        // Ping concurrently
        let results: [ComputerStatus] = await withTaskGroup(of: ComputerStatus.self) { taskGroup in
            for (name, ip) in computers {
                taskGroup.addTask {
                    let online = ip.isEmpty ? false : await pingOne(ip)
                    return ComputerStatus(name: name, ip: ip, online: online)
                }
            }
            var out: [ComputerStatus] = []
            for await s in taskGroup { out.append(s) }
            return out.sorted { $0.name < $1.name }
        }

        let visible = onlineOnly ? results.filter { $0.online } : results

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(visible) { print(String(data: data, encoding: .utf8) ?? "[]") }
            return
        }

        let onlineCount  = results.filter { $0.online }.count
        let offlineCount = results.count - onlineCount
        let nW = 32; let iW = 18

        print("\n=== \(group) ===\n".bold)
        print(("  " + "COMPUTER".col(nW) + " " + "IP".col(iW) + " STATUS").bold)
        print("  " + String(repeating: "-", count: nW) + " " + String(repeating: "-", count: iW) + " ------")
        for s in visible {
            let ip = s.ip.isEmpty ? "—" : s.ip
            let status = s.online
                ? "+ online".green
                : (s.ip.isEmpty ? "? no IP".yellow : "- offline".red)
            print("  " + s.name.col(nW) + " " + ip.col(iW) + " " + status)
        }
        print("\n  Total: \(results.count) | Online: \(onlineCount) | Offline: \(offlineCount)\n")
    }
}

struct ComputerStatus: Codable {
    let name: String
    let ip: String
    let online: Bool
}

/// Preview which computers would be targeted from a CSV file.
struct ArdGroupPreviewSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Preview computers that would be targeted from a CSV file"
    )

    @Argument(help: "Path to CSV file of computer names or IPs")
    var csvFile: String

    func run() async throws {
        let path = (csvFile as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            print("[ERROR] File not found: \(csvFile)".red)
            throw ExitCode.failure
        }
        let computers = try ArdRunner.computersFromCSV(path: path)
        print("\n" + "Computers in \(csvFile)".bold + " (\(computers.count))\n")
        for c in computers { print("  \(c)") }
        print("")
    }
}

/// Ping using system `ping` — 1 packet, 1s timeout.
private func pingOne(_ ip: String) async -> Bool {
    await withCheckedContinuation { cont in
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/sbin/ping")
        t.arguments = ["-c", "1", "-W", "1000", "-t", "1", ip]
        t.standardOutput = FileHandle.nullDevice
        t.standardError  = FileHandle.nullDevice
        t.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
        do { try t.run() } catch { cont.resume(returning: false) }
    }
}

struct ArdGroupListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all computer groups from ReportMate"
    )

    @Option(name: .shortAndLong, help: "Filter groups by name")
    var filter: String?

    func run() async throws {
        let config = try FleetMateConfig.load()
        guard config.isReportMateConfigured else {
            print("[ERROR] ReportMate not configured.".red)
            throw ExitCode.failure
        }
        let rm = ReportMateService(config: config)
        let devices = try await rm.getDevices()
        var groups = Set(devices.map { $0.location }.filter { !$0.isEmpty })
        if let f = filter { groups = groups.filter { $0.lowercased().contains(f.lowercased()) } }
        let sorted = groups.sorted()
        guard !sorted.isEmpty else { print("\nNo groups found.\n".yellow); return }
        print("\n" + "Computer Groups".bold + " (\(sorted.count))\n")
        for g in sorted {
            let count = devices.filter { $0.location == g }.count
            print("  \(g)  " + "(\(count) computers)".dim)
        }
        print("")
    }
}

// MARK: - ard run (custom UNIX command)

/// Run any arbitrary UNIX/shell command on one computer or an entire group via SSH.
struct ArdRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a custom UNIX command on a device or group via SSH",
        discussion: """
            Pass any shell command as a quoted string to execute it over SSH.

            EXAMPLES
              fleetmate ard run \"uptime\" --device Mac-Studio-01
              fleetmate ard run \"df -h /\" --group \"B1122 Studio Lab\"
              fleetmate ard run \"sw_vers\" --group computers.csv --json
            """
    )

    @Argument(help: "Shell command to execute (quote the whole command)")
    var command: String

    @OptionGroup var targeting: ArdTargetOptions

    func run() async throws {
        try await ArdRunner.run(script: command, targeting: targeting)
    }
}

// MARK: - ard vnc

/// Open a macOS Screen Sharing (VNC) connection to a device.
struct ArdVncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vnc",
        abstract: "Open a Screen Sharing (VNC) connection to a device",
        discussion: """
            Resolves the device name, serial, hostname, or IP via ReportMate and opens
            Screen Sharing using a vnc:// URL — without leaving VS Code.

            EXAMPLES
              fleetmate ard vnc Mac-Example-01
              fleetmate ard vnc 10.15.2.15
            """
    )

    @Argument(help: "Device name, serial, hostname, or IP address")
    var device: String

    func run() async throws {
        let config = try FleetMateConfig.load()
        let ssh = SecureShellService(fleetConfig: config)

        do {
            let (ip, deviceRecord) = try await ssh.resolveHost(device)
            let label = deviceRecord?.displayName ?? device
            print("Opening Screen Sharing to \(label) (\(ip))...".cyan)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["vnc://\(ip)"]
            try open.run()
            open.waitUntilExit()
        } catch {
            print("[ERROR] Could not resolve \"\(device)\": \(error.localizedDescription)".red)
            throw ExitCode.failure
        }
    }
}

// MARK: - ard inventory

struct ArdInventoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inventory",
        abstract: "Device inventory scripts",
        subcommands: [
            ArdInventoryIpSubcommand.self,
            ArdInventoryInfoSubcommand.self,
            ArdInventorySerialSubcommand.self,
        ],
        defaultSubcommand: ArdInventoryIpSubcommand.self
    )
}

struct ArdInventoryIpSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: "Get Ethernet and WiFi IP addresses"
    )
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: #"echo ""; echo "Ethernet"; ipconfig getifaddr en0; echo ""; echo "WiFi"; ipconfig getifaddr en1"#,
            targeting: targeting
        )
    }
}

struct ArdInventoryInfoSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "About This Mac: hardware, OS, serial, Munki config, network"
    )
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        system_profiler SPHardwareDataType | egrep "Serial Number|Model|Memory|Processor Name|Processor Speed"
        echo ""; echo "OS version:"; sw_vers
        echo ""; echo "Manifest:"; defaults read /Library/Preferences/ManagedInstalls ClientIdentifier
        echo ""; echo "Repo:"; defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL
        echo ""; echo "Catalog:"; defaults read /Library/Preferences/com.apple.RemoteDesktop Text1
        echo ""; echo "Area:"; defaults read /Library/Preferences/com.apple.RemoteDesktop Text2
        echo ""; echo "Room:"; defaults read /Library/Preferences/com.apple.RemoteDesktop Text3
        echo ""; echo "Ethernet:"; ipconfig getifaddr en0; networksetup -getmacaddress en0 | awk '{print $3}'
        echo ""; echo "WiFi:"; ipconfig getifaddr en1; networksetup -getmacaddress en1 | awk '{print $3}'
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdInventorySerialSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serial",
        abstract: "Get hardware serial number"
    )
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "system_profiler SPHardwareDataType | awk '/Serial/ {print $4}'",
            targeting: targeting
        )
    }
}

// MARK: - ard security

struct ArdSecurityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "security",
        abstract: "Security check and hardening scripts",
        subcommands: [
            ArdSecurityFilevaultSubcommand.self,
            ArdSecuritySshdSubcommand.self,
            ArdSecurityDefenderSubcommand.self,
            ArdSecurityFindAdminSubcommand.self,
            ArdSecurityRootSshSubcommand.self,
        ]
    )
}

struct ArdSecurityFilevaultSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "filevault", abstract: "Check FileVault status")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(script: "/usr/bin/fdesetup status", targeting: targeting)
    }
}

struct ArdSecuritySshdSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sshd", abstract: "Check sshd config for known admin entries")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(script: "cat /etc/ssh/sshd_config | grep ecuadmin", targeting: targeting)
    }
}

struct ArdSecurityDefenderSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "defender", abstract: "Run Microsoft Defender quick scan")
    @OptionGroup var targeting: ArdTargetOptions
    @Flag(name: .long, help: "Run full scan instead of quick scan")
    var full: Bool = false
    func run() async throws {
        let script = full
            ? "/usr/local/bin/mdatp scan full"
            : "/usr/local/bin/mdatp scan quick"
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdSecurityFindAdminSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find-admin", abstract: "Find local admin account (ecuadmin)")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "ls /Users | grep ecuadmin; dscl . -read /Users | grep ecuadmin",
            targeting: targeting
        )
    }
}

struct ArdSecurityRootSshSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "root-ssh", abstract: "Check if root SSH login is enabled")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "sudo systemsetup -getremotelogin",
            targeting: targeting
        )
    }
}

// MARK: - ard updates

struct ArdUpdatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "updates",
        abstract: "Munki software update scripts",
        subcommands: [
            ArdUpdatesCheckSubcommand.self,
            ArdUpdatesInstallSubcommand.self,
            ArdUpdatesPendingSubcommand.self,
        ],
        defaultSubcommand: ArdUpdatesCheckSubcommand.self
    )
}

struct ArdUpdatesCheckSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Check for available Munki updates (no install)")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "/usr/local/munki/managedsoftwareupdate --checkonly",
            targeting: targeting
        )
    }
}

struct ArdUpdatesInstallSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Check and install all pending Munki updates")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "/usr/local/munki/managedsoftwareupdate --checkonly && /usr/local/munki/managedsoftwareupdate --installonly",
            targeting: targeting
        )
    }
}

struct ArdUpdatesPendingSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pending", abstract: "List packages in the Munki install cache (pending installs)")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: #"ls /Library/Managed\ Installs/Cache"#,
            targeting: targeting
        )
    }
}

// MARK: - ard munki

struct ArdMunkiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "munki",
        abstract: "Munki configuration scripts",
        subcommands: [
            ArdMunkiConfigSubcommand.self,
            ArdMunkiManifestSubcommand.self,
        ],
        defaultSubcommand: ArdMunkiConfigSubcommand.self
    )
}

struct ArdMunkiConfigSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Show Munki configuration (repo, manifest, reporting)")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        echo ""; echo "MunkiRepo:"
        defaults read /Library/Preferences/ManagedInstalls.plist SoftwareRepoURL
        echo ""; echo "ClientIdentifier:"
        defaults read /Library/Preferences/ManagedInstalls.plist ClientIdentifier
        echo ""; echo "Python:"
        ls /usr/local/munki/Python.framework/Versions/
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdMunkiManifestSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-manifest", abstract: "Change the Munki ClientIdentifier (manifest)")
    @OptionGroup var targeting: ArdTargetOptions
    @Option(name: .long, help: "New manifest/ClientIdentifier value")
    var manifest: String
    func run() async throws {
        // Note: MunkiPreflight takes priority if present
        let script = "defaults write /Library/Preferences/ManagedInstalls ClientIdentifier \"\(manifest)\""
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

// MARK: - ard upkeep

struct ArdUpkeepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upkeep",
        abstract: "General maintenance and upkeep scripts",
        subcommands: [
            ArdUpkeepRebootSubcommand.self,
            ArdUpkeepLogoutSubcommand.self,
            ArdUpkeepStorageSubcommand.self,
            ArdUpkeepRunningAppsSubcommand.self,
            ArdUpkeepKillNudgeSubcommand.self,
            ArdUpkeepFixAdminPermsSubcommand.self,
        ]
    )
}

struct ArdUpkeepRebootSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reboot", abstract: "Reboot the target machine(s) immediately")
    @OptionGroup var targeting: ArdTargetOptions
    @Flag(name: .long, help: "Confirm: this will immediately restart the machine(s)")
    var confirm: Bool = false
    func run() async throws {
        guard confirm else {
            print("[WARNING] This will immediately reboot target device(s). Add --confirm to proceed.".yellow)
            throw ExitCode.failure
        }
        try await ArdRunner.run(script: "/sbin/shutdown -r now", targeting: targeting)
    }
}

struct ArdUpkeepLogoutSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Log out the current user")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = #"WindowServer="$(ps -axc | grep WindowServer | awk '{print $1}')"; kill -HUP $WindowServer"#
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdUpkeepStorageSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "storage", abstract: "Check available storage space")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        system_profiler SPStorageDataType | grep "Free" | awk '{print $2}' | head -1
        system_profiler SPStorageDataType | grep "Available" | awk '{print $2}' | head -1
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdUpkeepRunningAppsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "running-apps", abstract: "List visible running applications")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: #"osascript -e 'tell application "System Events" to set quitapps to name of every application process whose visible is true and name is not "Finder"'"#,
            targeting: targeting
        )
    }
}

struct ArdUpkeepKillNudgeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill-nudge", abstract: "Kill the Nudge process and remove the app")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "killall Nudge; rm -rf /Applications/Utilities/Nudge.app",
            targeting: targeting
        )
    }
}

struct ArdUpkeepFixAdminPermsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fix-admin-perms", abstract: "Fix permissions on the local admin home folder")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        /usr/sbin/chown -R admin:staff /Users/admin/
        /bin/chmod -R 700 /Users/admin/
        /bin/chmod -R 755 /Users/admin/Public
        /bin/chmod 755 /Users/admin
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

// MARK: - ard users

struct ArdUsersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "users",
        abstract: "User account management scripts",
        subcommands: [
            ArdUsersAdminsSubcommand.self,
        ],
        defaultSubcommand: ArdUsersAdminsSubcommand.self
    )
}

struct ArdUsersAdminsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "admins", abstract: "List members of the local admin group")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(script: "dscl . -read /Groups/admin", targeting: targeting)
    }
}

// MARK: - ard profiles

struct ArdProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Configuration profile scripts",
        subcommands: [
            ArdProfilesListSubcommand.self,
        ],
        defaultSubcommand: ArdProfilesListSubcommand.self
    )
}

struct ArdProfilesListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all installed configuration profiles")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "/usr/bin/profiles -P | cut -d' ' -f4",
            targeting: targeting
        )
    }
}

// MARK: - ard dock

struct ArdDockCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock",
        abstract: "Dock management scripts (dockutil)",
        subcommands: [
            ArdDockListSubcommand.self,
            ArdDockFixStudentSubcommand.self,
            ArdDockSetAdminSubcommand.self,
        ],
        defaultSubcommand: ArdDockListSubcommand.self
    )
}

struct ArdDockListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List current Dock items")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(script: "/usr/local/bin/dockutil --list", targeting: targeting)
    }
}

struct ArdDockFixStudentSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fix-student", abstract: "Run the student Dock outset script")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "/usr/local/outset/login-every/StudentDock.sh",
            targeting: targeting
        )
    }
}

struct ArdDockSetAdminSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-admin", abstract: "Set the standard admin Dock layout")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        /usr/local/bin/dockutil --remove all --no-restart
        /usr/local/bin/dockutil --add /Applications/System\\ Preferences.app --no-restart
        /usr/local/bin/dockutil --add /Applications/Managed\\ Software\\ Center.app --no-restart
        /usr/local/bin/dockutil --add /Applications/Safari.app --no-restart
        /usr/local/bin/dockutil --add /Applications/Utilities/Terminal.app --no-restart
        /usr/local/bin/dockutil --add /Applications/Utilities/Console.app --no-restart
        defaults write com.apple.dock autohide -bool false
        killall Dock
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

// MARK: - ard printing

struct ArdPrintingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "printing",
        abstract: "Printer management scripts",
        subcommands: [
            ArdPrintingListSubcommand.self,
            ArdPrintingRemoveEcuSubcommand.self,
        ],
        defaultSubcommand: ArdPrintingListSubcommand.self
    )
}

struct ArdPrintingListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed printers")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(script: "lpstat -p | cut -d' ' -f2", targeting: targeting)
    }
}

struct ArdPrintingRemoveEcuSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-ecu", abstract: "Remove all ECU_ printers")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: "lpstat -p | cut -d' ' -f2 | grep ECU_ | xargs -n1 sudo lpadmin -x",
            targeting: targeting
        )
    }
}

// MARK: - ard enrollment

struct ArdEnrollmentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enrollment",
        abstract: "MDM enrollment check scripts",
        subcommands: [
            ArdEnrollmentDepSubcommand.self,
            ArdEnrollmentBootstrapTokenSubcommand.self,
        ],
        defaultSubcommand: ArdEnrollmentDepSubcommand.self
    )
}

struct ArdEnrollmentDepSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dep", abstract: "Check DEP/Apple School Manager enrollment status")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        echo ""
        if [[ $(profiles show -type enrollment | grep ConfigurationURL) ]]; then
          echo "Device in School Manager"
        else
          echo "Device NOT in School Manager"
        fi
        profiles status -type enrollment | grep DEP
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdEnrollmentBootstrapTokenSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bootstrap-token", abstract: "Check bootstrap token and secure token status")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        let script = """
        echo ""
        profiles status -type bootstraptoken
        echo ""
        dscl . list /Users | grep -v '_' | xargs -I {} sysadminctl -secureTokenStatus {}
        echo ""
        diskutil apfs listUsers /
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

// MARK: - ard logs

struct ArdLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Log reading scripts",
        subcommands: [
            ArdLogsMunkiInstallSubcommand.self,
            ArdLogsMunkiUpdateSubcommand.self,
            ArdLogsSystemSubcommand.self,
        ],
        defaultSubcommand: ArdLogsMunkiInstallSubcommand.self
    )
}

struct ArdLogsMunkiInstallSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "munki-install", abstract: "Read today's Munki install log")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: #"cat /Library/Managed\ Installs/Logs/Install.log | grep "$(date +'%b %d %Y')""#,
            targeting: targeting
        )
    }
}

struct ArdLogsMunkiUpdateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "munki-update", abstract: "Read today's Munki managed software update log")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(
            script: #"cat /Library/Managed\ Installs/Logs/ManagedSoftwareUpdate.log | grep "$(date +'%b %d %Y')""#,
            targeting: targeting
        )
    }
}

struct ArdLogsSystemSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "system", abstract: "Read system.log")
    @OptionGroup var targeting: ArdTargetOptions
    func run() async throws {
        try await ArdRunner.run(script: "cat /var/log/system.log | tail -50", targeting: targeting)
    }
}

// MARK: - ard macos

struct ArdMacOSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macos",
        abstract: "macOS update and reinstall scripts",
        subcommands: [
            ArdMacOSUpdateSubcommand.self,
            ArdMacOSEraseInstallSubcommand.self,
        ]
    )
}

struct ArdMacOSUpdateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Reinstall macOS in-place via erase-install (no data loss)"
    )
    @OptionGroup var targeting: ArdTargetOptions
    @Flag(name: .long, help: "Required: confirms you want to trigger a macOS reinstall")
    var confirm: Bool = false
    func run() async throws {
        guard confirm else {
            print("[WARNING] This will trigger a macOS reinstall. Add --confirm to proceed.".yellow)
            throw ExitCode.failure
        }
        let script = """
        curl -s -L https://raw.githubusercontent.com/grahampugh/erase-install/master/erase-install.sh -o /tmp/EraseInstall.sh
        chmod +x /tmp/EraseInstall.sh
        sudo bash /tmp/EraseInstall.sh --reinstall --depnotify --overwrite
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}

struct ArdMacOSEraseInstallSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "erase-install",
        abstract: "[DANGER] WIPE and reinstall macOS — ALL DATA WILL BE ERASED"
    )
    @OptionGroup var targeting: ArdTargetOptions
    @Flag(name: .long, help: "Required: confirms you understand ALL DATA WILL BE ERASED")
    var confirm: Bool = false
    func run() async throws {
        guard confirm else {
            print("[DANGER] THIS WILL ERASE ALL DATA ON THE TARGET MACHINE(S).".red.bold)
            print("    Add --confirm only if you are absolutely certain.".red)
            throw ExitCode.failure
        }
        let script = """
        echo "ERASING COMPUTER — THIS IS IRREVERSIBLE"
        curl -s -L https://raw.githubusercontent.com/grahampugh/erase-install/master/erase-install.sh -o /tmp/EraseInstall.sh
        chmod +x /tmp/EraseInstall.sh
        sudo bash /tmp/EraseInstall.sh --erase --depnotify --overwrite
        """
        try await ArdRunner.run(script: script, targeting: targeting)
    }
}
