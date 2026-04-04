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
    case summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome:         "Welcome"
        case .moduleSelection: "Modules"
        case .graph:           "Microsoft Graph"
        case .snipe:           "Snipe-IT"
        case .tdx:             "TeamDynamix"
        case .devops:          "Azure DevOps"
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
    // Module toggles
    @Published var enableGraph = false
    @Published var enableSnipe = false
    @Published var enableTdx = false
    @Published var enableDevOps = false

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

    // Navigation
    @Published var currentStepIndex = 0

    // Test results
    @Published var testResults: [ConnectionTestResult] = []
    @Published var isTesting = false

    // Dynamic step list based on enabled modules
    var steps: [OnboardingStep] {
        var s: [OnboardingStep] = [.welcome, .moduleSelection]
        if enableGraph  { s.append(.graph) }
        if enableSnipe  { s.append(.snipe) }
        if enableTdx    { s.append(.tdx) }
        if enableDevOps { s.append(.devops) }
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
            return enableGraph || enableSnipe || enableTdx || enableDevOps
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

    /// Pre-populate from existing config (for re-run scenario)
    func populate(from config: FleetMateConfig) {
        if let t = config.graphTenantId, !t.isEmpty {
            enableGraph = true
            graphTenantId = t
        }
        if let id = config.devicesGraphId { devicesGraphId = id }
        if let s = config.devicesGraphSecret { devicesGraphSecret = s; graphAuthMode = .servicePrincipal }
        if let id = config.systemsGraphId { systemsGraphId = id }
        if let s = config.systemsGraphSecret { systemsGraphSecret = s; graphAuthMode = .servicePrincipal }

        if let u = config.snipeUrl, !u.isEmpty {
            enableSnipe = true
            snipeUrl = u
        }
        if let k = config.snipeApiKey { snipeApiKey = k }
        if config.snipeAuthMethod == .apiKey { snipeAuthMode = .apiKey }

        if let u = config.tdxBaseUrl, !u.isEmpty {
            enableTdx = true
            tdxBaseUrl = u
        }
        if let id = config.tdxTicketingAppId { tdxTicketingAppId = "\(id)" }
        else if let id = config.tdxAppId { tdxTicketingAppId = "\(id)" }
        if config.tdxBeid != nil { tdxAuthMode = .serviceAccount }
        if let b = config.tdxBeid { tdxBeid = b }
        if let w = config.tdxWebServicesKey { tdxWebServicesKey = w }

        if let o = config.devopsOrganization, !o.isEmpty {
            enableDevOps = true
            devopsOrganization = o
        }
        if let p = config.devopsProject { devopsProject = p }
        if let c = config.devopsClientId { devopsClientId = c }
        if let t = config.devopsTenantId { devopsTenantId = t }
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
                case .devops:
                    OnboardingDevOpsStep()
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
}
