import SwiftUI
import FleetMateCore

/// Settings window tabs. Every tab needs an explicit tag: a tab without one
/// can never become the selection, so clicking it left the pane blank.
enum SettingsTab {
    static let general = 0
    static let authentication = 1
    static let appearance = 2
    static let manage = 3
    static let about = 4
    static let repositories = RepositoriesSettingsView.tabTag
    static let enrollment = 6
    static let agent = 7
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    /// TicketsMate has no General tab, so it opens on Authentication.
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = AppEdition.current.isTicketsOnly ? SettingsTab.authentication : SettingsTab.general
    private let ticketsOnly = AppEdition.current.isTicketsOnly

    var body: some View {
        TabView(selection: $selectedTabIndex) {
            // General switches modules on and off; TicketsMate has one.
            if !ticketsOnly {
                GeneralSettingsTab()
                    .environmentObject(appState)
                    .tabItem { Label("General", systemImage: "gear") }
                    .tag(SettingsTab.general)
            }

            AuthSettingsView()
                .environmentObject(appState)
                .tabItem { Label("Authentication", systemImage: "lock.shield") }
                .tag(SettingsTab.authentication)

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                .tag(SettingsTab.appearance)

            if !ticketsOnly {
                ManageSettingsView()
                    .environmentObject(appState)
                    .tabItem { Label("Manage", systemImage: "wrench.and.screwdriver") }
                    .tag(SettingsTab.manage)

                AppleOrgSettingsView()
                    .environmentObject(appState)
                    .tabItem { Label("Enrollment", systemImage: FleetModule.enrollment.icon) }
                    .tag(SettingsTab.enrollment)
                AgentSettingsView()
                    .environmentObject(appState)
                    .tabItem { Label("Agent", systemImage: ContentView.agentSymbol) }
                    .tag(SettingsTab.agent)
                RepositoriesSettingsView()
                    .environmentObject(appState)
                    .tabItem { Label("Repositories", systemImage: "folder.badge.gearshape") }
                    .tag(SettingsTab.repositories)
            }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 600, maxWidth: 700, minHeight: 700, idealHeight: 900, maxHeight: 1100)
    }
}

// MARK: - General Settings Tab (Module Toggles)

private struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = 0

    var body: some View {
        Form {
                Section {
                    ForEach(FleetModule.allCases) { module in
                        moduleRow(module)
                    }
                } header: {
                    Text("Enabled Modules")
                } footer: {
                    Text("Switched-off modules are hidden from the tab bar and stop loading. Their settings are kept, so switching one back on picks up where it left off.")
                    .settingsFooter()
                }

                Section {
                    LabeledContent {
                        Button("Run Setup Wizard…") {
                            appState.showOnboardingWizard = true
                            NSApp.keyWindow?.close()
                        }
                    } label: {
                        Text("Setup Wizard")
                        Text("Walks through choosing modules and connecting each one.")
                    }
                }
        }
        .formStyle(.grouped)
    }

    private func binding(for module: FleetModule) -> Binding<Bool> {
        Binding(
            get: { appState.modules.isOn(module) },
            set: { on in
                withAnimation(.snappy) {
                    appState.modules.set(module, on: on)
                }
                // Manage keeps its own enabled flag in config (the CLI reads
                // it too), so switching the module on also sets that.
                if module == .manage, on, appState.config.manage?.enabled != true {
                    var c = appState.config
                    var manage = c.manage ?? ManageConfig()
                    manage.enabled = true
                    c.manage = manage
                    appState.saveConfig(c)
                }
            }
        )
    }

    @ViewBuilder
    private func moduleRow(_ module: FleetModule) -> some View {
        let on = appState.modules.isOn(module)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: binding(for: module)) {
                HStack(spacing: 12) {
                    Image(systemName: module.icon)
                        .appFont(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title).appFont(.body, weight: .medium)
                        Text(module.summary).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)

            if on && !module.isConfigured(appState.config) {
                HStack(spacing: 8) {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                    Text(needsMessage(module))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Configure…") { configure(module) }
                        .controlSize(.small)
                }
                .padding(.leading, 36)
            }
        }
    }

    private func needsMessage(_ module: FleetModule) -> String {
        switch module {
        case .manage: "Needs the enrollment roster before it can show rooms."
        case .enrollment: "Needs where its API credentials are kept."
        default: "Needs a connection before it can load anything."
        }
    }

    /// Open the settings pane that configures the module.
    private func configure(_ module: FleetModule) {
        switch module {
        case .manage:
            selectedTabIndex = SettingsTab.manage
        case .enrollment:
            selectedTabIndex = SettingsTab.enrollment
        case .devices, .identity, .inventory, .tickets, .projects:
            let system: AuthSystemId = switch module {
            case .inventory: .snipe
            case .tickets: .tdx
            case .projects: .devops
            default: .graph
            }
            selectedTabIndex = SettingsTab.authentication
            // The Authentication tab may not exist yet when the tab switch
            // lands, so let it build before asking it to edit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .editAuthSystem, object: system)
            }
        case .development, .reporting:
            break
        }
    }
}

extension Notification.Name {
    static let editAuthSystem = Notification.Name("editAuthSystem")
}

#if DEBUG
#Preview {
    SettingsView()
        .environmentObject(AppState())
}
#endif

extension View {
    /// Explanatory text under a Settings group: leading-aligned, footnote
    /// size, secondary colour, as a native grouped Form footer reads. Without
    /// the explicit frame a multi-line footer centres or trails ragged.
    func settingsFooter() -> some View {
        self.font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
