import SwiftUI
import FleetMateCore

// MARK: - Step Enum

enum OnboardingStep: String, Identifiable {
    case welcome
    case moduleSelection
    case graph
    case snipe
    case tdx
    case devops
    case development
    case manage
    case summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome:         "Welcome"
        case .moduleSelection: "Modules"
        case .graph:           "Devices & Identity"
        case .snipe:           "Inventory"
        case .tdx:             "Tickets"
        case .devops:          "Projects"
        case .development:     "Development"
        case .manage:          "Manage"
        case .summary:         "Summary"
        }
    }
}

// MARK: - Auth Mode Enums

enum GraphAuthMode: String, CaseIterable {
    case sso = "SSO (Azure CLI)"
    case servicePrincipal = "Service Principal"
}

enum TdxWizardAuthMode: String, CaseIterable {
    case sso = "SSO (Browser)"
    case serviceAccount = "Service Account"
}

enum SnipeWizardAuthMode: String, CaseIterable {
    case sso = "SSO (Browser)"
    case apiKey = "API Key"
}

// MARK: - Connection Test Result

struct ConnectionTestResult: Identifiable {
    let id = UUID()
    let service: String
    let success: Bool
    let message: String
}

// MARK: - Wizard State

@MainActor
class OnboardingWizardState: ObservableObject {
    // Modules chosen on the Modules step. A fresh setup starts with the two
    // that need no connection; TicketsMate connects Tickets and nothing else.
    @Published var selectedModules: Set<FleetModule> = AppEdition.current.isTicketsOnly
        ? [.tickets] : [.development, .reporting]

    // Connectors each selected module needs.
    var enableGraph: Bool { selectedModules.contains(.devices) || selectedModules.contains(.identity) }
    var enableSnipe: Bool { selectedModules.contains(.inventory) }
    var enableTdx: Bool { selectedModules.contains(.tickets) }
    var enableDevOps: Bool { selectedModules.contains(.projects) }
    var enableManage: Bool { selectedModules.contains(.manage) }
    var enableDevelopment: Bool { selectedModules.contains(.development) }

    // Development: where repositories are cloned and found, and which GitHub
    // owners beyond your own memberships to list.
    @Published var repoCloneRoot = RepoSettings.default.cloneRoot
    @Published var repoScanRoot = RepoSettings.default.scanRoots.first ?? ""
    @Published var repoGitHubOwners = ""

    // Graph fields
    @Published var graphTenantId = ""
    @Published var graphAuthMode: GraphAuthMode = .sso
    @Published var devicesGraphId = ""
    @Published var devicesGraphSecret = ""
    @Published var systemsGraphId = ""
    @Published var systemsGraphSecret = ""

    // Snipe-IT fields
    @Published var snipeUrl = ""
    @Published var snipeApiKey = ""
    @Published var snipeAuthMode: SnipeWizardAuthMode = .sso

    // TDX fields
    @Published var tdxBaseUrl = ""
    @Published var tdxTicketingAppId = ""
    @Published var tdxAuthMode: TdxWizardAuthMode = .sso
    @Published var tdxBeid = ""
    @Published var tdxWebServicesKey = ""

    // DevOps fields
    @Published var devopsOrganization = ""
    @Published var devopsProject = ""
    @Published var devopsClientId = ""
    @Published var devopsTenantId = ""

    // Manage
    @Published var manageRosterPath = ""
    @Published var manageSshKeyPath = ""
    @Published var manageSshUser = ""
    /// The Munki repo root, when known, so an empty roster path resolves.
    var manageRepoRoot: String?

    // Navigation
    @Published var currentStepIndex = 0

    // Test results
    @Published var testResults: [ConnectionTestResult] = []
    @Published var isTesting = false

