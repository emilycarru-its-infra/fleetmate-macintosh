import SwiftUI
import FleetMateCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabIndex: Int = 0

    var body: some View {
        TabView(selection: $selectedTabIndex) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            AuthSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Authentication", systemImage: "lock.shield")
                }
                .tag(1)
        }
        .frame(minWidth: 560, maxWidth: 560, minHeight: 400, idealHeight: 620, maxHeight: 900)
    }

    private var generalTab: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Config File") {
                    Text("~/.fleetmate/config.yaml")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button("Reload Configuration") {
                    appState.reloadConfig()
                }
            }

            Section("Microsoft Graph") {
                ConfigRow(label: "Tenant ID", value: appState.config.graphTenantId, isSecret: false)
                ConfigRow(label: "Client ID", value: appState.config.graphClientId, isSecret: false)
                ConfigRow(label: "Client Secret", value: appState.config.graphClientSecret, isSecret: true)
            }

            Section("Azure DevOps") {
                ConfigRow(label: "Organization", value: appState.config.devopsOrganization, isSecret: false)
                ConfigRow(label: "Project", value: appState.config.devopsProject, isSecret: false)
            }

            Section("TeamDynamix") {
                ConfigRow(label: "Base URL", value: appState.config.tdxBaseUrl, isSecret: false)
                ConfigRow(label: "App ID", value: appState.config.tdxAppId.map { String($0) }, isSecret: false)
                ConfigRow(label: "Username", value: appState.config.tdxUsername, isSecret: false)
                ConfigRow(label: "Password", value: appState.config.tdxPassword, isSecret: true)
                ConfigRow(label: "BEID", value: appState.config.tdxBeid, isSecret: true)
            }

            Section("Snipe-IT") {
                ConfigRow(label: "URL", value: appState.config.snipeUrl, isSecret: false)
                ConfigRow(label: "API Key", value: appState.config.snipeApiKey, isSecret: true)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text("1.0.0")
                }
                LabeledContent("Platform") {
                    Text("macOS")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ConfigRow: View {
    let label: String
    let value: String?
    let isSecret: Bool

    @State private var showSecret = false

    var body: some View {
        LabeledContent(label) {
            HStack {
                if let value = value, !value.isEmpty {
                    if isSecret && !showSecret {
                        Text(String(repeating: "•", count: min(value.count, 20)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text(value)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if isSecret {
                        Button(action: { showSecret.toggle() }) {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("Not configured")
                        .foregroundColor(.red)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
