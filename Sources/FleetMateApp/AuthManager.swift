import Foundation
import FleetMateCore

/// Centralized manager that tracks authentication state for every configured system.
/// Published on AppState so any view can observe status changes.
@MainActor
class AuthManager: ObservableObject {
    @Published var systems: [AuthSystemId: AuthSystemStatus] = [:]
    
    private let config: FleetMateConfig
    
    init(config: FleetMateConfig) {
        self.config = config
        bootstrapFromConfig()
    }
    
    // MARK: - Bootstrap
    
    /// Populate initial states from config: configured systems get `.configured`,
    /// unconfigured ones are omitted entirely (as if they don't exist).
    func bootstrapFromConfig() {
        systems.removeAll()
        
        // Devices — Graph / Intune
        if config.isGraphConfigured {
            systems[.intune] = AuthSystemStatus(systemId: .intune, state: .configured)
            systems[.graph]  = AuthSystemStatus(systemId: .graph,  state: .configured)
        }
        
        // Assets — Snipe-IT
        if config.isSnipeConfigured {
            systems[.snipe] = AuthSystemStatus(systemId: .snipe, state: .configured)
        }
        
        // Tickets — TDX
        if config.isTdxConfigured {
            systems[.tdx] = AuthSystemStatus(systemId: .tdx, state: .configured)
        }
        
        // Projects — DevOps
        if config.isDevOpsConfigured {
            systems[.devops] = AuthSystemStatus(systemId: .devops, state: .configured)
        }
        
        // Projects — GitHub
        if let gh = config.tasks?.providers.github, gh.enabled {
            systems[.github] = AuthSystemStatus(systemId: .github, state: .configured)
        }
        
        // Projects — Gitea
        if let gt = config.tasks?.providers.gitea, gt.enabled {
            systems[.gitea] = AuthSystemStatus(systemId: .gitea, state: .configured)
        }
        
        // Identity — Entra
        if config.isSystemsGraphConfigured {
            systems[.entra] = AuthSystemStatus(systemId: .entra, state: .configured)
        }
    }
    
    // MARK: - State Updates
    
    func update(_ id: AuthSystemId, state: AuthTokenState) {
        guard systems[id] != nil else { return }
        systems[id]?.state = state
        systems[id]?.lastChecked = Date()
        if case .valid(let user, _) = state {
            systems[id]?.user = user
        }
    }
    
    // MARK: - Queries
    
    /// All configured systems (those that appear in the UI).
    var configuredSystems: [AuthSystemStatus] {
        AuthSystemId.allCases.compactMap { systems[$0] }
    }
    
    /// Systems for a given category/tab.
    func systems(for category: AuthCategory) -> [AuthSystemStatus] {
        configuredSystems.filter { $0.systemId.category == category }
    }
    
    /// Overall health for a category (used for tab badge).
    func categoryHealth(_ category: AuthCategory) -> AuthTokenState {
        let items = systems(for: category)
        guard !items.isEmpty else { return .notConfigured }
        if items.allSatisfy({ $0.state.isHealthy }) { return .valid(user: nil, expiry: nil) }
        if items.contains(where: { if case .failed = $0.state { return true }; return false }) {
            return .failed(message: "")
        }
        if items.contains(where: { if case .servicePrincipal = $0.state { return true }; return false }) {
            return .servicePrincipal(name: "")
        }
        return .configured
    }
    
    /// True if any system is logged in as a Service Principal.
    var hasServicePrincipalWarning: Bool {
        systems.values.contains { if case .servicePrincipal = $0.state { return true }; return false }
    }
    
    // MARK: - Probe All