    // Dynamic step list based on enabled modules
    var steps: [OnboardingStep] {
        if AppEdition.current.isTicketsOnly { return [.welcome, .tdx, .summary] }
        var s: [OnboardingStep] = [.welcome, .moduleSelection]
        if enableGraph  { s.append(.graph) }
        if enableSnipe  { s.append(.snipe) }
        if enableTdx    { s.append(.tdx) }
        if enableDevOps { s.append(.devops) }
        if enableDevelopment { s.append(.development) }
        if enableManage { s.append(.manage) }
        s.append(.summary)
        return s
    }

    var currentStep: OnboardingStep {
        let all = steps
        guard currentStepIndex < all.count else { return all.last! }
        return all[currentStepIndex]
    }

    var canGoNext: Bool {
        switch currentStep {
        case .moduleSelection:
            return !selectedModules.isEmpty
        case .graph:
            if graphTenantId.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if graphAuthMode == .servicePrincipal {
                let hasDevices = !devicesGraphId.isEmpty && !devicesGraphSecret.isEmpty
                let hasSystems = !systemsGraphId.isEmpty && !systemsGraphSecret.isEmpty
                return hasDevices || hasSystems
            }
            return true
        case .snipe:
            if snipeUrl.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if snipeAuthMode == .apiKey {
                return !snipeApiKey.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        case .tdx:
            let hasBase = !tdxBaseUrl.trimmingCharacters(in: .whitespaces).isEmpty &&
                          !tdxTicketingAppId.trimmingCharacters(in: .whitespaces).isEmpty
            if !hasBase { return false }
            if tdxAuthMode == .serviceAccount {
                return !tdxBeid.isEmpty && !tdxWebServicesKey.isEmpty
            }
            return true
        case .devops:
            return !devopsOrganization.trimmingCharacters(in: .whitespaces).isEmpty
        case .development:
            return !repoCloneRoot.trimmingCharacters(in: .whitespaces).isEmpty
        case .manage:
            var c = ManageConfig()
            c.rosterPath = manageRosterPath
            return c.hasRoster(repoRoot: manageRepoRoot)
        default:
            return true
        }
    }

    var isLastStep: Bool {
        currentStepIndex >= steps.count - 1
    }

    func goNext() {
        if currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
        }
    }

