import Foundation
import Yams

/// Configuration for FleetMate
///
/// Credentials are loaded in order of precedence:
/// 1. Environment variables (highest priority, for CI/CD)
/// 2. macOS Keychain (for developer workstations)
/// 3. .env files (legacy fallback)
/// 4. Config YAML files (default values)
///
/// Required Environment Variables:
/// - REPORTMATE_URL: ReportMate API base URL
/// - REPORTMATE_PASSPHRASE: ReportMate API passphrase
/// - SNIPE_URL: Snipe-IT instance URL
/// - SNIPE_API_KEY: Snipe-IT API key
/// - GRAPH_TENANT_ID: Azure AD tenant ID for Microsoft Graph
/// - GRAPH_CLIENT_ID: Azure AD application client ID
/// - GRAPH_CLIENT_SECRET: Azure AD application client secret (optional)
/// - DEVOPS_ORGANIZATION: Azure DevOps organization name
/// - DEVOPS_PROJECT: Azure DevOps project name
/// - DEVOPS_PAT: Azure DevOps personal access token (optional)
/// - TDX_BASE_URL: TeamDynamix Web API base URL
/// - TDX_APP_ID: TeamDynamix application ID
/// - TDX_USERNAME: TeamDynamix username (for regular auth)
/// - TDX_PASSWORD: TeamDynamix password (for regular auth)
/// - TDX_BEID: TeamDynamix BEID (for admin auth)
/// - TDX_WEB_SERVICES_KEY: TeamDynamix web services key (for admin auth)
public struct FleetMateConfig: Codable {
    // ReportMate API settings (replaces MunkiReport)
    public var reportMateUrl: String?
    public var reportMatePassphrase: String?
    
    // Legacy MunkiReport settings (deprecated, use ReportMate)
    public var munkiReportUrl: String?
    var munkiReportSshHost: String?
    var munkiReportSshUser: String?
    var munkiReportSshKeyPath: String?
    var munkiReportDbPath: String?

    // Snipe-IT API settings
    public var snipeUrl: String?
    public var snipeApiKey: String?

    // Microsoft Graph (Intune/Entra) settings
    public var graphTenantId: String?
    public var graphClientId: String?
    public var graphClientSecret: String?
    public var graphPageSize: Int = 100

    // Azure DevOps settings
    public var devopsOrganization: String?
    public var devopsProject: String?
    public var devopsPat: String?
    public var devopsDefaultWorkItemType: String = "Bug"

    // TeamDynamix (TDX) settings
    public var tdxBaseUrl: String?
    public var tdxAppId: Int?
    public var tdxUsername: String?
    public var tdxPassword: String?
    public var tdxBeid: String?
    public var tdxWebServicesKey: String?
    public var tdxDefaultTypeId: Int?
    public var tdxDefaultStatusId: Int?
    public var tdxDefaultPriorityId: Int?
    public var tdxDefaultSourceId: Int?
    public var tdxDefaultAccountId: Int?
    
    // SecureShell settings
    public var secureShell: SecureShellConfig?

    // Deployment repo paths
    public var deploymentPath: String = "deployment"
    public var pkgsinfoPath: String = "deployment/pkgsinfo"
    public var pkgsPath: String = "deployment/pkgs"
    public var manifestsPath: String = "deployment/manifests"
    public var catalogsPath: String = "deployment/catalogs"

    // Local paths
    public var packagesPath: String = "packages"
    public var logPath: String = "~/Library/Logs/FleetMate"
    public var logLevel: String = "info"
    public var cacheMinutes: Int = 5

    // Repo root (detected at runtime)
    public var repoRoot: String?
    
    /// Default initializer
    public init() {}

