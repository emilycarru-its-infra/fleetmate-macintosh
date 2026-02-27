import ArgumentParser
import Foundation
import Rainbow
import FleetMateCore

/// Configure command - Manage FleetMate credentials in Keychain
struct ConfigureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Manage FleetMate credentials in Keychain",
        discussion: """
            Securely store and manage API credentials in macOS Keychain.
            Credentials can be imported from environment variables or set interactively.
            """,
        subcommands: [
            SetSubcommand.self,
            GetSubcommand.self,
            ListSubcommand.self,
            ImportSubcommand.self,
            ClearSubcommand.self,
            ValidateSubcommand.self
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - Set Credential

struct SetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a credential in Keychain"
    )
    
    @Argument(help: "The credential key to set")
    var key: String
    
    @Option(name: .shortAndLong, help: "The value to set (omit for secure prompt)")
    var value: String?
    
    func run() async throws {
        let keychain = KeychainService.shared
        
        guard let keychainKey = KeychainService.Key(rawValue: key) else {
            print("[ERROR] Unknown key: \(key)".red)
            print("\nAvailable keys:")
            for k in KeychainService.Key.allCases {
                print("  - \(k.rawValue)")
            }
            throw ExitCode.failure
        }
        
        let finalValue: String
        if let v = value {
            finalValue = v
        } else {
            // Prompt for value securely
            print("Enter value for \(key): ", terminator: "")
            fflush(stdout)
            
            // Disable echo for password input
            var term = termios()
            tcgetattr(STDIN_FILENO, &term)
            let originalFlags = term.c_lflag
            term.c_lflag &= ~UInt(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &term)
            
            guard let input = readLine() else {
                term.c_lflag = originalFlags
                tcsetattr(STDIN_FILENO, TCSANOW, &term)
                print("\n[ERROR] No input provided".red)
                throw ExitCode.failure
            }
            
            // Restore echo
            term.c_lflag = originalFlags
            tcsetattr(STDIN_FILENO, TCSANOW, &term)
            print("") // New line after hidden input
            
            finalValue = input
        }
        
        do {
            try keychain.save(finalValue, for: keychainKey)
            print("[ok] Saved \(key) to Keychain".green)
        } catch {
            print("[ERROR] Failed to save: \(error.localizedDescription)".red)
            throw ExitCode.failure
        }
    }
}

// MARK: - Get Credential

struct GetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a credential from Keychain"
    )
    
    @Argument(help: "The credential key to get")
    var key: String
    
    @Flag(name: .shortAndLong, help: "Show the actual value (default: masked)")
    var reveal: Bool = false
    
    func run() async throws {
        let keychain = KeychainService.shared
        
        guard let keychainKey = KeychainService.Key(rawValue: key) else {
            print("[ERROR] Unknown key: \(key)".red)
            throw ExitCode.failure
        }
        
        guard let value = keychain.get(keychainKey) else {
            print("[ERROR] No value found for \(key)".yellow)
            throw ExitCode.failure
        }
        
        if reveal {
            print(value)
        } else {
            let masked = String(value.prefix(4)) + "****" + String(value.suffix(4))
            print("\(key): \(masked)")
        }
    }
}

// MARK: - List Credentials

struct ListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured credentials"
    )
    
    @Flag(name: .shortAndLong, help: "Show configuration status only")
    var status: Bool = false
    
    func run() async throws {
        let keychain = KeychainService.shared
        
        print("\n" + "FleetMate Keychain Credentials".bold + "\n")
        
        let groups: [(String, [KeychainService.Key])] = [
            ("ReportMate", [.reportMateUrl, .reportMatePassphrase]),
            ("Snipe-IT", [.snipeUrl, .snipeApiKey]),
            ("Microsoft Graph", [.graphTenantId, .graphClientId, .graphClientSecret]),
            ("Azure DevOps", [.devopsOrganization, .devopsProject]),
            ("TDX (TeamDynamix)", [.tdxBaseUrl, .tdxBeid, .tdxAppId, .tdxUsername, .tdxPassword]),
            ("Secure Shell", [.sshPrivateKey, .sshKeyVaultName, .sshKeyPath])
        ]
        
        for (groupName, keys) in groups {
            print(groupName.bold.cyan + ":")
            
            var allConfigured = true
            for key in keys {
                let hasValue = keychain.exists(key)
                let indicator = hasValue ? "yes".green : "no".red
                print("  \(indicator) \(key.rawValue)")
                if !hasValue { allConfigured = false }
            }
            
            if status && allConfigured {
                print("  " + "→ Fully configured".green)
            }
            print("")
        }
        
        if status {
            printConfigurationSummary()
        }
    }
    
    private func printConfigurationSummary() {
        print("Configuration Summary".bold + "\n")
        
        do {
            let config = try FleetMateConfig.load()
            
            let checks: [(String, Bool)] = [
                ("ReportMate", config.isReportMateConfigured),
                ("Snipe-IT", config.snipeApiKey != nil),
                ("Graph/Entra", config.graphTenantId != nil && config.graphClientId != nil),
                ("Azure DevOps", config.devopsOrganization != nil),
                ("TDX", config.tdxUsername != nil),
                ("Secure Shell", config.isSecureShellConfigured)
            ]
            
            for (name, configured) in checks {
                let status = configured ? "[ok] Ready".green : "[ERROR] Not configured".red
                print("  \(name): \(status)")
            }
        } catch {
            print("  [WARNING] Could not load config: \(error.localizedDescription)".yellow)
        }
        
        print("")
    }
}

