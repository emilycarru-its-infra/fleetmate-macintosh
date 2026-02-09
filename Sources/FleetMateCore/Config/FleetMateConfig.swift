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

    // Microsoft Graph settings - shared tenant
    public var graphTenantId: String?
    public var graphPageSize: Int = 100
    
    // Microsoft Graph - Devices (Intune) Service Principal
    // Used for: /deviceManagement/managedDevices
    public var devicesGraphId: String?
    public var devicesGraphSecret: String?
    
    // Microsoft Graph - Systems (Entra) Service Principal
    // Used for: /users, /groups
    public var systemsGraphId: String?
    public var systemsGraphSecret: String?
    
    // Legacy single-credential properties (for backward compatibility)
    public var graphClientId: String?
    public var graphClientSecret: String?

    // Azure DevOps settings
    public var devopsOrganization: String?
    public var devopsProject: String?
    public var devopsPat: String?
    public var devopsClientId: String?
    public var devopsTenantId: String?
    public var devopsDefaultWorkItemType: String = "Bug"

    // TeamDynamix (TDX) settings
    public var tdxBaseUrl: String?
    public var tdxAppId: Int?  // Legacy fallback
    public var tdxTicketingAppId: Int?  // 115 at ECU
    public var tdxAssetsAppId: Int?  // 116 at ECU
    public var tdxUsername: String?
    public var tdxPassword: String?
    public var tdxBeid: String?
    public var tdxWebServicesKey: String?
    public var tdxDefaultTypeId: Int?
    public var tdxDefaultStatusId: Int?
    public var tdxDefaultPriorityId: Int?
    public var tdxDefaultSourceId: Int?
    public var tdxDefaultAccountId: Int?
    public var tdxResponsibleGroupId: Int?  // Group ID for filtering tickets
    
    // TDX SSO Authentication (user-context auth via Entra ID/Shibboleth)
    public var tdxAuthMethod: TdxAuthMethod = .auto
    public var tdxSsoEnabled: Bool = true  // Prefer SSO when available
    public var tdxSsoCallbackPort: Int = 8457  // Localhost callback port
    
    // SecureShell settings
    public var secureShell: SecureShellConfig?
    
    // Tasks settings (multi-provider task management)
    public var tasks: TasksConfig?

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
        case devicesGraphId = "devices_graph_id"
        case devicesGraphSecret = "devices_graph_secret"
        case systemsGraphId = "systems_graph_id"
        case systemsGraphSecret = "systems_graph_secret"
        case devopsOrganization = "devops_organization"
        case devopsProject = "devops_project"
        case devopsPat = "devops_pat"
        case devopsClientId = "devops_client_id"
        case devopsTenantId = "devops_tenant_id"
        case devopsDefaultWorkItemType = "devops_default_work_item_type"
        case tdxBaseUrl = "tdx_base_url"
        case tdxAppId = "tdx_app_id"
        case tdxTicketingAppId = "tdx_ticketing_app_id"
        case tdxAssetsAppId = "tdx_assets_app_id"
        case tdxUsername = "tdx_username"
        case tdxAuthMethod = "tdx_auth_method"
        case tdxSsoEnabled = "tdx_sso_enabled"
        case tdxSsoCallbackPort = "tdx_sso_callback_port"
        case tdxPassword = "tdx_password"
        case tdxBeid = "tdx_beid"
        case tdxWebServicesKey = "tdx_web_services_key"
        case tdxDefaultTypeId = "tdx_default_type_id"
        case tdxDefaultStatusId = "tdx_default_status_id"
        case tdxDefaultPriorityId = "tdx_default_priority_id"
        case tdxDefaultSourceId = "tdx_default_source_id"
        case tdxDefaultAccountId = "tdx_default_account_id"
        case tdxResponsibleGroupId = "tdx_responsible_group_id"
        case secureShell = "secure_shell"
        case tasks = "tasks"
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
        
        // Load from secrets.yaml file (created by setup-secrets.sh)
        // This is the PRIMARY secret storage - no Keychain prompts!
        loadFromSecretsFile(into: &config)
        
        // NOTE: Keychain loading removed to avoid password prompts
        // Secrets are now loaded from ~/.config/fleetmate/secrets.yaml

        // Environment variables override everything (for CI/CD)
        loadEnvironmentVariables(into: &config)

        // Find repo root
        config.repoRoot = findRepoRoot()

        return config
    }
    
    /// Load secrets from ~/.config/fleetmate/secrets.yaml (created by setup-secrets.sh)
    /// Returns true if secrets file was found and loaded successfully
    @discardableResult
    private static func loadFromSecretsFile(into config: inout FleetMateConfig) -> Bool {
        let secretsPath = NSString(string: "~/.config/fleetmate/secrets.yaml").expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: secretsPath) else {
            print("[FleetMate] secrets.yaml not found at \(secretsPath)")
            return false
        }
        
        guard let contents = try? String(contentsOfFile: secretsPath, encoding: .utf8) else {
            print("[FleetMate] Could not read secrets.yaml")
            return false
        }
        
        // Parse as dictionary to allow missing keys (FleetMateConfig decode requires all keys)
        guard let yaml = try? Yams.load(yaml: contents) as? [String: Any] else {
            print("[FleetMate] Failed to parse secrets.yaml as dictionary")
            return false
        }
        
        print("[FleetMate] Loaded \(yaml.count) secrets from \(secretsPath)")
        
        // Helper to get string value
        func str(_ key: String) -> String? {
            yaml[key] as? String
        }
        
        // Helper to get int value
        func int(_ key: String) -> Int? {
            yaml[key] as? Int
        }
        
        // Snipe-IT
        if let v = str("snipe_url"), !v.isEmpty { config.snipeUrl = v }
        if let v = str("snipe_api_key"), !v.isEmpty { config.snipeApiKey = v }
        
        // Microsoft Graph - shared tenant
        if let v = str("graph_tenant_id"), !v.isEmpty { config.graphTenantId = v }
        
        // Microsoft Graph - Devices (Intune) Service Principal
        if let v = str("devices_graph_id"), !v.isEmpty { config.devicesGraphId = v }
        if let v = str("devices_graph_secret"), !v.isEmpty { config.devicesGraphSecret = v }
        
        // Microsoft Graph - Systems (Entra) Service Principal
        if let v = str("systems_graph_id"), !v.isEmpty { config.systemsGraphId = v }
        if let v = str("systems_graph_secret"), !v.isEmpty { config.systemsGraphSecret = v }
        
        // Legacy single-credential (backward compatibility)
        if let v = str("graph_client_id"), !v.isEmpty { config.graphClientId = v }
        if let v = str("graph_client_secret"), !v.isEmpty { config.graphClientSecret = v }
        
        // Azure DevOps
        if let v = str("devops_organization"), !v.isEmpty { config.devopsOrganization = v }
        if let v = str("devops_project"), !v.isEmpty { config.devopsProject = v }
        if let v = str("devops_client_id"), !v.isEmpty { config.devopsClientId = v }
        if let v = str("devops_tenant_id"), !v.isEmpty { config.devopsTenantId = v }
        
        // TeamDynamix
        if let v = str("tdx_base_url"), !v.isEmpty { config.tdxBaseUrl = v }
        if let appId = int("tdx_app_id") { config.tdxAppId = appId }
        if let appId = int("tdx_ticketing_app_id") { config.tdxTicketingAppId = appId }
        if let appId = int("tdx_assets_app_id") { config.tdxAssetsAppId = appId }
        if let v = str("tdx_username"), !v.isEmpty { config.tdxUsername = v }
        if let v = str("tdx_password"), !v.isEmpty { config.tdxPassword = v }
        if let v = str("tdx_beid"), !v.isEmpty { config.tdxBeid = v }
        if let v = str("tdx_web_services_key"), !v.isEmpty { config.tdxWebServicesKey = v }
        if let groupId = int("tdx_responsible_group_id") { config.tdxResponsibleGroupId = groupId }
        
        // ReportMate
        if let v = str("reportmate_url"), !v.isEmpty { config.reportMateUrl = v }
        if let v = str("reportmate_passphrase"), !v.isEmpty { config.reportMatePassphrase = v }
        
        return true
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
        if let v = env["DEVOPS_CLIENT_ID"] { config.devopsClientId = v }
        if let v = env["DEVOPS_TENANT_ID"] { config.devopsTenantId = v }

        // TDX
        if let v = env["TDX_BASE_URL"] { config.tdxBaseUrl = v }
        if let v = env["TDX_APP_ID"], let id = Int(v) { config.tdxAppId = id }
        if let v = env["TDX_TICKETING_APP_ID"], let id = Int(v) { config.tdxTicketingAppId = id }
        if let v = env["TDX_ASSETS_APP_ID"], let id = Int(v) { config.tdxAssetsAppId = id }
        if let v = env["TDX_USERNAME"] { config.tdxUsername = v }
        if let v = env["TDX_PASSWORD"] { config.tdxPassword = v }
        if let v = env["TDX_BEID"] { config.tdxBeid = v }
        if let v = env["TDX_WEB_SERVICES_KEY"] { config.tdxWebServicesKey = v }
        if let v = env["TDX_RESPONSIBLE_GROUP_ID"], let id = Int(v) { config.tdxResponsibleGroupId = id }
        
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
        case "DEVOPS_CLIENT_ID": config.devopsClientId = value
        case "DEVOPS_TENANT_ID": config.devopsTenantId = value
        case "TDX_BASE_URL": config.tdxBaseUrl = value
        case "TDX_APP_ID": config.tdxAppId = Int(value)
        case "TDX_TICKETING_APP_ID": config.tdxTicketingAppId = Int(value)
        case "TDX_ASSETS_APP_ID": config.tdxAssetsAppId = Int(value)
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

    /// Check if Graph is configured (either devices or systems service principal)
    public var isGraphConfigured: Bool {
        return graphTenantId != nil && (isDevicesGraphConfigured || isSystemsGraphConfigured || graphClientId != nil)
    }
    
    /// Check if Devices Graph (Intune) is configured
    public var isDevicesGraphConfigured: Bool {
        return graphTenantId != nil && devicesGraphId != nil && devicesGraphSecret != nil
    }
    
    /// Check if Systems Graph (Entra users/groups) is configured
    public var isSystemsGraphConfigured: Bool {
        return graphTenantId != nil && systemsGraphId != nil && systemsGraphSecret != nil
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
            // NOTE: Removed Keychain check to avoid password prompts
        }
        // Check default SSH key locations
        let defaultPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/id_ed25519",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/id_rsa"
        ]
        return defaultPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    /// Check if any tasks provider is configured
    public var isTasksConfigured: Bool {
        guard let tasks = tasks else { return false }
        return tasks.providers.azdevops?.enabled == true ||
               tasks.providers.github?.enabled == true ||
               tasks.providers.gitea?.enabled == true
    }
    
    /// Get list of enabled task providers
    public var enabledTaskProviders: [String] {
        guard let tasks = tasks else { return [] }
        var providers: [String] = []
        if tasks.providers.azdevops?.enabled == true { providers.append("azdevops") }
        if tasks.providers.github?.enabled == true { providers.append("github") }
        if tasks.providers.gitea?.enabled == true { providers.append("gitea") }
        return providers
    }

    /// Get TDX tickets URL
    public func tdxTicketsUrl(_ suffix: String = "") -> String {
        let base = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appId = tdxTicketingAppId ?? tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(base)/api/\(appId)/tickets"
        }
        return "\(base)/api/\(appId)/tickets/\(suffix)"
    }
    
    /// Get TDX assets URL
    public func tdxAssetsUrl(_ suffix: String = "") -> String {
        let base = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appId = tdxAssetsAppId ?? tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(base)/api/\(appId)/assets"
        }
        return "\(base)/api/\(appId)/assets/\(suffix)"
    }
}

