import Foundation

/// The agent command-line tools FleetMate keeps current.
public enum AgentCli: String, CaseIterable, Codable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    /// The npm package a global npm install comes from.
    public var npmPackage: String {
        switch self {
        case .codex: return "@openai/codex"
        case .claude: return "@anthropic-ai/claude-code"
        }
    }
}

/// How an agent CLI got onto this Mac, read from where its binary really is.
public enum AgentCliInstallMethod: String, Codable, Sendable {
    case homebrewCask
    case homebrewFormula
    case npm
    case claudeNative
    case unknown

    public var displayName: String {
        switch self {
        case .homebrewCask: return "Homebrew cask"
        case .homebrewFormula: return "Homebrew formula"
        case .npm: return "npm global"
        case .claudeNative: return "Claude native installer"
        case .unknown: return "Unknown"
        }
    }
}

/// Where one installed CLI is and how to update it.
public struct AgentCliInstall: Codable, Sendable, Equatable {
    public var cli: AgentCli
    /// The path found on PATH (often a symlink).
    public var path: String
    /// `path` with every symlink resolved.
    public var resolvedPath: String
    public var method: AgentCliInstallMethod
    /// The cask or formula token, or the npm package.
    public var package: String?
    /// The Homebrew or npm prefix the install lives under, so the update uses
    /// the same tool that installed it.
    public var prefix: String?

    public init(cli: AgentCli, path: String, resolvedPath: String, method: AgentCliInstallMethod,
                package: String? = nil, prefix: String? = nil) {
        self.cli = cli
        self.path = path
        self.resolvedPath = resolvedPath
        self.method = method
        self.package = package
        self.prefix = prefix
    }
}

/// One process to run as part of an update.
public struct AgentCliCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public var display: String { ([executable] + arguments).joined(separator: " ") }
}

/// What the updater knows about one CLI, kept between runs.
public struct AgentCliStatus: Codable, Sendable, Equatable {
    public var cli: AgentCli
    public var installed: Bool
    public var path: String?
    public var method: AgentCliInstallMethod?
    public var version: String?
    public var latestVersion: String?
    public var lastChecked: Date?
    public var lastUpdated: Date?
    /// A neutral one-line note on the last attempt: "Up to date", "Updated
    /// 0.161.0 → 0.162.1", "Update failed: …", "Not installed".
    public var message: String?

    public init(cli: AgentCli, installed: Bool, path: String? = nil, method: AgentCliInstallMethod? = nil,
                version: String? = nil, latestVersion: String? = nil, lastChecked: Date? = nil,
                lastUpdated: Date? = nil, message: String? = nil) {
        self.cli = cli
        self.installed = installed
        self.path = path
        self.method = method
        self.version = version
        self.latestVersion = latestVersion
        self.lastChecked = lastChecked
        self.lastUpdated = lastUpdated
        self.message = message
    }
}

/// The saved state the app and the `fleetmate agent update` command share.
public struct AgentCliUpdateState: Codable, Sendable, Equatable {
    public var lastChecked: Date?
    public var statuses: [AgentCliStatus]

    public init(lastChecked: Date? = nil, statuses: [AgentCliStatus] = []) {
        self.lastChecked = lastChecked
        self.statuses = statuses
    }

    public static var defaultPath: String { AppEdition.current.supportPath("agent-cli-updates.json") }

    public static func load(from path: String = defaultPath) -> AgentCliUpdateState {
        guard let data = FileManager.default.contents(atPath: path) else { return AgentCliUpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AgentCliUpdateState.self, from: data)) ?? AgentCliUpdateState()
    }

    public func save(to path: String = defaultPath) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// True when no check has run within `interval`.
    public func isStale(now: Date = Date(), interval: TimeInterval = AgentCliUpdater.checkInterval) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }
}

/// Keeps `codex` and `claude` at their latest versions without anyone
/// watching: finds each CLI, works out how it was installed from where its
/// binary really lives, and updates it with that same tool, non-interactively.
///
/// It never installs a CLI that is not there, never uses sudo, and never
/// waits on input (every child gets /dev/null for stdin). The process runner
/// and file checks are injected so the decisions are testable.
public struct AgentCliUpdater: Sendable {
    public typealias Runner = @Sendable (AgentCliCommand) async -> ProcessOutput

