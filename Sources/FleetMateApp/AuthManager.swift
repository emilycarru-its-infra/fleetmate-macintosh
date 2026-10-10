import Foundation
import FleetMateCore

/// Centralized manager that tracks authentication state for every configured system.
/// Published on AppState so any view can observe status changes.
@MainActor
class AuthManager: ObservableObject {
    @Published var systems: [AuthSystemId: AuthSystemStatus] = [:]
    /// Who `az` and `gh` are signed in as (nil: not signed in or not checked).
    @Published var azAccount: CliAccount?
    @Published var ghAccount: CliAccount?
    /// True once the CLI accounts have been read at least once.
    @Published var cliAccountsChecked = false
    /// Elevation domains whose session is cold-starting for a probe, so the
    /// cards read "Starting elevation session…" instead of a bare spinner.
    @Published var startingElevation: Set<GraphDomain> = []
    
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

        // Tickets — TDX. TicketsMate always lists it, unconfigured or not, so
        // its one system can be set up from this panel.
        let ticketsOnly = AppEdition.current.isTicketsOnly
        if config.isTdxConfigured || ticketsOnly {
            systems[.tdx] = AuthSystemStatus(
                systemId: .tdx,
                state: config.isTdxConfigured ? .configured : .notConfigured
            )
        }

        // TicketsMate carries none of the Projects systems below.
        guard !ticketsOnly else { return }

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
    /// True while `probeAll` runs, so opening Settings during a launch-time
    /// probe does not start a second one.
    @Published private(set) var isProbingAll = false

    func probeAll(
        graphService: GraphService,
        tdxService: TdxService,
        snipeService: SnipeService,
        devOpsService: AzureDevOpsService
    ) async {
        guard !isProbingAll else { return }
        isProbingAll = true
        defer { isProbingAll = false }
        await probeCliAccounts()
        // .intune shares .graph's probe — skip it so the pair is probed once.
        for id in AuthSystemId.allCases where systems[id] != nil && id != .intune {
            await probeSystem(
                id,
                graphService: graphService,
                tdxService: tdxService,
                snipeService: snipeService,
                devOpsService: devOpsService
            )
        }
    }

    /// Probe a single system, so a card's Re-check only spins that card.
    /// `.graph` and `.intune` share one probe (same elevation identity).
    func probeSystem(
        _ id: AuthSystemId,
        graphService: GraphService,
        tdxService: TdxService,
        snipeService: SnipeService,
        devOpsService: AzureDevOpsService
    ) async {
        guard systems[id] != nil else { return }
        switch id {
        case .graph, .intune:
            await probeGraphIntune(graphService: graphService)
        case .entra:
            await probeEntra(graphService: graphService)
        case .snipe:
            await probeSnipe(snipeService: snipeService)
        case .tdx:
            await probeTdx(tdxService: tdxService)
        case .devops:
            if devOpsService.hasValidToken {
                update(.devops, state: .authenticating)
                await probeDevOps(devOpsService: devOpsService)
            } else {
                // Checked and no token: the silent SSO at launch either has
                // not finished or did not work. Stamp it so the row reads
                // "Needs sign-in" rather than checking forever.
                update(.devops, state: .configured)
            }
        case .github:
            update(.github, state: .authenticating)
            await probeGitHub()
        case .gitea:
            break
        }
    }

    /// Read who `az` and `gh` are signed in as — one shared check behind
    /// every card that depends on either CLI.
    func probeCliAccounts() async {
        async let az = CliAccountProbe.azAccount()
        async let gh = CliAccountProbe.ghAccount()
        azAccount = await az
        ghAccount = await gh
        cliAccountsChecked = true
    }

    /// Note a cold start before a probe that rides an elevation session, so
    /// the wait (often over a minute) is shown as progress, not a hang.
    private func noteElevationStart(_ domain: GraphDomain) async {
        guard config.graphUsesAze else { return }
        let info = await ElevationSession().sessionInfo(domain)
        if case .ready = info.status() { return }
        startingElevation.insert(domain)
    }

    private func probeGraphIntune(graphService: GraphService) async {
        guard systems[.graph] != nil else { return }
        update(.graph, state: .authenticating)
        update(.intune, state: .authenticating)
        await noteElevationStart(.devices)
        defer { startingElevation.remove(.devices) }
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

    private func probeEntra(graphService: GraphService) async {
        update(.entra, state: .authenticating)
        await noteElevationStart(.identity)
        defer { startingElevation.remove(.identity) }
        do {
            _ = try await graphService.searchGroups("test", limit: 1)
            update(.entra, state: .valid(user: "az elevation", expiry: nil))
        } catch {
            update(.entra, state: .failed(message: error.localizedDescription))
        }
    }

    private func probeSnipe(snipeService: SnipeService) async {
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
        } else {
            // No way in yet; stamp the check so the row asks for sign-in.
            update(.snipe, state: .configured)
        }
    }

    private func probeTdx(tdxService: TdxService) async {
        // A refused sign-in keeps its reason; a probe would only replace it
        // with a generic "not signed in".
        if let reason = tdxService.refusedSsoReason {
            update(.tdx, state: .failed(message: reason))
            return
        }
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
    
    // MARK: - az CLI Login / Logout (legacy — kept for manual escape hatch)

    /// Launch `az login` (opens browser), then re-probe DevOps state.
    func loginDevOps(devOpsService: AzureDevOpsService) async {
        guard systems[.devops] != nil else { return }
        update(.devops, state: .authenticating)
        let az = resolveAzPath()
        let success = await ProcessRunner.run(az, ["login", "-o", "json"]).succeeded
        if success {
            await probeDevOps(devOpsService: devOpsService)
        } else {
            update(.devops, state: .failed(message: "az login failed or was cancelled"))
        }
    }

    /// Run `az logout` then mark DevOps as needing re-auth.
    func logoutDevOps(devOpsService: AzureDevOpsService) async {
        let az = resolveAzPath()
        _ = await ProcessRunner.run(az, ["logout"])
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
    
    func probeGitHub() async {
        // A GUI app's PATH has no Homebrew, so resolve gh by absolute path.
        // `gh auth status` exits non-zero when logged out and prints to stderr
        // on some versions, so read both streams and ignore the exit code.
        ghAccount = await CliAccountProbe.ghAccount()
        if let account = ghAccount {
            update(.github, state: .valid(user: account.user, expiry: nil))
        } else {
            // gh missing or not logged in
            update(.github, state: .configured)
        }
    }
    
    // MARK: - Shell Helpers
    
    private func resolveAzPath() -> String {
        ProcessRunner.resolve("az")
    }
}
