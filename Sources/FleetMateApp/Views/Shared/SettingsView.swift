import SwiftUI
import FleetMateCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = 0

    var body: some View {
        TabView(selection: $selectedTabIndex) {
            GeneralSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            AuthSettingsView()
                .environmentObject(appState)
                .tabItem { Label("Authentication", systemImage: "lock.shield") }
                .tag(1)

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
                .tag(2)
        }
        .frame(minWidth: 600, maxWidth: 700, minHeight: 700, idealHeight: 900, maxHeight: 1100)
    }
}

// MARK: - General Settings Tab (Module Toggles)

private struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = 0
    @State private var isLoading = true

    private var enableGraph: Bool { appState.config.isGraphConfigured || appState.config.graphTenantId != nil }
    private var enableSnipe: Bool { appState.config.isSnipeConfigured }
    private var enableTdx: Bool { appState.config.isTdxConfigured }
    private var enableDevOps: Bool { appState.config.isDevOpsConfigured }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Setup Wizard") {
                    appState.showOnboardingWizard = true
                    NSApp.keyWindow?.close()
                }
                .help("Run the guided setup wizard")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            Form {
                Section {
                    moduleRow(
                        enabled: enableGraph,
                        icon: "shield.checkered",
                        title: "Devices & Identity",
                        subtitle: "Microsoft Intune devices, Entra ID users and groups",
                        systemId: .graph,
                        onEnable: { /* Graph needs tenant ID — open Auth edit */ },
                        onDisable: {
                            var c = appState.config
                            c.graphTenantId = nil
                            c.devicesGraphId = nil; c.devicesGraphSecret = nil
                            c.systemsGraphId = nil; c.systemsGraphSecret = nil
                            appState.saveConfig(c)
                        }
                    )
                    moduleRow(
                        enabled: enableSnipe,
                        icon: "tag",
                        title: "Inventory",
                        subtitle: "Snipe-IT asset management",
                        systemId: .snipe,
                        onEnable: { /* Snipe needs URL — open Auth edit */ },
                        onDisable: {
                            var c = appState.config
                            c.snipeUrl = nil; c.snipeApiKey = nil
                            c.snipeSsoEnabled = false
                            appState.saveConfig(c)
                        }
                    )
                    moduleRow(
                        enabled: enableTdx,
                        icon: "ticket",
                        title: "Tickets",
                        subtitle: "TeamDynamix service desk",
                        systemId: .tdx,
                        onEnable: { /* TDX needs URL — open Auth edit */ },
                        onDisable: {
                            var c = appState.config
                            c.tdxBaseUrl = nil
                            appState.saveConfig(c)
                        }
                    )
                    moduleRow(
                        enabled: enableDevOps,
                        icon: "square.stack.3d.up",
                        title: "Projects",
                        subtitle: "Azure DevOps boards and GitHub issues",
                        systemId: .devops,
                        onEnable: { /* DevOps needs org — open Auth edit */ },
                        onDisable: {
                            var c = appState.config
                            c.devopsOrganization = nil
                            appState.saveConfig(c)
                        }
                    )
                } header: {
                    Text("Enabled Modules")
                } footer: {
                    Text("Disabled modules are hidden from the tab bar. Configure credentials in the Authentication tab.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func moduleRow(enabled: Bool, icon: String, title: String, subtitle: String, systemId: AuthSystemId, onEnable: @escaping () -> Void, onDisable: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { enabled },
            set: { newValue in
                if newValue {
                    onEnable()
                    // Switch to Auth tab and trigger edit for this system
                    selectedTabIndex = 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NotificationCenter.default.post(name: .editAuthSystem, object: systemId)
                    }
                } else {
                    onDisable()
                }
            }
        )) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .appFont(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(.body, weight: .medium)
                    Text(subtitle).appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

extension Notification.Name {
    static let editAuthSystem = Notification.Name("editAuthSystem")
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