    /// How often the app checks on its own.
    public static let checkInterval: TimeInterval = 6 * 60 * 60

    public let home: String
    public let runner: Runner
    public let isExecutable: @Sendable (String) -> Bool
    public let resolveLinks: @Sendable (String) -> String
    public let log: @Sendable (String) -> Void

    public init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        run: @escaping Runner = AgentCliUpdater.defaultRunner,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        resolveLinks: @escaping @Sendable (String) -> String = AgentCliUpdater.realpath,
        log: @escaping @Sendable (String) -> Void = { dbg.info($0, category: "agent-update") }
    ) {
        self.home = home
        self.runner = run
        self.isExecutable = isExecutable
        self.resolveLinks = resolveLinks
        self.log = log
    }

    public static let defaultRunner: Runner = { command in
        var env = ProcessInfo.processInfo.environment
        for (k, v) in command.environment { env[k] = v }
        return await ProcessRunner.run(command.executable, command.arguments, environment: env)
    }

    public static func realpath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Finding the CLIs

    /// Folders a login shell puts on PATH, in the order it searches them.
    public func searchFolders() -> [String] {
        ["\(home)/.local/bin", "\(home)/bin", "\(home)/.npm-global/bin", "\(home)/.claude/local",
         "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The first `cli` binary in the usual folders, else whatever a login
    /// shell finds (nvm and other version managers live only there).
    public func locate(_ cli: AgentCli) async -> String? {
        for folder in searchFolders() where isExecutable("\(folder)/\(cli.rawValue)") {
            return "\(folder)/\(cli.rawValue)"
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let out = await runner(AgentCliCommand(shell, ["-l", "-c", "command -v \(cli.rawValue)"]))
        let found = out.stdout.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard out.succeeded, let found, found.hasPrefix("/") else { return nil }
        return found
    }

    /// The install method for a binary at `resolvedPath`, from its location:
    /// Homebrew keeps casks under `Caskroom/<token>/` and formulae under
    /// `Cellar/<name>/`; npm under `lib/node_modules/<package>/`; Claude
    /// Code's native installer under `~/.local/share/claude/versions/`.
    public static func detect(cli: AgentCli, path: String, resolvedPath: String, home: String) -> AgentCliInstall {
        let parts = resolvedPath.split(separator: "/").map(String.init)
        func token(after marker: String) -> (token: String, prefix: String)? {
            guard let i = parts.firstIndex(of: marker), i + 1 < parts.count else { return nil }
            return (parts[i + 1], "/" + parts[..<i].joined(separator: "/"))
        }
        if let cask = token(after: "Caskroom") {
            return AgentCliInstall(cli: cli, path: path, resolvedPath: resolvedPath,
                                   method: .homebrewCask, package: cask.token, prefix: cask.prefix)
        }
        if let formula = token(after: "Cellar") {
            return AgentCliInstall(cli: cli, path: path, resolvedPath: resolvedPath,
                                   method: .homebrewFormula, package: formula.token, prefix: formula.prefix)
        }
        if let i = parts.firstIndex(of: "node_modules"), i + 1 < parts.count {
            // `lib/node_modules` under a global prefix; the npm beside it
            // is the one that installed the package.
            let prefixParts = parts[..<i].last == "lib" ? parts[..<(i - 1)] : parts[..<i]
            let package = parts[i + 1].hasPrefix("@") && i + 2 < parts.count
                ? parts[i + 1] + "/" + parts[i + 2] : parts[i + 1]
            // Claude's old "local" installer is an npm tree under ~/.claude/local.
            if cli == .claude, resolvedPath.hasPrefix("\(home)/.claude/local/") {
                return AgentCliInstall(cli: cli, path: path, resolvedPath: resolvedPath, method: .claudeNative)
            }
            return AgentCliInstall(cli: cli, path: path, resolvedPath: resolvedPath, method: .npm,
                                   package: package, prefix: "/" + prefixParts.joined(separator: "/"))
        }
        if cli == .claude,
           resolvedPath.hasPrefix("\(home)/.local/share/claude/") || resolvedPath.hasPrefix("\(home)/.claude/") {
            return AgentCliInstall(cli: cli, path: path, resolvedPath: resolvedPath, method: .claudeNative)
        }
        return AgentCliInstall(cli: cli, path: path, resolvedPath: resolvedPath, method: .unknown)
    }

    /// `brew` for a Homebrew prefix: the one inside it, so an Intel and an
    /// Apple silicon Homebrew on the same Mac each update their own installs.
    func brew(for install: AgentCliInstall) -> String {
        if let prefix = install.prefix, isExecutable("\(prefix)/bin/brew") { return "\(prefix)/bin/brew" }
        return isExecutable("/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
    }

    func npm(for install: AgentCliInstall) -> String {
        if let prefix = install.prefix, isExecutable("\(prefix)/bin/npm") { return "\(prefix)/bin/npm" }
        return "npm"
    }

    /// Homebrew settings for an unattended run: no implicit `brew update`
    /// (the updater runs one itself, once), no hints, no prompts.
    public static let brewEnvironment: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
        "NONINTERACTIVE": "1",
        "CI": "1",
    ]

    /// The refresh to run once before any Homebrew upgrade, or nil.
    public func refreshCommand(for install: AgentCliInstall) -> AgentCliCommand? {
        switch install.method {
        case .homebrewCask, .homebrewFormula:
            return AgentCliCommand(brew(for: install), ["update", "--quiet"], environment: Self.brewEnvironment)
        default:
            return nil
        }
    }

    /// The command that updates `install` in place, or nil when FleetMate
    /// cannot update it safely (an unknown install method).
    public func updateCommand(for install: AgentCliInstall) -> AgentCliCommand? {
        switch install.method {
        case .homebrewCask:
            guard let token = install.package else { return nil }
            return AgentCliCommand(brew(for: install), ["upgrade", "--cask", token], environment: Self.brewEnvironment)
        case .homebrewFormula:
            guard let name = install.package else { return nil }
            return AgentCliCommand(brew(for: install), ["upgrade", "--formula", name], environment: Self.brewEnvironment)
        case .npm:
            let package = install.package ?? install.cli.npmPackage
            return AgentCliCommand(npm(for: install), ["install", "--global", "--no-fund", "--no-audit", "\(package)@latest"],
                                   environment: ["npm_config_yes": "true", "npm_config_update_notifier": "false"])
        case .claudeNative:
            return AgentCliCommand(install.path, ["update"], environment: ["CI": "1"])
        case .unknown:
            return nil
        }
    }

    /// The command that reports the newest available version, or nil where
    /// that cannot be asked cheaply (the native installer checks for itself).
    public func latestVersionCommand(for install: AgentCliInstall) -> AgentCliCommand? {
        switch install.method {
        case .homebrewCask:
            guard let token = install.package else { return nil }
            return AgentCliCommand(brew(for: install), ["info", "--json=v2", "--cask", token], environment: Self.brewEnvironment)
        case .homebrewFormula:
            guard let name = install.package else { return nil }
            return AgentCliCommand(brew(for: install), ["info", "--json=v2", "--formula", name], environment: Self.brewEnvironment)
        case .npm:
            return AgentCliCommand(npm(for: install), ["view", install.package ?? install.cli.npmPackage, "version"])
        case .claudeNative, .unknown:
            return nil
        }
    }

    /// The newest version in a `brew info --json=v2` or `npm view` answer.
    public static func parseLatest(_ output: String, method: AgentCliInstallMethod) -> String? {
        switch method {
        case .homebrewCask, .homebrewFormula:
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let cask = (json["casks"] as? [[String: Any]])?.first { return cask["version"] as? String }
            if let formula = (json["formulae"] as? [[String: Any]])?.first,
               let versions = formula["versions"] as? [String: Any] {
                return versions["stable"] as? String
            }
            return nil
        case .npm:
            let v = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        default:
            return nil
        }
    }

    /// The first dotted version number in `--version` output:
    /// "codex-cli 0.162.1" → 0.162.1, "2.1.296 (Claude Code)" → 2.1.296.
    public static func parseVersion(_ output: String) -> String? {
        for word in output.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" }) {
            let w = word.hasPrefix("v") ? word.dropFirst() : Substring(word)
            let pieces = w.split(separator: ".", omittingEmptySubsequences: false)
            if pieces.count >= 2, pieces.allSatisfy({ !$0.isEmpty }), pieces[0].allSatisfy(\.isNumber),
               pieces[1].allSatisfy(\.isNumber) {
                return String(w)
            }
        }
        return nil
    }

    // MARK: - Running

    /// Find each CLI and how it is installed.
    public func installs() async -> [AgentCli: AgentCliInstall] {
        var found: [AgentCli: AgentCliInstall] = [:]
        for cli in AgentCli.allCases {
            guard let path = await locate(cli) else { continue }
            found[cli] = Self.detect(cli: cli, path: path, resolvedPath: resolveLinks(path), home: home)
        }
        return found
    }

    func version(of install: AgentCliInstall) async -> String? {
        let out = await runner(AgentCliCommand(install.path, ["--version"]))
        return out.succeeded ? Self.parseVersion(out.stdout) : nil
    }

    /// Check every CLI, and update the ones that are installed unless
    /// `checkOnly`. Returns the new state; the caller saves it.
    /// `lastChecked` there is when an update run last happened, the clock the
    /// schedule goes by.
    public func run(checkOnly: Bool, previous: AgentCliUpdateState = AgentCliUpdateState(),
                    now: @Sendable () -> Date = { Date() }) async -> AgentCliUpdateState {
        let installs = await installs()
        var statuses: [AgentCliStatus] = []

        // One `brew update` serves every Homebrew install.
        var refreshed = Set<String>()
        for cli in AgentCli.allCases {
            let old = previous.statuses.first { $0.cli == cli }
            guard let install = installs[cli] else {
                statuses.append(AgentCliStatus(cli: cli, installed: false, lastChecked: now(), message: "Not installed"))
                continue
            }
            var status = AgentCliStatus(cli: cli, installed: true, path: install.path, method: install.method,
                                        version: await version(of: install), lastChecked: now(),
                                        lastUpdated: old?.lastUpdated)
            if let refresh = refreshCommand(for: install), !refreshed.contains(refresh.executable) {
                refreshed.insert(refresh.executable)
                log("Refreshing Homebrew: \(refresh.display)")
                let out = await runner(refresh)
                if !out.succeeded { log("brew update failed (\(out.exitCode)): \(Self.tail(out.stderr))") }
            }
            if let latest = latestVersionCommand(for: install) {
                let out = await runner(latest)
                if out.succeeded { status.latestVersion = Self.parseLatest(out.stdout, method: install.method) }
            }

            if checkOnly {
                status.message = Self.describe(version: status.version, latest: status.latestVersion)
                statuses.append(status)
                continue
            }
            if let latest = status.latestVersion, latest == status.version {
                status.message = "Up to date"
                statuses.append(status)
                continue
            }
            guard let command = updateCommand(for: install) else {
                status.message = "Installed by an unrecognised method; FleetMate leaves it alone"
                statuses.append(status)
                continue
            }
            log("Updating \(cli.rawValue) (\(install.method.rawValue)): \(command.display)")
            let out = await runner(command)
            let before = status.version
            status.version = await version(of: install) ?? before
            if out.succeeded {
                if status.version != before, let before, let after = status.version {
                    status.message = "Updated \(before) → \(after)"
                    status.lastUpdated = now()
                } else {
                    status.message = "Up to date"
                }
                log("\(cli.rawValue): \(status.message ?? "")")
            } else {
                let reason = Self.tail(out.stderr.isEmpty ? out.stdout : out.stderr)
                status.message = "Update did not complete: \(reason)"
                log("\(cli.rawValue) update failed (\(out.exitCode)): \(reason)")
            }
            statuses.append(status)
        }
        // A check alone does not reset the update schedule.
        return AgentCliUpdateState(lastChecked: checkOnly ? previous.lastChecked : now(), statuses: statuses)
    }

    static func describe(version: String?, latest: String?) -> String {
        switch (version, latest) {
        case let (v?, l?) where v == l: return "Up to date"
        case let (_, l?): return "\(l) available"
        default: return "Checked"
        }
    }

    /// The last line of a tool's error output, trimmed for a status line.
    static func tail(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "no output"
        return line.count > 160 ? String(line.prefix(157)) + "…" : line
    }
}
