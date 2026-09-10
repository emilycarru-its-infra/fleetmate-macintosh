import Foundation

/// Settings for the Manage tab: where the roster and command library live,
/// how SSH and Screen Sharing sessions are opened. Nothing here is a secret;
/// the Screen Sharing password has its own Keychain entry.
///
/// Read from the `manage:` block of `~/.fleetmate/config.yaml` and from the
/// per-user credentials file the Settings window writes; the file wins.
public struct ManageConfig: Codable, Equatable, Sendable {
    /// The operator switched the module on. Off hides the tab even when a roster exists.
    public var enabled: Bool = false
    /// Path to the enrollment roster CSV (computers.csv). Empty means the Munki repo default.
    /// Only a fallback: the roster is fetched from Azure DevOps first (see rosterRepo).
    public var rosterPath: String = ""
    /// Azure DevOps project and repository the roster is fetched from at
    /// load, so a stale local checkout never shows a stale sidebar. Empty
    /// rosterRepo turns the fetch off and the local file is used alone.
    public var rosterRepoProject: String = "Devices"
    public var rosterRepo: String = "Munki"
    public var rosterRepoPath: String = "/deployment/enroll/computers.csv"
    /// Path to the YAML command library. Empty means the per-user default.
    public var commandsPath: String = ""
    /// Private key for fleet SSH. Empty means `~/.ssh/id_rsa.macadmins`.
    public var sshKeyPath: String = ""
    /// Account for fleet SSH. Empty means the fleet admin account.
    public var sshUser: String = ""
    /// Terminal.app profile to open SSH sessions in. Empty means Terminal's default.
    public var terminalTheme: String = ""
    /// Account offered to Screen Sharing. Empty means the SSH user.
    public var screenSharingUser: String = ""
    /// Show roster rows whose status is not an Active variant.
    public var includeRetired: Bool = false
    /// Show the Provisioning catalog as a lab section.
    public var includeProvisioning: Bool = false
    /// Parallel SSH probes during a scan.
    public var probeConcurrency: Int = 12

    public static let defaultSshUser = "macadmins"
    public static let defaultSshKeyPath = "~/.ssh/id_rsa.macadmins"
    public static let defaultRosterRelativePath = "deployment/enroll/computers.csv"
    /// Where the roster fetched from Azure DevOps is kept between launches.
    public static let rosterCachePath = "~/.fleetmate/cache/computers.csv"

    /// The fetch is on when a repository is named.
    public var fetchesRoster: Bool {
        !rosterRepo.trimmingCharacters(in: .whitespaces).isEmpty && !rosterRepoProject.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var rosterSourceLabel: String { "\(rosterRepoProject)/\(rosterRepo)" }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled
        case rosterPath = "roster_path"
        case rosterRepoProject = "roster_repo_project"
        case rosterRepo = "roster_repo"
        case rosterRepoPath = "roster_repo_path"
        case commandsPath = "commands_path"
        case sshKeyPath = "ssh_key_path"
        case sshUser = "ssh_user"
        case terminalTheme = "terminal_theme"
        case screenSharingUser = "screen_sharing_user"
        case includeRetired = "include_retired"
        case includeProvisioning = "include_provisioning"
        case probeConcurrency = "probe_concurrency"
    }

    // MARK: - Resolved values