// MARK: - Tasks Configuration

/// Configuration for multi-provider task management
public struct TasksConfig: Codable {
    /// Task provider configurations
    public var providers: TaskProvidersConfig
    
    /// Microsoft Planner sync configuration (one-way push)
    public var planner: PlannerSyncConfig?
    
    /// Markdown file sync configuration
    public var markdown: MarkdownSyncConfig?
    
    /// Default provider for task creation when not specified
    public var defaultProvider: String
    
    public init(
        providers: TaskProvidersConfig = TaskProvidersConfig(),
        planner: PlannerSyncConfig? = nil,
        markdown: MarkdownSyncConfig? = nil,
        defaultProvider: String = "azdevops"
    ) {
        self.providers = providers
        self.planner = planner
        self.markdown = markdown
        self.defaultProvider = defaultProvider
    }
    
    enum CodingKeys: String, CodingKey {
        case providers
        case planner
        case markdown
        case defaultProvider = "default_provider"
    }
}

/// Configuration for individual task providers
public struct TaskProvidersConfig: Codable {
    /// Azure DevOps task provider configuration
    public var azdevops: AzureDevOpsProviderConfig?
    
    /// GitHub task provider configuration
    public var github: GitHubProviderConfig?
    
    /// Gitea task provider configuration
    public var gitea: GiteaProviderConfig?
    
