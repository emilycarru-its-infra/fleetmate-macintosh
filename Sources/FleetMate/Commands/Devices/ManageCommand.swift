import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

/// `fleetmate manage`: the Manage tab's roster, scanner, runner and
/// library from the command line, sharing the same Core services.
struct ManageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manage",
        abstract: "Lab operations over SSH: rooms, scans, fleet commands, the command library",
        discussion: """
            Reads the enrollment roster the Manage tab uses (the manage block in
            ~/.fleetmate/config.yaml, or the Munki repo's deployment/enroll/computers.csv),
            resolves machines through ReportMate and mDNS, and runs commands over the
            fleet SSH key.
            """,
        subcommands: [
            ManageRoomsSubcommand.self,
            ManageScanSubcommand.self,
            ManageRunSubcommand.self,
            ManageLibrarySubcommand.self,
            ManageAuditSubcommand.self,
            ManageImportScanLabSubcommand.self,
        ],
        defaultSubcommand: ManageRoomsSubcommand.self
    )
}

// MARK: - Shared

enum ManageCli {
    static func manageConfig(_ config: FleetMateConfig) -> ManageConfig {
        config.manage ?? ManageConfig()
    }

    static func loadRoster(_ config: FleetMateConfig) throws -> (roster: FleetRoster, path: String) {
        let manage = manageConfig(config)
        let path = manage.resolvedRosterPath(repoRoot: config.repoRoot)
        guard !path.isEmpty else {
            print("[ERROR] No roster path. Set manage.roster_path in ~/.fleetmate/config.yaml or configure the Munki repo root.".red)
            throw ExitCode.failure
        }
        let roster = try RosterLoader(includeRetired: manage.includeRetired, includeProvisioning: manage.includeProvisioning).load(path: path)
        return (roster, path)
    }

    /// Find a sidebar room by its key, case-insensitively, in any section.
    static func room(named name: String, in roster: FleetRoster) -> RosterRoom? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return roster.allRooms.first { $0.number.lowercased() == wanted }
            ?? roster.allRooms.first { $0.number.lowercased().hasPrefix(wanted) }
            ?? roster.allRooms.first { ($0.displayName ?? "").lowercased() == wanted }
    }

    static func scanner(_ config: FleetMateConfig) -> HostScanner {
        let manage = manageConfig(config)
        let directory: DeviceDirectory? = config.isReportMateConfigured
            ? ReportMateDeviceDirectory(service: ReportMateService(config: config)) : nil
        return HostScanner(directory: directory, probe: NetworkReachabilityProbe(), concurrency: max(4, manage.probeConcurrency))
    }

    static func executor(_ config: FleetMateConfig) -> SecureShellService {
        SecureShellService(config: manageConfig(config).toSecureShellConfig(), reportMate: nil)
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func stateLabel(_ result: HostScanResult?) -> String {
        guard let result else { return "unresolved" }
        switch result.state {
        case .unresolved: return "unresolved"
        case .unreachable: return "unreachable"
        case .online:
            var ports: [String] = []
            if result.sshOpen { ports.append("ssh") }
            if result.screenSharingOpen { ports.append("vnc") }
            return "online (\(ports.joined(separator: ",")))"
        }
    }
}

// MARK: - rooms

struct ManageRoomsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rooms", abstract: "List the roster's rooms and groups")

    @Option(name: .long, help: "Section: labs, kiosks, staff, faculty (default: all)")
    var section: String?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    struct RoomRow: Encodable {
        var section: String
        var key: String
        var name: String?
        var machines: Int
    }

    func run() async throws {
        let config = try FleetMateConfig.load()
        let (roster, path) = try ManageCli.loadRoster(config)
        var rows: [RoomRow] = []
        func add(_ section: String, _ rooms: [RosterRoom]) {
            guard self.section == nil || self.section?.lowercased() == section else { return }
            rows += rooms.map { RoomRow(section: section, key: $0.number, name: $0.displayName, machines: $0.count) }
        }
        add("labs", roster.labs)
        add("kiosks", roster.kiosks)
        add("staff", roster.staff)
        add("faculty", roster.faculty)

        if json {
            try ManageCli.printJSON(rows)
            return
        }
        print("Roster: \(path)".lightBlack)
        var current = ""
        for row in rows {
            if row.section != current {
                current = row.section
                print("\n" + current.uppercased().bold)
            }
            let name = row.name.map { "  \($0)" } ?? ""
            print("  \(row.key.col(32)) \(String(row.machines).col(5))\(name)")
        }
        print("\n\(roster.allComputers.count) machines in \(rows.count) rooms".lightBlack)
    }
}

