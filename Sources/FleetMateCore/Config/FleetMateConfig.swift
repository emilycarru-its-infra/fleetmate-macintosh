import Foundation
import Yams

/// Configuration for FleetMate
///
/// Required Environment Variables:
/// - MUNKIREPORT_URL: MunkiReport instance URL
/// - MUNKIREPORT_SSH_HOST: SSH host for MunkiReport database access
/// - MUNKIREPORT_SSH_USER: SSH username
/// - MUNKIREPORT_SSH_KEY_PATH: Path to SSH private key
/// - MUNKIREPORT_DB_PATH: Path to MunkiReport SQLite database on remote host
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
    // MunkiReport settings (all required via environment)
    public var munkiReportUrl: String?
    var munkiReportSshHost: String?
    var munkiReportSshUser: String?
    var munkiReportSshKeyPath: String?
    var munkiReportDbPath: String?

    // Snipe-IT API settings
    var snipeUrl: String?
    var snipeApiKey: String?

    // Microsoft Graph (Intune/Entra) settings
    var graphTenantId: String?
    var graphClientId: String?
    var graphClientSecret: String?
    var graphPageSize: Int = 100

    // Azure DevOps settings
    var devopsOrganization: String?
    var devopsProject: String?
    var devopsPat: String?
    var devopsDefaultWorkItemType: String = "Bug"

    // TeamDynamix (TDX) settings
    var tdxBaseUrl: String?
    var tdxAppId: Int?
    var tdxUsername: String?
    var tdxPassword: String?
    var tdxBeid: String?
    var tdxWebServicesKey: String?
    var tdxDefaultTypeId: Int?
    var tdxDefaultStatusId: Int?
    var tdxDefaultPriorityId: Int?
    var tdxDefaultSourceId: Int?
    var tdxDefaultAccountId: Int?

    // Deployment repo paths
    var deploymentPath: String = "deployment"
    var pkgsinfoPath: String = "deployment/pkgsinfo"
    var pkgsPath: String = "deployment/pkgs"
    var manifestsPath: String = "deployment/manifests"
    var catalogsPath: String = "deployment/catalogs"

    // Local paths
    var packagesPath: String = "packages"
    var logPath: String = "~/Library/Logs/FleetMate"
    var logLevel: String = "info"
    var cacheMinutes: Int = 5

    // Repo root (detected at runtime)
    var repoRoot: String?

    enum CodingKeys: String, CodingKey {
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

    /// Load configuration from file and environment
    static func load() throws -> FleetMateConfig {
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

        // Environment variables override
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

        // MunkiReport
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
    }

    private static func applyConfigValue(key: String, value: String, to config: inout FleetMateConfig) {
        switch key {
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
    func resolvePath(_ relativePath: String) -> String {
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

    /// Check if MunkiReport is configured
    var isMunkiReportConfigured: Bool {
        return munkiReportUrl != nil
    }

    /// Check if MunkiReport SSH access is configured
    var isMunkiReportSshConfigured: Bool {
        return munkiReportSshHost != nil && munkiReportSshUser != nil && munkiReportDbPath != nil
    }

    /// Check if Snipe-IT is configured
    var isSnipeConfigured: Bool {
        return snipeUrl != nil && snipeApiKey != nil
    }

    /// Check if Graph is configured
    var isGraphConfigured: Bool {
        return graphTenantId != nil && graphClientId != nil
    }

    /// Check if DevOps is configured
    var isDevOpsConfigured: Bool {
        return devopsOrganization != nil && devopsProject != nil
    }

    /// Check if TDX is configured
    var isTdxConfigured: Bool {
        return tdxBaseUrl != nil && tdxAppId != nil &&
               ((tdxUsername != nil && tdxPassword != nil) || (tdxBeid != nil && tdxWebServicesKey != nil))
    }

    /// Get TDX tickets URL
    func tdxTicketsUrl(_ suffix: String = "") -> String {
        let base = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appId = tdxAppId ?? 0
        if suffix.isEmpty {
            return "\(base)/api/\(appId)/tickets"
        }
        return "\(base)/api/\(appId)/tickets/\(suffix)"
    }
}