    public init(
        azdevops: AzureDevOpsProviderConfig? = nil,
        github: GitHubProviderConfig? = nil,
        gitea: GiteaProviderConfig? = nil
    ) {
        self.azdevops = azdevops
        self.github = github
        self.gitea = gitea
    }
}

/// Azure DevOps provider configuration for tasks
public struct AzureDevOpsProviderConfig: Codable {
    /// Whether this provider is enabled
    public var enabled: Bool
    
    /// Override organization (uses devopsOrganization if not set)
    public var organization: String?
    
    /// Override project (uses devopsProject if not set)
    public var project: String?
    
    /// Default work item type for created tasks
    public var defaultWorkItemType: String
    
    /// Area path for created tasks
    public var areaPath: String?
    
    /// Iteration path for created tasks (empty = current sprint)
    public var iterationPath: String?
    
    public init(
        enabled: Bool = true,
        organization: String? = nil,
        project: String? = nil,
        defaultWorkItemType: String = "Bug",
        areaPath: String? = nil,
        iterationPath: String? = nil
    ) {
        self.enabled = enabled
        self.organization = organization
        self.project = project
        self.defaultWorkItemType = defaultWorkItemType
        self.areaPath = areaPath
        self.iterationPath = iterationPath
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case organization
        case project
        case defaultWorkItemType = "default_work_item_type"
        case areaPath = "area_path"
        case iterationPath = "iteration_path"
    }
}