// MARK: - scan

struct ManageScanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "Resolve a room's machines and see who is online")

    @Argument(help: "Room key (lab, kiosk room, staff area, faculty letter)")
    var room: String

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    struct ScanRow: Encodable {
        var serial: String
        var hostname: String
        var name: String
        var ip: String
        var source: String
        var state: String
        var sshOpen: Bool
        var screenSharingOpen: Bool
    }

    func run() async throws {
        let config = try FleetMateConfig.load()
        let (roster, _) = try ManageCli.loadRoster(config)
        guard let target = ManageCli.room(named: room, in: roster) else {
            print("[ERROR] No room named \(room). Try: fleetmate manage rooms".red)
            throw ExitCode.failure
        }
        if !json { print("Scanning \(target.name) (\(target.count) machines)…".cyan) }
        let (results, summary) = await ManageCli.scanner(config).scan(target.computers) { progress in
            if !json, !progress.status.isEmpty { FileHandle.standardError.write(Data("  \(progress.status)\n".utf8)) }
        }
        let rows = target.computers.map { c -> ScanRow in
            let r = results[c.id]
            return ScanRow(serial: c.serial, hostname: c.hostname, name: c.friendlyName, ip: r?.ip ?? "",
                           source: r?.source.rawValue ?? "none", state: ManageCli.stateLabel(r),
                           sshOpen: r?.sshOpen ?? false, screenSharingOpen: r?.screenSharingOpen ?? false)
        }
        if json {
            try ManageCli.printJSON(rows)
            return
        }
        print("")
        for row in rows {
            let state = row.state.hasPrefix("online") ? row.state.green : (row.state == "unreachable" ? row.state.yellow : row.state.lightBlack)
            print("  \(row.hostname.isEmpty ? row.name : row.hostname).col(28) \(row.ip.col(16)) \(state)")
        }
        print("\n\(summary.online) online of \(summary.total), \(summary.resolved) resolved (\(summary.mode.label)) in \(String(format: "%.1f", summary.duration))s".lightBlack)
    }
}

// MARK: - run

