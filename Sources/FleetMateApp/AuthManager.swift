import Foundation
import FleetMateCore

/// Centralized manager that tracks authentication state for every configured system.
/// Published on AppState so any view can observe status changes.
@MainActor
class AuthManager: ObservableObject {
    @Published var systems: [AuthSystemId: AuthSystemStatus] = [:]
    
    private(set) var config: FleetMateConfig

    init(config: FleetMateConfig) {
        self.config = config
        bootstrapFromConfig()
    }

    // MARK: - Bootstrap

    /// Populate initial states from config: configured systems get `.configured`,
    /// unconfigured ones are omitted entirely (as if they don't exist).
    func bootstrapFromConfig(with newConfig: FleetMateConfig? = nil) {
        if let newConfig { config = newConfig }
        systems.removeAll()
        
        // Devices — Graph / Intune (show if tenant ID set, even with CLI SSO)
        if config.isGraphConfigured || config.graphTenantId != nil {
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

        // Projects — DevOps and GitHub are always listed, even before they are
        // configured. Gating them on their own config made the panel unusable:
        // the Settings ▸ Projects toggle sends you here to enter the DevOps
        // organization, but with no row to edit there was nothing to fill in and
        // the toggle silently did nothing. An unconfigured row shows as
        // `.notConfigured` with its edit button, which is the way in.
        systems[.devops] = AuthSystemStatus(
            systemId: .devops,
            state: config.isDevOpsConfigured ? .configured : .notConfigured
        )

        // GitHub authenticates through the `gh` CLI / Keychain rather than
        // anything stored here, so `enabled` says nothing about whether it works
        // — probeGitHub() resolves the real state. Listing it unconditionally is
        // what lets the panel report a GitHub session that is already live.
        systems[.github] = AuthSystemStatus(systemId: .github, state: .configured)

        // Projects — Gitea
        if let gt = config.tasks?.providers.gitea, gt.enabled {
            systems[.gitea] = AuthSystemStatus(systemId: .gitea, state: .configured)
        }

        // Identity — Entra (show if tenant ID set, even with CLI SSO)
        if config.isSystemsGraphConfigured || config.graphTenantId != nil {
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

    /// Report that an *optional* auth path failed — a silent browser-SSO attempt,
    /// say — without contradicting a system that is already authenticated by some
    /// other means.
    ///
    /// These systems have more than one way in: Snipe-IT and ReportMate ride an
    /// OIDC bearer, and TeamDynamix a service-account JWT (its API supports no
    /// Entra/OAuth login at all, so browser SSO can never be the answer there).
    /// The cookie-SSO attempt runs anyway and, on failure, used to overwrite a
    /// perfectly good `.valid` with "Failed: Silent SSO failed" — the panel
    /// claiming TDX was broken while the row underneath said "signed in as
    /// Service Account" in green.
    func reportOptionalAuthFailure(_ id: AuthSystemId, message: String) {
        guard let current = systems[id]?.state else { return }
        if current.isHealthy {
            dbg.info("\(id.rawValue): optional SSO path failed (\(message)) — keeping the working auth state", category: "auth")
            return
        }
        update(id, state: .failed(message: message))
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
                update(.graph,  state: .valid(user: "az elevation", expiry: nil))
                update(.intune, state: .valid(user: "az elevation", expiry: nil))
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
                update(.entra, state: .valid(user: "az elevation", expiry: nil))
            } catch {
                update(.entra, state: .failed(message: error.localizedDescription))
            }
        }
        
        // Snipe-IT
        if systems[.snipe] != nil {
            if snipeService.usesOidc {
                // OIDC bearer minted from the operator's Entra session — the
                // default since the fork's OIDC guard shipped. This branch used
                // to be missing entirely, so a Snipe on OIDC was never probed:
                // it sat at .configured until the (irrelevant) cookie-SSO attempt
                // timed out and painted it red, while the API was working fine.
                update(.snipe, state: .authenticating)
                do {
                    _ = try await snipeService.getAllAssets()
                    update(.snipe, state: .valid(user: "SSO bearer (OIDC)", expiry: nil))
                } catch {
                    update(.snipe, state: .failed(message: error.localizedDescription))
                }
            } else if snipeService.ssoAuthenticated {
                // SSO mode — already authenticated via cookies
                update(.snipe, state: .valid(user: snipeService.ssoUserName ?? "SSO User", expiry: nil))
            } else if !snipeService.apiKey.isEmpty {
                // API key mode — probe with a lightweight call
                update(.snipe, state: .authenticating)
                do {
                    _ = try await snipeService.getAllAssets()
                    update(.snipe, state: .valid(user: config.snipeUrl ?? "Snipe-IT", expiry: nil))
                } catch {
                    update(.snipe, state: .failed(message: error.localizedDescription))
                }
            }
            // SSO not yet authenticated + no API key = leave at .configured, SSO will handle it
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