/// GitHub provider configuration for tasks
public struct GitHubProviderConfig: Codable {
    /// Whether this provider is enabled
    public var enabled: Bool
    
    /// Repository owner (user or organization)
    public var owner: String?
    
    /// Repository name
    public var repo: String?
    
    /// Personal access token (or use 'gh auth token')
    public var token: String?
    
    /// Default labels to apply to created issues
    public var defaultLabels: [String]
    
    /// Use GitHub CLI for authentication if token not provided
    public var useGhCli: Bool
    
    public init(
        enabled: Bool = false,
        owner: String? = nil,
        repo: String? = nil,
        token: String? = nil,
        defaultLabels: [String] = [],
        useGhCli: Bool = true
    ) {
        self.enabled = enabled
        self.owner = owner
        self.repo = repo
        self.token = token
        self.defaultLabels = defaultLabels
        self.useGhCli = useGhCli
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case owner
        case repo
        case token
        case defaultLabels = "default_labels"
        case useGhCli = "use_gh_cli"
    }
}

/// Gitea provider configuration for tasks
public struct GiteaProviderConfig: Codable {
    /// Whether this provider is enabled
    public var enabled: Bool
    
    /// Gitea server URL (e.g., "https://git.example.com")
    public var url: String?
    
    /// Repository owner
    public var owner: String?
    