    enum CodingKeys: String, CodingKey {
        case reportMateUrl = "reportmate_url"
        case reportMatePassphrase = "reportmate_passphrase"
        case munkiReportUrl = "munkireport_url"
        case munkiReportSshHost = "munkireport_ssh_host"
        case munkiReportSshUser = "munkireport_ssh_user"
        case munkiReportSshKeyPath = "munkireport_ssh_key_path"
        case munkiReportDbPath = "munkireport_db_path"
        case snipeUrl = "snipe_url"
        case snipeApiKey = "snipe_api_key"
        case graphTenantId = "graph_tenant_id"
        case graphClientId = "graph_client_id"
        case graphClientSecret = "graph_client_secret"
        case graphPageSize = "graph_page_size"
        case devopsOrganization = "devops_organization"
        case devopsProject = "devops_project"
        case devopsPat = "devops_pat"
        case devopsDefaultWorkItemType = "devops_default_work_item_type"
        case tdxBaseUrl = "tdx_base_url"
        case tdxAppId = "tdx_app_id"
        case tdxUsername = "tdx_username"
        case tdxPassword = "tdx_password"
        case tdxBeid = "tdx_beid"
        case tdxWebServicesKey = "tdx_web_services_key"
        case tdxDefaultTypeId = "tdx_default_type_id"
        case tdxDefaultStatusId = "tdx_default_status_id"
        case tdxDefaultPriorityId = "tdx_default_priority_id"
        case tdxDefaultSourceId = "tdx_default_source_id"
        case tdxDefaultAccountId = "tdx_default_account_id"
        case secureShell = "secure_shell"
        case deploymentPath = "deployment_path"
        case pkgsinfoPath = "pkgsinfo_path"
        case pkgsPath = "pkgs_path"
        case manifestsPath = "manifests_path"
        case catalogsPath = "catalogs_path"
        case packagesPath = "packages_path"
        case logPath = "log_path"
        case logLevel = "log_level"
        case cacheMinutes = "cache_minutes"
        case repoRoot = "repo_root"
    }

    static let configLocations: [String] = [
        "~/.fleetmate/config.yaml",
        "~/.config/fleetmate/config.yaml",
        "/etc/fleetmate/config.yaml"
    ]

    /// Load configuration from file, Keychain, and environment
    public static func load() throws -> FleetMateConfig {
        var config = FleetMateConfig()

        // Try config file locations
        for location in configLocations {
            let expandedPath = NSString(string: location).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                if let loaded = loadFromFile(path: expandedPath) {
                    config = loaded
                    break
                }
            }
        }

        // Load .env file
        let envPaths = [
            "~/.fleetmate/.env",
            ".env"
        ]
        for envPath in envPaths {
            let expandedPath = NSString(string: envPath).expandingTildeInPath
            loadEnvFile(path: expandedPath, into: &config)
        }
        
        // Load from macOS Keychain (preferred for developer workstations)
        loadFromKeychain(into: &config)

        // Environment variables override everything (for CI/CD)
        loadEnvironmentVariables(into: &config)

        // Find repo root
        config.repoRoot = findRepoRoot()

