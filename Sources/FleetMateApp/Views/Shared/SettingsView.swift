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

            ManageSettingsView()
                .environmentObject(appState)
                .tabItem { Label("Manage", systemImage: "wrench.and.screwdriver") }
                .tag(3)
        }
        .frame(minWidth: 600, maxWidth: 700, minHeight: 700, idealHeight: 900, maxHeight: 1100)
    }
}

// MARK: - General Settings Tab (Module Toggles)

private struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = 0
    /// Modules switched on before their credentials exist. The switch flips
    /// immediately and stays here; the row grows a Configure button instead of
    /// the old behavior of yanking the user to the Authentication tab.
    @State private var pendingConfigure: Set<AuthSystemId> = []

    private var enableGraph: Bool { appState.config.isGraphConfigured || appState.config.graphTenantId != nil }
    private var enableSnipe: Bool { appState.config.isSnipeConfigured }
    private var enableTdx: Bool { appState.config.isTdxConfigured }
    private var enableDevOps: Bool { appState.config.isDevOpsConfigured }
    private var enableManage: Bool { appState.config.manage?.enabled ?? false }

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
                        onDisable: {
                            var c = appState.config
                            c.devopsOrganization = nil
                            appState.saveConfig(c)
                        }
                    )
                    manageRow
                } header: {
                    Text("Enabled Modules")
                } footer: {
                    Text("Disabled modules are hidden from the tab bar. Configure credentials in the Authentication tab.")
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Manage has no credentials to collect, only a roster path, so its row
    /// flips the config flag directly and points at the Manage tab.
    private var manageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { enableManage },
                set: { newValue in
                    var c = appState.config
                    var manage = c.manage ?? ManageConfig()
                    manage.enabled = newValue
                    c.manage = manage
                    appState.saveConfig(c)
                }
            )) {
                HStack(spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver")
                        .appFont(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage").appFont(.body, weight: .medium)
                        Text("Lab operations over SSH and Screen Sharing").appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)

            if enableManage && !appState.config.isManageConfigured {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text("Needs the enrollment roster before it can show rooms.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Configure…") { selectedTabIndex = 3 }
                        .controlSize(.small)
                }
                .padding(.leading, 36)
            }
        }
    }

    @ViewBuilder
    private func moduleRow(enabled: Bool, icon: String, title: String, subtitle: String, systemId: AuthSystemId, onDisable: @escaping () -> Void) -> some View {
        let needsConfig = pendingConfigure.contains(systemId) && !enabled
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { enabled || pendingConfigure.contains(systemId) },
                set: { newValue in
                    withAnimation(.snappy) {
                        if newValue {
                            pendingConfigure.insert(systemId)
                        } else {
                            pendingConfigure.remove(systemId)
                            if enabled { onDisable() }
                        }
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

            if needsConfig {
                HStack(spacing: 8) {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                    Text("Needs credentials before it can load anything.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Configure…") {
                        selectedTabIndex = 1
                        // The Authentication tab may not exist yet when the tab
                        // switch lands, so let it build before asking it to edit.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            NotificationCenter.default.post(name: .editAuthSystem, object: systemId)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 36)
            }
        }
        .onChange(of: enabled) { _, nowEnabled in
            if nowEnabled { pendingConfigure.remove(systemId) }
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