    /// Repository name
    public var repo: String?
    
    /// API token
    public var token: String?
    
    /// Default labels to apply to created issues
    public var defaultLabels: [String]
    
    public init(
        enabled: Bool = false,
        url: String? = nil,
        owner: String? = nil,
        repo: String? = nil,
        token: String? = nil,
        defaultLabels: [String] = []
    ) {
        self.enabled = enabled
        self.url = url
        self.owner = owner
        self.repo = repo
        self.token = token
        self.defaultLabels = defaultLabels
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case url
        case owner
        case repo
        case token
        case defaultLabels = "default_labels"
    }
}

/// Microsoft Planner sync configuration (one-way push)
public struct PlannerSyncConfig: Codable {
    /// Whether Planner sync is enabled
    public var enabled: Bool
    
    /// Planner plan ID to sync tasks to
    public var planId: String?
    
    /// Default bucket ID for new tasks (nil = first available)
    public var defaultBucketId: String?
    
    /// Path to store sync state mapping file
    public var statePath: String
    
    public init(
        enabled: Bool = false,
        planId: String? = nil,
        defaultBucketId: String? = nil,
        statePath: String = "~/.fleetmate/planner-sync-state.json"
    ) {
        self.enabled = enabled
        self.planId = planId
        self.defaultBucketId = defaultBucketId
        self.statePath = statePath
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case planId = "plan_id"
        case defaultBucketId = "default_bucket_id"
        case statePath = "state_path"
    }
}

/// Markdown file sync configuration
public struct MarkdownSyncConfig: Codable {
    /// Whether markdown sync is enabled
    public var enabled: Bool
    
    /// Path to the planning repo/directory
    public var repoPath: String?
    
    /// Subdirectory for board markdown files
    public var boardsPath: String
    
    /// Subdirectory for individual task markdown files
    public var tasksPath: String
    
    /// Watch for file changes and auto-sync
    public var watchForChanges: Bool
    
    public init(
        enabled: Bool = false,
        repoPath: String? = nil,
        boardsPath: String = "boards",
        tasksPath: String = "tasks",
        watchForChanges: Bool = true
    ) {
        self.enabled = enabled
        self.repoPath = repoPath
        self.boardsPath = boardsPath
        self.tasksPath = tasksPath
        self.watchForChanges = watchForChanges
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case repoPath = "repo_path"
        case boardsPath = "boards_path"
        case tasksPath = "tasks_path"
        case watchForChanges = "watch_for_changes"
    }
}

// MARK: - TDX Authentication Method

/// Authentication method for TeamDynamix API
public enum TdxAuthMethod: String, Codable, CaseIterable, Sendable {
    /// Automatically choose best method: SSO if available, then service account, then user/password
    case auto = "auto"
    
    /// Browser-based SSO via Entra ID / Shibboleth (user context)
    /// All actions appear as the logged-in user
    case browserSSO = "browser_sso"
    
    /// Service account using BEID + WebServicesKey (admin context)
    /// Actions appear as the API service account
    case serviceAccount = "service_account"
    
    /// Traditional username/password authentication
    case userPassword = "user_password"
    
    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .browserSSO: return "Single Sign-On (SSO)"
        case .serviceAccount: return "Service Account"
        case .userPassword: return "Username/Password"
        }
    }
    
    public var description: String {
        switch self {
        case .auto: return "Automatically selects the best available method"
        case .browserSSO: return "Authenticate via your organization's identity provider"
        case .serviceAccount: return "Uses BEID and WebServicesKey for API access"
        case .userPassword: return "Traditional TDX username and password"
        }
    }
}