struct ManageRunSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a library command or a literal script on every online machine in a room",
        discussion: """
            The command argument is a library label ("Uptime", "Munki check only") or a
            literal shell script. Caution and destructive commands ask before running
            unless --yes is given. Output streams per machine as it arrives.
            """
    )

    @Argument(help: "Room key")
    var room: String

    @Argument(help: "Library label or literal command")
    var command: String

    @Flag(name: .shortAndLong, help: "Skip the confirmation for caution and destructive commands")
    var yes: Bool = false

    @Option(name: .long, help: "Parallel SSH sessions (default: the Manage setting)")
    var concurrent: Int?

    @Option(name: .shortAndLong, help: "SSH user (default: the Manage setting)")
    var user: String?

    @Flag(name: .long, help: "Output as JSON, one object per machine, after the run")
    var json: Bool = false

    struct RunRow: Encodable {
        var serial: String
        var hostname: String
        var ip: String
        var status: String
        var exitCode: Int32?
        var output: String
        var error: String
        var seconds: Double?
    }

    func run() async throws {
        let config = try FleetMateConfig.load()
        let manage = ManageCli.manageConfig(config)
        let (roster, _) = try ManageCli.loadRoster(config)
        guard let target = ManageCli.room(named: room, in: roster) else {
            print("[ERROR] No room named \(room). Try: fleetmate manage rooms".red)
            throw ExitCode.failure
        }

        let library = ManageStateStore().loadCommandLibrary(path: manage.commandsPath.isEmpty ? nil : manage.resolvedCommandsPath).categories
        let script: String
        let label: String
        let trust: CommandTrustLevel
        if let entry = CommandLibrary.find(label: command, in: library) {
            script = entry.command
            label = entry.label
            trust = entry.trustLevel
        } else {
            script = command
            label = command
            trust = CommandTrustLevel.inferred(from: command)
        }
        if let template = PlaceholderTemplate.detect(label: label, command: script) {
            print("[ERROR] \(label) needs values for \(template.placeholders.joined(separator: ", ")); run it from the app.".red)
            throw ExitCode.failure
        }

        if !json { print("Scanning \(target.name)…".cyan) }
        let (results, _) = await ManageCli.scanner(config).scan(target.computers)
        let targets = target.computers.compactMap { c -> CommandRunner.Target? in
            guard let r = results[c.id], r.isOnline else { return nil }
            return CommandRunner.Target(computer: c, ip: r.ip)
        }
        guard !targets.isEmpty else {
            print("No machines online in \(target.name).".yellow)
            throw ExitCode.failure
        }

        if trust != .safe && !yes {
            print("\(trust.warningTitle) \(label)".yellow.bold)
            print(trust.warningMessage)
            print("Targets: \(targets.count) online machine\(targets.count == 1 ? "" : "s") in \(target.name)")
            print("Type yes to continue: ", terminator: "")
            guard let answer = readLine(), answer.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                print("Cancelled.")
                throw ExitCode.failure
            }
        }

        if !json { print("Running \(label) on \(targets.count) machine\(targets.count == 1 ? "" : "s")…\n".cyan) }
        let runner = CommandRunner(
            executor: ManageCli.executor(config),
            concurrency: max(1, concurrent ?? manage.probeConcurrency),
            username: user ?? manage.resolvedSshUser,
            timeout: 300)
        let collector = RunCollector(targets: targets)
        await runner.run(script: script, on: targets) { event in
            collector.apply(event, live: !json)
        }
        let rows = collector.rows()
        if json {
            try ManageCli.printJSON(rows)
        } else {
            let ok = rows.filter { $0.status == "success" }.count
            print("\n\(ok) succeeded, \(rows.count - ok) did not".lightBlack)
        }
        if rows.contains(where: { $0.status != "success" }) { throw ExitCode.failure }
    }

    /// Gathers per-host output from runner events and prints lines as they arrive.
    final class RunCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: CommandRunResult] = [:]
        private var order: [String] = []
        private var pendingLine: [String: String] = [:]

        init(targets: [CommandRunner.Target]) {
            for t in targets {
                results[t.computer.id] = CommandRunResult(computer: t.computer, ip: t.ip)
                order.append(t.computer.id)
            }
        }

        func apply(_ event: CommandRunner.Event, live: Bool) {
            lock.withLock {
                switch event {
                case .started(let serial):
                    results[serial]?.status = .running
                    results[serial]?.startTime = Date()
                case .output(let serial, let chunk):
                    results[serial]?.output += chunk
                    guard live, let name = results[serial]?.computer.displayName else { return }
                    var buffer = (pendingLine[serial] ?? "") + chunk
                    while let newline = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newline])
                        buffer = String(buffer[buffer.index(after: newline)...])
                        print("\(name.cyan): \(line)")
                    }
                    pendingLine[serial] = buffer
                case .finished(let serial, let result):
                    guard var r = results[serial] else { return }
                    if live, let rest = pendingLine[serial], !rest.isEmpty { print("\(r.computer.displayName.cyan): \(rest)") }
                    r.errorOutput = result.stderr
                    r.exitCode = result.exitCode
                    r.endTime = Date()
                    r.status = CommandRunStatus(outcome: result.outcome, exitCode: result.exitCode)
                    results[serial] = r
                    if live {
                        let tag = r.status == .success ? r.status.label.green : r.status.label.red
                        let err = result.stderr.isEmpty ? "" : "  \(result.stderr.split(separator: "\n").first ?? "")"
                        print("\(r.computer.displayName.cyan): [\(tag)]\(err)")
                    }
                case .cancelled(let serial):
                    results[serial]?.status = .cancelled
                    results[serial]?.endTime = Date()
                }
            }
        }

        func rows() -> [RunRow] {
            lock.withLock {
                order.compactMap { serial in
                    guard let r = results[serial] else { return nil }
                    return RunRow(serial: r.computer.serial, hostname: r.computer.hostname, ip: r.ip,
                                  status: r.status == .success ? "success" : r.status.label.lowercased(),
                                  exitCode: r.exitCode, output: r.output, error: r.errorOutput, seconds: r.duration)
                }
            }
        }
    }
}