    func goBack() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
        }
    }

    /// Pre-select the modules that are on and connected, so a re-run starts
    /// from how the app is set up now.
    func populate(modules: ModuleEnablement, config: FleetMateConfig) {
        guard !AppEdition.current.isTicketsOnly else { return }
        selectedModules = Set(FleetModule.allCases.filter { modules.isActive($0, config: config) })
    }

    /// Pre-fill Development from the repository settings already saved.
    func populate(repoSettings: RepoSettings) {
        repoCloneRoot = repoSettings.cloneRoot
        repoScanRoot = repoSettings.scanRoots.first ?? repoScanRoot
        repoGitHubOwners = repoSettings.gitHubOwners.joined(separator: ", ")
    }

    /// The module switches to save: on for every selected module, off for the
    /// rest.
    func moduleEnablement() -> ModuleEnablement {
        var m = ModuleEnablement()
        for module in FleetModule.allCases { m.set(module, on: selectedModules.contains(module)) }
        return m
    }

    /// Pre-populate from existing config (for re-run scenario)
    func populate(from config: FleetMateConfig) {
        if let t = config.graphTenantId, !t.isEmpty {
            graphTenantId = t
        }
        if let id = config.devicesGraphId { devicesGraphId = id }
        if let s = config.devicesGraphSecret { devicesGraphSecret = s; graphAuthMode = .servicePrincipal }
        if let id = config.systemsGraphId { systemsGraphId = id }
        if let s = config.systemsGraphSecret { systemsGraphSecret = s; graphAuthMode = .servicePrincipal }

        if let u = config.snipeUrl, !u.isEmpty {
            snipeUrl = u
        }
        if let k = config.snipeApiKey { snipeApiKey = k }
        if config.snipeAuthMethod == .apiKey { snipeAuthMode = .apiKey }

        if let u = config.tdxBaseUrl, !u.isEmpty {
            tdxBaseUrl = u
        }
        if let id = config.tdxTicketingAppId { tdxTicketingAppId = "\(id)" }
        else if let id = config.tdxAppId { tdxTicketingAppId = "\(id)" }
        if config.tdxBeid != nil { tdxAuthMode = .serviceAccount }
        if let b = config.tdxBeid { tdxBeid = b }
        if let w = config.tdxWebServicesKey { tdxWebServicesKey = w }

        if let o = config.devopsOrganization, !o.isEmpty {
            devopsOrganization = o
        }
        if let p = config.devopsProject { devopsProject = p }
        if let c = config.devopsClientId { devopsClientId = c }
        if let t = config.devopsTenantId { devopsTenantId = t }

        manageRepoRoot = config.repoRoot
        if let m = config.manage {
            manageRosterPath = m.rosterPath
            manageSshKeyPath = m.sshKeyPath
            manageSshUser = m.sshUser
        }
    }

    /// Ensure a URL string has an https:// scheme prefix.
    private func ensureHttps(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
        return "https://\(trimmed)"
    }

    /// Build a FleetMateConfig from wizard state, merging into existing config
    func buildConfig(base: FleetMateConfig) -> FleetMateConfig {
        var c = base

        if enableGraph {
            c.graphTenantId = graphTenantId.isEmpty ? nil : graphTenantId
            if graphAuthMode == .servicePrincipal {
                c.devicesGraphId = devicesGraphId.isEmpty ? nil : devicesGraphId
                c.devicesGraphSecret = devicesGraphSecret.isEmpty ? nil : devicesGraphSecret
                c.systemsGraphId = systemsGraphId.isEmpty ? nil : systemsGraphId
                c.systemsGraphSecret = systemsGraphSecret.isEmpty ? nil : systemsGraphSecret
            }
        }

        if enableSnipe {
            c.snipeUrl = snipeUrl.isEmpty ? nil : ensureHttps(snipeUrl)
            if snipeAuthMode == .sso {
                c.snipeSsoEnabled = true
                c.snipeAuthMethod = .browserSSO
            } else {
                c.snipeSsoEnabled = false
                c.snipeAuthMethod = .apiKey
                c.snipeApiKey = snipeApiKey.isEmpty ? nil : snipeApiKey
            }
        }

        if enableTdx {
            c.tdxBaseUrl = tdxBaseUrl.isEmpty ? nil : ensureHttps(tdxBaseUrl)
            let appId = Int(tdxTicketingAppId)
            c.tdxTicketingAppId = appId
            c.tdxAppId = appId
            if tdxAuthMode == .sso {
                c.tdxSsoEnabled = true
                c.tdxAuthMethod = .browserSSO
            } else {
                c.tdxBeid = tdxBeid.isEmpty ? nil : tdxBeid
                c.tdxWebServicesKey = tdxWebServicesKey.isEmpty ? nil : tdxWebServicesKey
            }
        }

        if enableDevOps {
            c.devopsOrganization = devopsOrganization.isEmpty ? nil : devopsOrganization
            c.devopsProject = devopsProject.isEmpty ? nil : devopsProject
            c.devopsClientId = devopsClientId.isEmpty ? nil : devopsClientId
            let tenant = devopsTenantId.isEmpty ? graphTenantId : devopsTenantId
            c.devopsTenantId = tenant.isEmpty ? nil : tenant
        }

        var manage = c.manage ?? ManageConfig()
        if enableManage {
            manage.enabled = true
            manage.rosterPath = manageRosterPath.trimmingCharacters(in: .whitespaces)
            manage.sshKeyPath = manageSshKeyPath.trimmingCharacters(in: .whitespaces)
            manage.sshUser = manageSshUser.trimmingCharacters(in: .whitespaces)
        }
        c.manage = manage

        return c
    }
}

// MARK: - Wizard Container View

