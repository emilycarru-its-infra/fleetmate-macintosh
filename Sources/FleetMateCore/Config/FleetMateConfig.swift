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
/// - DEVOPS_CLIENT_ID: Azure AD app client ID for OAuth2 SSO (optional)
/// - DEVOPS_TENANT_ID: Azure AD tenant ID for OAuth2 SSO (optional)
/// NOTE: NO PAT (Personal Access Token) — Azure DevOps uses SSO only.
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

    // Snipe-IT settings
    public var snipeUrl: String?
    public var snipeApiKey: String?
    public var snipeAuthMethod: SnipeAuthMethod = .auto
    public var snipeSsoEnabled: Bool = true

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
    // NO PAT — Azure DevOps uses SSO only (browser OAuth2 or Azure CLI with Platform SSO).
    public var devopsOrganization: String?
    public var devopsProject: String?
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
        // NO PAT — Azure DevOps uses SSO only
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

    static let configPath = "~/.fleetmate/config.yaml"

    /// Load configuration.
    ///
    /// Priority (lowest → highest):
    /// 1. `~/.fleetmate/config.yaml`  — structural/non-credential settings (tasks, paths, etc.)
    /// 2. Keychain                    — all credential values written by the Settings UI
    /// 3. Environment variables       — CI/CD override; use `KeychainService.importFromEnvironment()`
    ///                                  to pre-seed Keychain, or just rely on env vars passthrough
    public static func load() throws -> FleetMateConfig {
        var config = FleetMateConfig()

        // 1. Structural config from file (tasks, secureShell, paths, log level, etc.)
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            if let loaded = loadFromFile(path: expandedPath) {
                config = loaded
            } else {
                // Codable decode failed — fall back to dictionary loader for nested sections
                loadConfigDictionary(path: expandedPath, into: &config)
            }
        }

        // 2. Credentials from Keychain (overrides any credentials that happened to be in the file)
        loadFromKeychain(into: &config)

        // 3. Environment variables override everything (CI/CD)
        loadEnvironmentVariables(into: &config)

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

    /// Fallback dictionary-based config loader for nested sections (tasks, secureShell, etc.)
    /// Handles both camelCase YAML keys and the proper Codable snake_case keys.
    private static func loadConfigDictionary(path: String, into config: inout FleetMateConfig) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let yaml = try? Yams.load(yaml: contents) as? [String: Any] else { return }

        // SecureShell (camelCase in existing YAML)
        if let ssh = (yaml["secureShell"] ?? yaml["secure_shell"]) as? [String: Any] {
            var s = config.secureShell ?? SecureShellConfig()
            if let v = ssh["privateKeyPath"] as? String { s.privateKeyPath = v }
            if let v = ssh["privateKeyEnvVar"] as? String { s.privateKeyEnvVar = v }
            if let v = ssh["keyVaultName"] as? String { s.keyVaultName = v }
            if let v = ssh["defaultUsername"] as? String { s.defaultUsername = v }
            if let v = ssh["connectionTimeoutSeconds"] as? Int { s.connectionTimeoutSeconds = v }
            if let v = ssh["commandTimeoutSeconds"] as? Int { s.commandTimeoutSeconds = v }
            if let v = ssh["maxConcurrentConnections"] as? Int { s.maxConcurrentConnections = v }
            if let v = ssh["port"] as? Int { s.port = v }
            config.secureShell = s
        }

        // Graph
        if let graph = yaml["graph"] as? [String: Any] {
            if let v = graph["useAzureCliAuth"] as? Bool, v { /* stored elsewhere */ }
        }

        // TDX (camelCase in existing YAML)
        if let tdx = yaml["tdx"] as? [String: Any] {
            if let v = tdx["baseUrl"] as? String { config.tdxBaseUrl = v }
            if let v = tdx["appId"] as? Int { config.tdxAppId = v }
        }

        // Log level
        if let ll = (yaml["logLevel"] ?? yaml["log_level"]) as? String {
            config.logLevel = ll
        }

        // Tasks — nested section (snake_case keys matching CodingKeys)
        if let tasks = yaml["tasks"] as? [String: Any],
           let providers = tasks["providers"] as? [String: Any] {
            var tasksConfig = config.tasks ?? TasksConfig()
            var providersConfig = tasksConfig.providers

            // Azure DevOps provider
            if let ado = providers["azdevops"] as? [String: Any] {
                var adoConfig = providersConfig.azdevops ?? AzureDevOpsProviderConfig()
                if let v = ado["enabled"] as? Bool { adoConfig.enabled = v }
                if let v = ado["organization"] as? String { adoConfig.organization = v }
                if let v = ado["project"] as? String { adoConfig.project = v }
                if let v = ado["default_work_item_type"] as? String { adoConfig.defaultWorkItemType = v }
                if let v = ado["area_path"] as? String { adoConfig.areaPath = v }
                if let v = ado["iteration_path"] as? String { adoConfig.iterationPath = v }
                providersConfig.azdevops = adoConfig
            }

            // GitHub provider
            if let gh = providers["github"] as? [String: Any] {
                var ghConfig = providersConfig.github ?? GitHubProviderConfig()
                if let v = gh["enabled"] as? Bool { ghConfig.enabled = v }
                if let v = gh["owner"] as? String { ghConfig.owner = v }
                if let v = gh["repo"] as? String { ghConfig.repo = v }
                if let v = gh["token"] as? String { ghConfig.token = v }
                if let v = gh["organization"] as? String { ghConfig.organization = v }
                if let v = gh["project_number"] as? Int { ghConfig.projectNumber = v }
                if let v = gh["project_scope"] as? String { ghConfig.projectScope = v }
                if let v = gh["use_gh_cli"] as? Bool { ghConfig.useGhCli = v }
                if let v = gh["oauth_client_id"] as? String { ghConfig.oauthClientId = v }
                if let v = gh["default_labels"] as? [String] { ghConfig.defaultLabels = v }
                providersConfig.github = ghConfig
            }

            // Gitea provider
            if let gt = providers["gitea"] as? [String: Any] {
                var gtConfig = providersConfig.gitea ?? GiteaProviderConfig()
                if let v = gt["enabled"] as? Bool { gtConfig.enabled = v }
                if let v = gt["url"] as? String { gtConfig.url = v }
                if let v = gt["owner"] as? String { gtConfig.owner = v }
                if let v = gt["repo"] as? String { gtConfig.repo = v }
                if let v = gt["token"] as? String { gtConfig.token = v }
                if let v = gt["default_labels"] as? [String] { gtConfig.defaultLabels = v }
                providersConfig.gitea = gtConfig
            }

            tasksConfig.providers = providersConfig
            if let dp = tasks["default_provider"] as? String { tasksConfig.defaultProvider = dp }
            config.tasks = tasksConfig
        }
    }
    
    /// Load credentials from JSON file (previously Keychain).
    private static func loadFromKeychain(into config: inout FleetMateConfig) {
        let path = NSString(string: credentialsPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            // Fall back to legacy Keychain read
            loadFromKeychainLegacy(into: &config)
            return
        }

        func get(_ key: String) -> String? { creds[key] }
        func getInt(_ key: String) -> Int? { creds[key].flatMap(Int.init) }

        if let v = get("reportMateUrl")      { config.reportMateUrl = v }
        if let v = get("reportMatePassphrase") { config.reportMatePassphrase = v }
        if let v = get("snipeUrl")           { config.snipeUrl = v }
        if let v = get("snipeApiKey")        { config.snipeApiKey = v }
        if let v = get("graphTenantId")      { config.graphTenantId = v }
        if let v = get("graphClientId")      { config.graphClientId = v }
        if let v = get("graphClientSecret")  { config.graphClientSecret = v }
        if let v = get("devicesGraphId")     { config.devicesGraphId = v }
        if let v = get("devicesGraphSecret") { config.devicesGraphSecret = v }
        if let v = get("systemsGraphId")     { config.systemsGraphId = v }
        if let v = get("systemsGraphSecret") { config.systemsGraphSecret = v }
        if let v = get("devopsOrganization") { config.devopsOrganization = v }
        if let v = get("devopsProject")      { config.devopsProject = v }
        if let v = get("devopsClientId")     { config.devopsClientId = v }
        if let v = get("devopsTenantId")     { config.devopsTenantId = v }
        if let v = get("tdxBaseUrl")         { config.tdxBaseUrl = v }
        if let id = getInt("tdxAppId")       { config.tdxAppId = id }
        if let id = getInt("tdxTicketingAppId") { config.tdxTicketingAppId = id }
        if let id = getInt("tdxAssetsAppId") { config.tdxAssetsAppId = id }
        if let v = get("tdxUsername")        { config.tdxUsername = v }
        if let v = get("tdxPassword")        { config.tdxPassword = v }
        if let v = get("tdxBeid")            { config.tdxBeid = v }
        if let v = get("tdxWebServicesKey")  { config.tdxWebServicesKey = v }
        if let id = getInt("tdxResponsibleGroupId") { config.tdxResponsibleGroupId = id }
        if let v = get("sshKeyPath") {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.privateKeyPath = v
        }
        if let v = get("sshDefaultUsername") {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.defaultUsername = v
        }
        if let v = get("sshKeyVaultName") {
            if config.secureShell == nil { config.secureShell = SecureShellConfig() }
            config.secureShell?.keyVaultName = v
        }
    }

    /// Legacy Keychain loader — used when credentials.json doesn't exist yet
    private static func loadFromKeychainLegacy(into config: inout FleetMateConfig) {
        let kc = KeychainService.shared
        if let v = kc.get(.reportMateUrl)        { config.reportMateUrl = v }
        if let v = kc.get(.reportMatePassphrase)  { config.reportMatePassphrase = v }
        if let v = kc.get(.snipeUrl)    { config.snipeUrl = v }
        if let v = kc.get(.snipeApiKey) { config.snipeApiKey = v }
        if let v = kc.get(.graphTenantId) { config.graphTenantId = v }
        if let v = kc.get(.graphClientId)     { config.graphClientId = v }
        if let v = kc.get(.graphClientSecret) { config.graphClientSecret = v }
        if let v = kc.get(.devicesGraphId)     { config.devicesGraphId = v }
        if let v = kc.get(.devicesGraphSecret) { config.devicesGraphSecret = v }
        if let v = kc.get(.systemsGraphId)     { config.systemsGraphId = v }
        if let v = kc.get(.systemsGraphSecret) { config.systemsGraphSecret = v }
        if let v = kc.get(.devopsOrganization) { config.devopsOrganization = v }
        if let v = kc.get(.devopsProject)      { config.devopsProject = v }
        if let v = kc.get(.devopsClientId)     { config.devopsClientId = v }
        if let v = kc.get(.devopsTenantId)     { config.devopsTenantId = v }
        if let v = kc.get(.tdxBaseUrl)         { config.tdxBaseUrl = v }
        if let v = kc.get(.tdxAppId),       let id = Int(v) { config.tdxAppId = id }
        if let v = kc.get(.tdxTicketingAppId), let id = Int(v) { config.tdxTicketingAppId = id }
        if let v = kc.get(.tdxAssetsAppId),    let id = Int(v) { config.tdxAssetsAppId = id }
        if let v = kc.get(.tdxUsername)        { config.tdxUsername = v }
        if let v = kc.get(.tdxPassword)        { config.tdxPassword = v }
        if let v = kc.get(.tdxBeid)            { config.tdxBeid = v }
        if let v = kc.get(.tdxWebServicesKey)  { config.tdxWebServicesKey = v }
        if let v = kc.get(.tdxResponsibleGroupId), let id = Int(v) { config.tdxResponsibleGroupId = id }
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
        // NO PAT — Azure DevOps uses SSO only
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

    /// Check if Snipe-IT is configured (API key or SSO mode)
    public var isSnipeConfigured: Bool {
        guard snipeUrl != nil else { return false }
        if snipeAuthMethod == .browserSSO || snipeSsoEnabled { return true }
        return snipeApiKey != nil
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

    /// Check if DevOps is configured (org is enough — project can be auto-discovered)
    public var isDevOpsConfigured: Bool {
        return devopsOrganization != nil || tasks?.providers.azdevops?.organization != nil
    }

    /// Check if TDX is configured (credentials or SSO mode)
    public var isTdxConfigured: Bool {
        guard tdxBaseUrl != nil, (tdxAppId != nil || tdxTicketingAppId != nil) else { return false }
        if tdxAuthMethod == .browserSSO || tdxSsoEnabled { return true }
        return (tdxUsername != nil && tdxPassword != nil) || (tdxBeid != nil && tdxWebServicesKey != nil)
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
    /// TDX API base — auto-appends /TDWebApi if the URL is just the hostname
    private var tdxApiBase: String {
        let raw = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !raw.isEmpty && !raw.contains("/TDWebApi") && !raw.hasSuffix("/api") {
            return "\(raw)/TDWebApi"
        }
        return raw
    }

    public func tdxTicketsUrl(_ suffix: String = "") -> String {
        let appId = tdxTicketingAppId ?? tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(tdxApiBase)/api/\(appId)/tickets"
        }
        return "\(tdxApiBase)/api/\(appId)/tickets/\(suffix)"
    }

    /// Get TDX assets URL
    public func tdxAssetsUrl(_ suffix: String = "") -> String {
        let appId = tdxAssetsAppId ?? tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(tdxApiBase)/api/\(appId)/assets"
        }
        return "\(tdxApiBase)/api/\(appId)/assets/\(suffix)"
    }

    /// Get TDX people URL (not app-scoped)
    public func tdxPeopleUrl(_ suffix: String = "") -> String {
        let base = tdxApiBase
        if suffix.isEmpty {
            return "\(base)/api/people"
        }
        return "\(base)/api/people/\(suffix)"
    }

    // MARK: - Persist

    /// Write all credential fields to the macOS Keychain.
    /// Called directly by the Settings UI — no files involved.
    /// Path for the credentials JSON file (alongside config.yaml)
    private static let credentialsPath = "~/.fleetmate/credentials.json"

    public static func saveToKeychain(_ config: FleetMateConfig) throws {
        // Save credentials as a JSON file — more reliable than per-key Keychain entries
        let path = NSString(string: credentialsPath).expandingTildeInPath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var creds: [String: String] = [:]

        func set(_ key: String, _ value: String?) {
            if let v = value, !v.isEmpty { creds[key] = v }
        }
        func setInt(_ key: String, _ value: Int?) {
            if let v = value { creds[key] = String(v) }
        }

        set("reportMateUrl", config.reportMateUrl)
        set("reportMatePassphrase", config.reportMatePassphrase)
        set("snipeUrl", config.snipeUrl)
        set("snipeApiKey", config.snipeApiKey)
        set("graphTenantId", config.graphTenantId)
        set("graphClientId", config.graphClientId)
        set("graphClientSecret", config.graphClientSecret)
        set("devicesGraphId", config.devicesGraphId)
        set("devicesGraphSecret", config.devicesGraphSecret)
        set("systemsGraphId", config.systemsGraphId)
        set("systemsGraphSecret", config.systemsGraphSecret)
        set("devopsOrganization", config.devopsOrganization)
        set("devopsProject", config.devopsProject)
        set("devopsClientId", config.devopsClientId)
        set("devopsTenantId", config.devopsTenantId)
        set("tdxBaseUrl", config.tdxBaseUrl)
        setInt("tdxAppId", config.tdxAppId)
        setInt("tdxTicketingAppId", config.tdxTicketingAppId)
        setInt("tdxAssetsAppId", config.tdxAssetsAppId)
        set("tdxUsername", config.tdxUsername)
        set("tdxPassword", config.tdxPassword)
        set("tdxBeid", config.tdxBeid)
        set("tdxWebServicesKey", config.tdxWebServicesKey)
        setInt("tdxResponsibleGroupId", config.tdxResponsibleGroupId)
        set("sshKeyPath", config.secureShell?.privateKeyPath)
        set("sshDefaultUsername", config.secureShell?.defaultUsername)
        set("sshKeyVaultName", config.secureShell?.keyVaultName)

        let data = try JSONSerialization.data(withJSONObject: creds, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        dbg.info("[SaveCreds] Wrote \(creds.count) keys to \(path)", category: "config")
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent(TaskProvidersConfig.self, forKey: .providers) ?? TaskProvidersConfig()
        planner = try container.decodeIfPresent(PlannerSyncConfig.self, forKey: .planner)
        markdown = try container.decodeIfPresent(MarkdownSyncConfig.self, forKey: .markdown)
        defaultProvider = try container.decodeIfPresent(String.self, forKey: .defaultProvider) ?? "azdevops"
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
    
    /// GitHub OAuth App client ID for Device Flow authentication.
    /// Register at github.com/settings/applications/new with "Device" grant type enabled.
    /// Enables invisible token acquisition with no config required for the end user.
    public var oauthClientId: String?
    
    /// Organization name for org-level Projects v2 queries
    public var organization: String?
    
    /// Default project number to use
    public var projectNumber: Int?
    
    /// Default scope for project queries (organization, user, repository)
    public var projectScope: String
    
    public init(
        enabled: Bool = false,
        owner: String? = nil,
        repo: String? = nil,
        token: String? = nil,
        defaultLabels: [String] = [],
        useGhCli: Bool = true,
        oauthClientId: String? = nil,
        organization: String? = nil,
        projectNumber: Int? = nil,
        projectScope: String = "organization"
    ) {
        self.enabled = enabled
        self.owner = owner
        self.repo = repo
        self.token = token
        self.defaultLabels = defaultLabels
        self.useGhCli = useGhCli
        self.oauthClientId = oauthClientId
        self.organization = organization
        self.projectNumber = projectNumber
        self.projectScope = projectScope
    }
    
    enum CodingKeys: String, CodingKey {
        case enabled
        case owner
        case repo
        case token
        case defaultLabels = "default_labels"
        case useGhCli = "use_gh_cli"
        case oauthClientId = "oauth_client_id"
        case organization
        case projectNumber = "project_number"
        case projectScope = "project_scope"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        defaultLabels = try container.decodeIfPresent([String].self, forKey: .defaultLabels) ?? []
        useGhCli = try container.decodeIfPresent(Bool.self, forKey: .useGhCli) ?? true
        oauthClientId = try container.decodeIfPresent(String.self, forKey: .oauthClientId)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        projectNumber = try container.decodeIfPresent(Int.self, forKey: .projectNumber)
        projectScope = try container.decodeIfPresent(String.self, forKey: .projectScope) ?? "organization"
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
/// - Note: Planner sync is deprecated. Use GitHub Projects v2 via the 'projects' command.
public struct PlannerSyncConfig: Codable {
    /// Whether Planner sync is enabled (deprecated — use GitHub Projects v2 instead)
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

// MARK: - Snipe-IT Authentication Method

public enum SnipeAuthMethod: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case browserSSO = "browser_sso"
    case apiKey = "api_key"
}