    /// Validate/probe each configured system asynchronously. Called once on launch 
    /// and again whenever config is reloaded.
    func probeAll(
        graphService: GraphService,
        tdxService: TdxService,
        snipeService: SnipeService,
        devOpsService: AzureDevOpsService
    ) async {
        // Graph / Intune
        if systems[.graph] != nil {
            update(.graph, state: .authenticating)
            update(.intune, state: .authenticating)
            do {
                // Attempt a lightweight Graph call
                _ = try await graphService.getManagedDevices(limit: 1)
                update(.graph,  state: .valid(user: "Service Credential", expiry: nil))
                update(.intune, state: .valid(user: "Service Credential", expiry: nil))
            } catch {
                update(.graph,  state: .failed(message: error.localizedDescription))
                update(.intune, state: .failed(message: error.localizedDescription))
            }
        }
        
        // Entra
        if systems[.entra] != nil {
            update(.entra, state: .authenticating)
            do {
                _ = try await graphService.searchGroups("test", limit: 1)
                update(.entra, state: .valid(user: "Service Credential", expiry: nil))
            } catch {
                update(.entra, state: .failed(message: error.localizedDescription))
            }
        }
        
        // Snipe-IT
        if systems[.snipe] != nil {
            update(.snipe, state: .authenticating)
            do {
                _ = try await snipeService.getAllAssets()
                update(.snipe, state: .valid(user: config.snipeUrl ?? "Snipe-IT", expiry: nil))
            } catch {
                update(.snipe, state: .failed(message: error.localizedDescription))
            }
        }
        
        // TDX
        if systems[.tdx] != nil {
            update(.tdx, state: .authenticating)
            do {
                let search = TicketSearchRequest(maxResults: 1)
                _ = try await tdxService.searchTickets(search: search, maxResults: 1)
                let userName = tdxService.authenticatedUserName
                update(.tdx, state: .valid(user: userName ?? "Service Account", expiry: nil))
            } catch {
                update(.tdx, state: .failed(message: error.localizedDescription))
            }
        }
        
        // DevOps (OAuth2 SSO)
        if systems[.devops] != nil {
            if devOpsService.hasValidToken {
                update(.devops, state: .authenticating)
                await probeDevOps(devOpsService: devOpsService)
            }
            // If no token yet, leave at .configured — SSO will handle it
        }
        
        // GitHub (gh CLI)
        if systems[.github] != nil {
            update(.github, state: .authenticating)
            await probeGitHub()
        }
    }
    
    // MARK: - az CLI Login / Logout (legacy — kept for manual escape hatch)

    /// Launch `az login` (opens browser), then re-probe DevOps state.
    func loginDevOps(devOpsService: AzureDevOpsService) async {
        guard systems[.devops] != nil else { return }
        update(.devops, state: .authenticating)
        let az = resolveAzPath()
        let success = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: az)
            process.arguments = ["login", "-o", "json"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        if success {
            await probeDevOps(devOpsService: devOpsService)
        } else {
            update(.devops, state: .failed(message: "az login failed or was cancelled"))
        }
    }

    /// Run `az logout` then mark DevOps as needing re-auth.
    func logoutDevOps(devOpsService: AzureDevOpsService) async {
        let az = resolveAzPath()
        _ = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: az)
            process.arguments = ["logout"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }.value
        devOpsService.clearBearerToken()
        update(.devops, state: .configured)
    }

    // MARK: - Individual Probes
    
    func probeDevOps(devOpsService: AzureDevOpsService) async {
        // Check if we have a valid Bearer token (from SSO)
        if devOpsService.hasValidToken {
            do {
                let ok = try await devOpsService.verifyAuth()
                if ok {
                    update(.devops, state: .valid(user: "SSO User", expiry: nil))
                } else {
                    update(.devops, state: .failed(message: "Azure DevOps: access denied"))
                }
            } catch {
                update(.devops, state: .failed(message: error.localizedDescription))
            }
            return
        }

        // No token yet — mark as needing SSO login
        update(.devops, state: .configured)
    }
    
    private func probeGitHub() async {
        // Check `gh auth status`
        do {
            let output = try await shellOutput("/usr/bin/env", ["gh", "auth", "status", "--active"])
            if output.contains("Logged in") {
                let user = output.components(separatedBy: "account ").last?
                    .components(separatedBy: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                update(.github, state: .valid(user: user, expiry: nil))
            } else {
                update(.github, state: .configured) // gh present but not logged in
            }
        } catch {
            // gh CLI not installed or not logged in
            update(.github, state: .configured)
        }
    }
    
    // MARK: - Shell Helpers
    
    struct AzAccountInfo {
        let name: String
        let type: String // "user" or "servicePrincipal"
    }
    
    private func runAzAccountShow() async throws -> AzAccountInfo {
        let output = try await shellOutput(resolveAzPath(), ["account", "show", "-o", "json"])
        guard let data = output.data(using: .utf8) else { throw AuthError.parseError }
        struct AzAccount: Decodable {
            let user: AzUser
            struct AzUser: Decodable {
                let name: String
                let type: String
            }
        }
        let account = try JSONDecoder().decode(AzAccount.self, from: data)
        return AzAccountInfo(name: account.user.name, type: account.user.type)
    }
    
    private func resolveAzPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/az") { return "/opt/homebrew/bin/az" }
        if FileManager.default.fileExists(atPath: "/usr/local/bin/az") { return "/usr/local/bin/az" }
        return "/usr/bin/env"
    }
    
    private func shellOutput(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        if executable == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw AuthError.commandFailed }
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    enum AuthError: Error {
        case commandFailed
        case parseError
    }
}