// MARK: - library

struct ManageLibrarySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "library", abstract: "List the command library")

    @Flag(name: .long, help: "List the library bundled with FleetMate rather than the operator's copy")
    var bundled: Bool = false

    @Option(name: .long, help: "Only this category")
    var category: String?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    struct LibraryRow: Encodable {
        var category: String
        var label: String
        var command: String
        var trust: String
    }

    func run() async throws {
        let config = try FleetMateConfig.load()
        let manage = ManageCli.manageConfig(config)
        let categories: [CommandCategory]
        let source: String
        if bundled {
            categories = CommandLibrary.loadBundled()
            source = "bundled"
        } else {
            let store = ManageStateStore()
            let path = manage.commandsPath.isEmpty ? nil : manage.resolvedCommandsPath
            categories = store.loadCommandLibrary(path: path).categories
            source = path ?? store.commandsPath
        }
        let filtered = categories.filter { category == nil || $0.name.lowercased() == category!.lowercased() }
        let rows = filtered.flatMap { cat in cat.commands.map { LibraryRow(category: cat.name, label: $0.label, command: $0.command, trust: $0.trustLevel.rawValue) } }
        if json {
            try ManageCli.printJSON(rows)
            return
        }
        print("Library: \(source)".lightBlack)
        for cat in filtered {
            print("\n" + cat.name.bold)
            for cmd in cat.commands {
                let trust: String
                switch cmd.trustLevel {
                case .safe: trust = "safe".green
                case .caution: trust = "caution".yellow
                case .destructive: trust = "destructive".red
                }
                print("  \(cmd.label.col(44)) \(trust.col(22)) \(cmd.command.prefix(70))")
            }
        }
        print("\n\(rows.count) commands in \(filtered.count) categories".lightBlack)
    }
}

// MARK: - audit

struct ManageAuditSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit", abstract: "Check a command library for problems (non-zero exit on errors)")

    @Argument(help: "YAML path (default: the operator's library; --bundled for the shipped one)")
    var path: String?

    @Flag(name: .long, help: "Audit the library bundled with FleetMate")
    var bundled: Bool = false

    func run() async throws {
        let categories: [CommandCategory]
        let source: String
        if bundled {
            categories = CommandLibrary.loadBundled()
            source = "bundled"
        } else {
            let config = try FleetMateConfig.load()
            let manage = ManageCli.manageConfig(config)
            source = path.map { NSString(string: $0).expandingTildeInPath } ?? (manage.commandsPath.isEmpty ? ManageStateStore().commandsPath : manage.resolvedCommandsPath)
            categories = try CommandLibrary.load(path: source)
        }
        let issues = CommandLibrary.audit(categories)
        let count = categories.reduce(0) { $0 + $1.commands.count }
        print("Audited \(count) commands in \(categories.count) categories (\(source))".lightBlack)
        for issue in issues.sorted(by: { $0.severity > $1.severity }) {
            let tag: String
            switch issue.severity {
            case .error: tag = "error".red
            case .warning: tag = "warning".yellow
            case .info: tag = "info".lightBlack
            }
            let location = issue.label.isEmpty ? issue.category : "\(issue.category) / \(issue.label)"
            print("  [\(tag)] \(location): \(issue.message)")
        }
        let errors = issues.filter { $0.severity == .error }.count
        if issues.isEmpty {
            print("Clean.".green)
        } else {
            print("\(errors) error\(errors == 1 ? "" : "s"), \(issues.count - errors) other".lightBlack)
        }
        if errors > 0 { throw ExitCode.failure }
    }
}

// MARK: - import-scanlab

struct ManageImportScanLabSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-scanlab",
        abstract: "Bring ScanLab's custom groups, history and added commands into FleetMate")

    func run() async throws {
        let importer = ScanLabImport()
        guard importer.hasSource else {
            print("Nothing to import: no ScanLab preferences or library on this Mac.".lightBlack)
            return
        }
        let report = importer.run()
        print(report.summary)
        if let path = report.libraryPath { print("Library: \(path)".lightBlack) }
    }
}