// MARK: - Import from Environment

struct ImportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import credentials from environment variables"
    )
    
    @Flag(name: .shortAndLong, help: "Overwrite existing values")
    var force: Bool = false
    
    @Flag(name: .shortAndLong, help: "Dry run - show what would be imported")
    var dryRun: Bool = false
    
    func run() async throws {
        let keychain = KeychainService.shared
        
        print("\n" + "Importing credentials from environment...".bold + "\n")
        
        let mappings: [(envVar: String, key: KeychainService.Key)] = [
            // ReportMate
            ("REPORTMATE_URL", .reportMateUrl),
            ("REPORTMATE_PASSPHRASE", .reportMatePassphrase),
            // Snipe-IT
            ("SNIPE_API_KEY", .snipeApiKey),
            ("SNIPE_URL", .snipeUrl),
            // Graph
            ("GRAPH_TENANT_ID", .graphTenantId),
            ("GRAPH_CLIENT_ID", .graphClientId),
            ("GRAPH_CLIENT_SECRET", .graphClientSecret),
            ("AZURE_TENANT_ID", .graphTenantId),  // Alternative name
            // DevOps (NO PAT — Azure DevOps uses SSO only)
            ("DEVOPS_ORGANIZATION", .devopsOrganization),
            ("DEVOPS_PROJECT", .devopsProject),
            // TDX
            ("TDX_BASE_URL", .tdxBaseUrl),
            ("TDX_BEID", .tdxBeid),
            ("TDX_APP_ID", .tdxAppId),
            ("TDX_USERNAME", .tdxUsername),
            ("TDX_PASSWORD", .tdxPassword),
            ("TDX_WEB_SERVICES_KEY", .tdxWebServicesKey),
            // SecureShell
            ("SECURE_SHELL_PRIVATE_KEY_PATH", .sshKeyPath),
            ("SECURE_SHELL_KEY_VAULT_NAME", .sshKeyVaultName)
        ]
        
        var imported = 0
        var skipped = 0
        var notFound = 0
        
        for (envVar, key) in mappings {
            guard let value = ProcessInfo.processInfo.environment[envVar], !value.isEmpty else {
                notFound += 1
                continue
            }
            
            let existing = keychain.get(key)
            if existing != nil && !force {
                print("⏭️  \(envVar) → \(key.rawValue) (already exists, use --force to overwrite)".yellow)
                skipped += 1
                continue
            }
            
            if dryRun {
                let preview = String(value.prefix(4)) + "****"
                print("\(envVar) → \(key.rawValue) = \(preview)")
            } else {
                do {
                    try keychain.save(value, for: key)
                    print("[ok] \(envVar) → \(key.rawValue)".green)
                    imported += 1
                } catch {
                    print("[ERROR] Failed to save \(key.rawValue): \(error)".red)
                }
            }
        }
        
        print("")
        if dryRun {
            print("Dry run complete. Use without --dry-run to apply changes.")
        } else {
            print("Import complete: \(imported) imported, \(skipped) skipped, \(notFound) not found in environment")
        }
    }
}

// MARK: - Clear Credentials