struct OnboardingWizardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var wizardState = OnboardingWizardState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            if wizardState.currentStep != .welcome {
                stepIndicator
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            // Step content
            Group {
                switch wizardState.currentStep {
                case .welcome:
                    OnboardingWelcomeStep()
                case .moduleSelection:
                    OnboardingModuleSelectionStep()
                case .graph:
                    OnboardingGraphStep()
                case .snipe:
                    OnboardingSnipeStep()
                case .tdx:
                    OnboardingTdxStep()
                case .manage:
                    OnboardingManageStep()
                        .environmentObject(wizardState)
                        .environmentObject(appState)
                case .devops:
                    OnboardingDevOpsStep()
                case .development:
                    OnboardingDevelopmentStep()
                case .summary:
                    OnboardingSummaryStep(onFinish: finish)
                }
            }
            .environmentObject(wizardState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: wizardState.currentStepIndex)

            // Navigation buttons
            if wizardState.currentStep != .welcome && wizardState.currentStep != .summary {
                navigationButtons
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            let hasExistingConfig = appState.config.isGraphConfigured ||
                                    appState.config.isSnipeConfigured ||
                                    appState.config.isTdxConfigured ||
                                    appState.config.isDevOpsConfigured
            if hasExistingConfig {
                wizardState.populate(from: appState.config)
                wizardState.populate(modules: appState.modules, config: appState.config)
            }
            if let repo = try? RepoManager().settings() {
                wizardState.populate(repoSettings: repo)
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            let allSteps = wizardState.steps
            ForEach(Array(allSteps.enumerated()), id: \.element.id) { index, step in
                if step != .welcome {
                    Circle()
                        .fill(index <= wizardState.currentStepIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack {
            Button("Back") { wizardState.goBack() }
                .disabled(wizardState.currentStepIndex == 0)

            Button("Skip Setup") { dismiss() }
                .foregroundStyle(.secondary)

            Spacer()

            Button("Next") { wizardState.goNext() }
                .keyboardShortcut(.defaultAction)
                .disabled(!wizardState.canGoNext)
        }
    }

    // MARK: - Finish

    private func finish() {
        let updatedConfig = wizardState.buildConfig(base: appState.config)
        dbg.info("[Wizard] Saving config: tdxBaseUrl=\(updatedConfig.tdxBaseUrl ?? "nil"), tdxAppId=\(updatedConfig.tdxAppId ?? -1), snipeUrl=\(updatedConfig.snipeUrl ?? "nil")", category: "wizard")
        appState.saveConfig(updatedConfig)
        if !AppEdition.current.isTicketsOnly {
            appState.modules = wizardState.moduleEnablement()
        }
        if wizardState.enableDevelopment {
            saveRepoSettings()
        }
        dbg.info("[Wizard] Save complete, error=\(appState.errorMessage ?? "none")", category: "wizard")
        dismiss()

        // Trigger SSO flows for newly configured services
        if wizardState.enableSnipe && wizardState.snipeAuthMode == .sso {
            appState.attemptSilentSnipeSso()
        }
        if wizardState.enableTdx && wizardState.tdxAuthMode == .sso {
            appState.attemptSilentTdxSso()
        }
        if wizardState.enableDevOps {
            appState.attemptSilentDevOpsSso()
        }

        // Reload data
        Task {
            await appState.preloadAllData()
        }
    }

    /// Write the Development step's locations to the same registry
    /// `fleetmate repos` and Settings ▸ Repositories use.
    private func saveRepoSettings() {
        let clone = wizardState.repoCloneRoot.trimmingCharacters(in: .whitespaces)
        let scan = wizardState.repoScanRoot.trimmingCharacters(in: .whitespaces)
        let owners = wizardState.repoGitHubOwners
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        do {
            try RepoManager().updateSettings { settings in
                if !clone.isEmpty { settings.cloneRoot = clone }
                if !scan.isEmpty, !settings.scanRoots.contains(scan) { settings.scanRoots.insert(scan, at: 0) }
                settings.gitHubOwners = owners
            }
            NotificationCenter.default.post(name: .repoRegistryChanged, object: nil)
        } catch {
            dbg.error("[Wizard] Saving repository settings failed: \(error.localizedDescription)", category: "wizard")
        }
    }
}
