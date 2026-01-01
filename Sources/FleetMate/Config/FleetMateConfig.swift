import Foundation
import Yams

/// Configuration for FleetMate
struct FleetMateConfig: Codable {
    // MunkiReport settings
    var munkiReportUrl: String = "https://munkireport.example.com"
    var munkiReportSshHost: String?
    var munkiReportSshUser: String = "ec2-user"
    var munkiReportSshKeyPath: String?
    var munkiReportDbPath: String = "/var/www/munkireport/app/db/db.sqlite"
    
    // Snipe-IT API settings
    var snipeUrl: String?
    var snipeApiKey: String?
    
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
    static func load() -> FleetMateConfig {
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
        if let url = ProcessInfo.processInfo.environment["MUNKIREPORT_URL"] {
            config.munkiReportUrl = url
        }
        if let host = ProcessInfo.processInfo.environment["MUNKIREPORT_SSH_HOST"] {
            config.munkiReportSshHost = host
        }
        if let user = ProcessInfo.processInfo.environment["MUNKIREPORT_SSH_USER"] {
            config.munkiReportSshUser = user
        }
        if let keyPath = ProcessInfo.processInfo.environment["MUNKIREPORT_SSH_KEY_PATH"] {
            config.munkiReportSshKeyPath = keyPath
        }
        if let snipeUrl = ProcessInfo.processInfo.environment["SNIPE_URL"] {
            config.snipeUrl = snipeUrl
        }
        if let snipeKey = ProcessInfo.processInfo.environment["SNIPE_API_KEY"] {
            config.snipeApiKey = snipeKey
        }
        
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
            
            switch key.uppercased() {
            case "MUNKIREPORT_URL": config.munkiReportUrl = value
            case "MUNKIREPORT_SSH_HOST": config.munkiReportSshHost = value
            case "MUNKIREPORT_SSH_USER": config.munkiReportSshUser = value
            case "MUNKIREPORT_SSH_KEY_PATH": config.munkiReportSshKeyPath = value
            case "SNIPE_URL": config.snipeUrl = value
            case "SNIPE_API_KEY": config.snipeApiKey = value
            default: break
            }
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
}