struct ClearSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear credentials from Keychain"
    )
    
    @Argument(help: "Specific key to clear (or 'all' for everything)")
    var key: String?
    
    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force: Bool = false
    
    func run() async throws {
        let keychain = KeychainService.shared
        
        if let keyName = key, keyName.lowercased() != "all" {
            // Clear specific key
            guard let keychainKey = KeychainService.Key(rawValue: keyName) else {
                print("[ERROR] Unknown key: \(keyName)".red)
                throw ExitCode.failure
            }
            
            if !force {
                print("Clear \(keyName) from Keychain? (y/N): ", terminator: "")
                guard let confirm = readLine()?.lowercased(), confirm == "y" || confirm == "yes" else {
                    print("Cancelled.")
                    return
                }
            }
            
            try keychain.delete(keychainKey)
            print("[ok] Cleared \(keyName) from Keychain".green)
        } else {
            // Clear all
            if !force {
                print("[WARNING] This will clear ALL FleetMate credentials from Keychain!".yellow.bold)
                print("Are you sure? (type 'yes' to confirm): ", terminator: "")
                guard let confirm = readLine()?.lowercased(), confirm == "yes" else {
                    print("Cancelled.")
                    return
                }
            }
            
            try keychain.clearAll()
            print("[ok] All FleetMate credentials cleared from Keychain".green)
        }
    }
}

// MARK: - Validate Configuration

struct ValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate API connections"
    )
    
    @Flag(name: .shortAndLong, help: "Test all configured services")
    var all: Bool = false
    
    @Option(name: .shortAndLong, help: "Specific service to test (reportmate, snipe, graph, devops, tdx)")
    var service: String?
    
    func run() async throws {
        print("\n" + "Validating API Connections...".bold + "\n")
        
        let config = try FleetMateConfig.load()
        
        let services = service.map { [$0.lowercased()] } ?? 
            (all ? ["reportmate", "snipe", "graph", "devops", "tdx"] : ["reportmate", "snipe"])
        
        for svc in services {
            switch svc {
            case "reportmate":
                await validateReportMate(config: config)
            case "snipe":
                await validateSnipe(config: config)
            case "graph":
                await validateGraph(config: config)
            case "devops":
                await validateDevOps(config: config)
            case "tdx":
                await validateTdx(config: config)
            default:
                print("[WARNING] Unknown service: \(svc)".yellow)
            }
        }
        
        print("")
    }
    
    private func validateReportMate(config: FleetMateConfig) async {
        print("ReportMate: ", terminator: "")
        
        guard config.isReportMateConfigured else {
            print("[ERROR] Not configured".red)
            return
        }
        
        let service = ReportMateService(config: config)
        do {
            let devices = try await service.getDevices()
            print("[ok] Connected (\(devices.count) devices)".green)
        } catch {
            print("[ERROR] Failed: \(error.localizedDescription)".red)
        }
    }
    
    private func validateSnipe(config: FleetMateConfig) async {
        print("Snipe-IT: ", terminator: "")
        
        guard config.snipeApiKey != nil else {
            print("[ERROR] Not configured".red)
            return
        }
        
        let service = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey, cacheMinutes: config.cacheMinutes)
        do {
            let assets = try await service.getAssets()
            print("[ok] Connected (\(assets.count) assets)".green)
        } catch {
            print("[ERROR] Failed: \(error.localizedDescription)".red)
        }
    }
    
    private func validateGraph(config: FleetMateConfig) async {
        print("Microsoft Graph: ", terminator: "")
        
        guard config.graphTenantId != nil else {
            print("[ERROR] Not configured".red)
            return
        }
        
        let service = GraphService(config: config)
        if service.isConfigured {
            print("[ok] Configured (test connection during device queries)".green)
        } else {
            print("[WARNING] Credentials set but not validated".yellow)
        }
    }
    
    private func validateDevOps(config: FleetMateConfig) async {
        print("Azure DevOps: ", terminator: "")
        // NO PAT — Azure DevOps uses SSO only (browser OAuth2 or Azure CLI with Platform SSO)
        guard config.isDevOpsConfigured else {
            print("[ERROR] Not configured (need organization + project)".red)
            return
        }
        
        let service = AzureDevOpsService(config: config)
        if service.isConfigured {
            print("[ok] Configured (SSO auth, test connection during work item queries)".green)
        } else {
            print("[WARNING] Organization/project set but not validated".yellow)
        }
    }
    
    private func validateTdx(config: FleetMateConfig) async {
        print("TeamDynamix: ", terminator: "")
        
        guard config.tdxUsername != nil || config.tdxBeid != nil else {
            print("[ERROR] Not configured".red)
            return
        }
        
        let service = TdxService(config: config)
        if service.isConfigured {
            print("[ok] Configured (test connection during ticket queries)".green)
        } else {
            print("[WARNING] Credentials set but not validated".yellow)
        }
    }
}