        return config
    }

    private static func loadFromFile(path: String) -> FleetMateConfig? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let decoder = YAMLDecoder()
        return try? decoder.decode(FleetMateConfig.self, from: contents)
    }
    
    /// Load credentials from macOS Keychain
    private static func loadFromKeychain(into config: inout FleetMateConfig) {
        let keychain = KeychainService.shared
        
        // ReportMate
        if let url = keychain.get(.reportMateUrl) { config.reportMateUrl = url }
        if let passphrase = keychain.get(.reportMatePassphrase) { config.reportMatePassphrase = passphrase }
        
        // Snipe-IT
        if let url = keychain.get(.snipeUrl) { config.snipeUrl = url }
        if let apiKey = keychain.get(.snipeApiKey) { config.snipeApiKey = apiKey }
        
        // Graph/Entra
        if let tenantId = keychain.get(.graphTenantId) { config.graphTenantId = tenantId }
        if let clientId = keychain.get(.graphClientId) { config.graphClientId = clientId }
        if let clientSecret = keychain.get(.graphClientSecret) { config.graphClientSecret = clientSecret }
        
        // Azure DevOps
        if let org = keychain.get(.devopsOrganization) { config.devopsOrganization = org }
        if let project = keychain.get(.devopsProject) { config.devopsProject = project }
        if let pat = keychain.get(.devopsPat) { config.devopsPat = pat }
        
        // TDX
        if let url = keychain.get(.tdxBaseUrl) { config.tdxBaseUrl = url }
        if let appId = keychain.get(.tdxAppId), let id = Int(appId) { config.tdxAppId = id }
        if let username = keychain.get(.tdxUsername) { config.tdxUsername = username }
        if let password = keychain.get(.tdxPassword) { config.tdxPassword = password }
        if let beid = keychain.get(.tdxBeid) { config.tdxBeid = beid }
        if let wsKey = keychain.get(.tdxWebServicesKey) { config.tdxWebServicesKey = wsKey }
        
        // SecureShell
        if let keyPath = keychain.get(.sshKeyPath) {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.privateKeyPath = keyPath
        }
        if let username = keychain.get(.sshDefaultUsername) {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.defaultUsername = username
        }
        if let vaultName = keychain.get(.sshKeyVaultName) {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.keyVaultName = vaultName
        }
    }

    private static func loadEnvFile(path: String, into config: inout FleetMateConfig) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // Remove quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            applyConfigValue(key: key.uppercased(), value: value, to: &config)
        }
    }

    private static func loadEnvironmentVariables(into config: inout FleetMateConfig) {
        let env = ProcessInfo.processInfo.environment

        // ReportMate
        if let v = env["REPORTMATE_URL"] { config.reportMateUrl = v }
        if let v = env["REPORTMATE_PASSPHRASE"] { config.reportMatePassphrase = v }

        // Legacy MunkiReport (deprecated)
        if let v = env["MUNKIREPORT_URL"] { config.munkiReportUrl = v }
        if let v = env["MUNKIREPORT_SSH_HOST"] { config.munkiReportSshHost = v }
        if let v = env["MUNKIREPORT_SSH_USER"] { config.munkiReportSshUser = v }
        if let v = env["MUNKIREPORT_SSH_KEY_PATH"] { config.munkiReportSshKeyPath = v }
        if let v = env["MUNKIREPORT_DB_PATH"] { config.munkiReportDbPath = v }

        // Snipe-IT
        if let v = env["SNIPE_URL"] { config.snipeUrl = v }
        if let v = env["SNIPE_API_KEY"] { config.snipeApiKey = v }

        // Microsoft Graph
        if let v = env["GRAPH_TENANT_ID"] { config.graphTenantId = v }
        if let v = env["GRAPH_CLIENT_ID"] { config.graphClientId = v }
        if let v = env["GRAPH_CLIENT_SECRET"] { config.graphClientSecret = v }

        // Azure DevOps
        if let v = env["DEVOPS_ORGANIZATION"] { config.devopsOrganization = v }
        if let v = env["DEVOPS_PROJECT"] { config.devopsProject = v }
        if let v = env["DEVOPS_PAT"] { config.devopsPat = v }
        if let v = env["AZURE_DEVOPS_PAT"] { config.devopsPat = v }

        // TDX
        if let v = env["TDX_BASE_URL"] { config.tdxBaseUrl = v }
        if let v = env["TDX_APP_ID"], let id = Int(v) { config.tdxAppId = id }
        if let v = env["TDX_USERNAME"] { config.tdxUsername = v }
        if let v = env["TDX_PASSWORD"] { config.tdxPassword = v }
        if let v = env["TDX_BEID"] { config.tdxBeid = v }
        if let v = env["TDX_WEB_SERVICES_KEY"] { config.tdxWebServicesKey = v }
        
        // SecureShell
        if let v = env["SSH_KEY_PATH"] {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.privateKeyPath = v
        }
        if let v = env["SSH_USER"] {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.defaultUsername = v
        }
    }

    private static func applyConfigValue(key: String, value: String, to config: inout FleetMateConfig) {
        switch key {
        case "REPORTMATE_URL": config.reportMateUrl = value
        case "REPORTMATE_PASSPHRASE": config.reportMatePassphrase = value
        case "MUNKIREPORT_URL": config.munkiReportUrl = value
        case "MUNKIREPORT_SSH_HOST": config.munkiReportSshHost = value
        case "MUNKIREPORT_SSH_USER": config.munkiReportSshUser = value
        case "MUNKIREPORT_SSH_KEY_PATH": config.munkiReportSshKeyPath = value
        case "MUNKIREPORT_DB_PATH": config.munkiReportDbPath = value
        case "SNIPE_URL": config.snipeUrl = value
        case "SNIPE_API_KEY": config.snipeApiKey = value
        case "GRAPH_TENANT_ID": config.graphTenantId = value
        case "GRAPH_CLIENT_ID": config.graphClientId = value
        case "GRAPH_CLIENT_SECRET": config.graphClientSecret = value
        case "DEVOPS_ORGANIZATION": config.devopsOrganization = value
        case "DEVOPS_PROJECT": config.devopsProject = value
        case "DEVOPS_PAT", "AZURE_DEVOPS_PAT": config.devopsPat = value
        case "TDX_BASE_URL": config.tdxBaseUrl = value
        case "TDX_APP_ID": config.tdxAppId = Int(value)
        case "TDX_USERNAME": config.tdxUsername = value
        case "TDX_PASSWORD": config.tdxPassword = value
        case "TDX_BEID": config.tdxBeid = value
        case "TDX_WEB_SERVICES_KEY": config.tdxWebServicesKey = value
        default: break
        }
    }

    private static func findRepoRoot() -> String? {
        var current = FileManager.default.currentDirectoryPath
        while !current.isEmpty && current != "/" {
            let gitPath = (current as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitPath) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Resolve a relative path to absolute using repo root
    public func resolvePath(_ relativePath: String) -> String {
        if relativePath.hasPrefix("/") {
            return relativePath
        }
        if relativePath.hasPrefix("~") {
            return NSString(string: relativePath).expandingTildeInPath
        }
        if let root = repoRoot {
            return (root as NSString).appendingPathComponent(relativePath)
        }
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(relativePath)
    }

    // MARK: - Helpers

    /// Check if ReportMate is configured (preferred over MunkiReport)
    public var isReportMateConfigured: Bool {
        return reportMateUrl != nil && !reportMateUrl!.isEmpty
    }

    /// Check if MunkiReport is configured (legacy)
    public var isMunkiReportConfigured: Bool {
        return munkiReportUrl != nil
    }

    /// Check if MunkiReport SSH access is configured
    public var isMunkiReportSshConfigured: Bool {
        return munkiReportSshHost != nil && munkiReportSshUser != nil && munkiReportDbPath != nil
    }

    /// Check if Snipe-IT is configured
    public var isSnipeConfigured: Bool {
        return snipeUrl != nil && snipeApiKey != nil
    }

    /// Check if Graph is configured
    public var isGraphConfigured: Bool {
        return graphTenantId != nil && graphClientId != nil
    }

    /// Check if DevOps is configured
    public var isDevOpsConfigured: Bool {
        return devopsOrganization != nil && devopsProject != nil
    }

    /// Check if TDX is configured
    public var isTdxConfigured: Bool {
        return tdxBaseUrl != nil && tdxAppId != nil &&
               ((tdxUsername != nil && tdxPassword != nil) || (tdxBeid != nil && tdxWebServicesKey != nil))
    }
    
    /// Check if SecureShell is configured
    public var isSecureShellConfigured: Bool {
        if let ssh = secureShell {
            // Check if we have a key path that exists or env var set
            let keyPath = ssh.resolvedKeyPath
            if FileManager.default.fileExists(atPath: keyPath) { return true }
            if ssh.getPrivateKeyFromEnv() != nil { return true }
            if KeychainService.shared.exists(.sshPrivateKey) { return true }
        }
        // Check default SSH key locations
        let defaultPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/id_ed25519",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/id_rsa"
        ]
        return defaultPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Get TDX tickets URL
    public func tdxTicketsUrl(_ suffix: String = "") -> String {
        let base = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appId = tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(base)/api/\(appId)/tickets"
        }
        return "\(base)/api/\(appId)/tickets/\(suffix)"
    }
    
    /// Get TDX assets URL
    public func tdxAssetsUrl(_ suffix: String = "") -> String {
        let base = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appId = tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(base)/api/\(appId)/assets"
        }
        return "\(base)/api/\(appId)/assets/\(suffix)"
    }
}