    /// The roster path in use: the configured one, else the Munki repo's enrollment CSV.
    public func resolvedRosterPath(repoRoot: String?) -> String {
        let trimmed = rosterPath.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return Self.expandHome(trimmed) }
        guard let repoRoot, !repoRoot.isEmpty else { return "" }
        return (Self.expandHome(repoRoot) as NSString).appendingPathComponent(Self.defaultRosterRelativePath)
    }

    public var resolvedCommandsPath: String {
        let trimmed = commandsPath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ManageStateStore().commandsPath : Self.expandHome(trimmed)
    }

    public var resolvedSshKeyPath: String {
        let trimmed = sshKeyPath.trimmingCharacters(in: .whitespaces)
        return Self.expandHome(trimmed.isEmpty ? Self.defaultSshKeyPath : trimmed)
    }

    public var resolvedSshUser: String {
        let trimmed = sshUser.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultSshUser : trimmed
    }

    public var resolvedScreenSharingUser: String {
        let trimmed = screenSharingUser.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? resolvedSshUser : trimmed
    }

    public func hasRoster(repoRoot: String?) -> Bool {
        let path = resolvedRosterPath(repoRoot: repoRoot)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    public var hasSshKey: Bool { FileManager.default.fileExists(atPath: resolvedSshKeyPath) }

    /// The SSH configuration the Manage tab connects with.
    public func toSecureShellConfig() -> SecureShellConfig {
        SecureShellConfig(
            privateKeyPath: resolvedSshKeyPath,
            privateKeyEnvVar: nil,
            keyVaultName: nil,
            defaultUsername: resolvedSshUser,
            connectionTimeoutSeconds: 8,
            commandTimeoutSeconds: 300,
            maxConcurrentConnections: max(1, probeConcurrency),
            port: 22
        )
    }

    public static func expandHome(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    // MARK: - Loading from the YAML dictionary

    /// Read a `manage:` block. Accepts snake_case and camelCase keys.
    static func from(yaml: [String: Any]) -> ManageConfig {
        var c = ManageConfig()
        func str(_ snake: String, _ camel: String) -> String? {
            (yaml[snake] ?? yaml[camel]) as? String
        }
        func bool(_ snake: String, _ camel: String) -> Bool? {
            (yaml[snake] ?? yaml[camel]) as? Bool
        }
        if let v = bool("enabled", "enabled") { c.enabled = v }
        if let v = str("roster_path", "rosterPath") { c.rosterPath = v }
        if let v = str("roster_repo_project", "rosterRepoProject") { c.rosterRepoProject = v }
        if let v = str("roster_repo", "rosterRepo") { c.rosterRepo = v }
        if let v = str("roster_repo_path", "rosterRepoPath") { c.rosterRepoPath = v }
        if let v = str("commands_path", "commandsPath") { c.commandsPath = v }
        if let v = str("ssh_key_path", "sshKeyPath") { c.sshKeyPath = v }
        if let v = str("ssh_user", "sshUser") { c.sshUser = v }
        if let v = str("terminal_theme", "terminalTheme") { c.terminalTheme = v }
        if let v = str("screen_sharing_user", "screenSharingUser") { c.screenSharingUser = v }
        if let v = bool("include_retired", "includeRetired") { c.includeRetired = v }
        if let v = bool("include_provisioning", "includeProvisioning") { c.includeProvisioning = v }
        if let v = (yaml["probe_concurrency"] ?? yaml["probeConcurrency"]) as? Int { c.probeConcurrency = v }
        return c
    }

    // MARK: - Credentials file round trip

    /// Flat keys in the per-user credentials JSON.
    static let credentialKeys = [
        "manageEnabled", "manageRosterPath", "manageCommandsPath", "manageSshKeyPath", "manageSshUser",
        "manageTerminalTheme", "manageScreenSharingUser", "manageIncludeRetired",
        "manageIncludeProvisioning", "manageProbeConcurrency",
    ]

    func credentialValues() -> [String: String] {
        var out: [String: String] = [:]
        out["manageEnabled"] = enabled ? "true" : "false"
        if !rosterPath.isEmpty { out["manageRosterPath"] = rosterPath }
        if !commandsPath.isEmpty { out["manageCommandsPath"] = commandsPath }
        if !sshKeyPath.isEmpty { out["manageSshKeyPath"] = sshKeyPath }
        if !sshUser.isEmpty { out["manageSshUser"] = sshUser }
        if !terminalTheme.isEmpty { out["manageTerminalTheme"] = terminalTheme }
        if !screenSharingUser.isEmpty { out["manageScreenSharingUser"] = screenSharingUser }
        if includeRetired { out["manageIncludeRetired"] = "true" }
        if includeProvisioning { out["manageIncludeProvisioning"] = "true" }
        if probeConcurrency != ManageConfig().probeConcurrency { out["manageProbeConcurrency"] = String(probeConcurrency) }
        return out
    }

    /// Apply the flat keys over `base`. Returns nil when none are present.
    static func applying(credentials: [String: String], to base: ManageConfig?) -> ManageConfig? {
        guard credentialKeys.contains(where: { credentials[$0] != nil }) else { return base }
        var c = base ?? ManageConfig()
        if let v = credentials["manageEnabled"] { c.enabled = v == "true" }
        if let v = credentials["manageRosterPath"] { c.rosterPath = v }
        if let v = credentials["manageCommandsPath"] { c.commandsPath = v }
        if let v = credentials["manageSshKeyPath"] { c.sshKeyPath = v }
        if let v = credentials["manageSshUser"] { c.sshUser = v }
        if let v = credentials["manageTerminalTheme"] { c.terminalTheme = v }
        if let v = credentials["manageScreenSharingUser"] { c.screenSharingUser = v }
        if let v = credentials["manageIncludeRetired"] { c.includeRetired = v == "true" }
        if let v = credentials["manageIncludeProvisioning"] { c.includeProvisioning = v == "true" }
        if let v = credentials["manageProbeConcurrency"], let n = Int(v) { c.probeConcurrency = n }
        return c
    }
}
