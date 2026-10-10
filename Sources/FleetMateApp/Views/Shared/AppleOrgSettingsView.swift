import SwiftUI
import FleetMateCore

/// Settings ▸ Enrollment: where the enrollment records joined into Devices
/// come from — Windows registrations through the Devices connection, and the
/// Mac enrollment organizations whose API credentials are configured here. They are read from Key Vault
/// with your own `az` sign-in each session; nothing is kept on this Mac.
struct AppleOrgSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        AppleOrgSettingsForm(store: appState.appleOrg)
    }
}

private struct AppleOrgSettingsForm: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AppleOrgStore

    @State private var vault = ""
    @State private var prefixes = ""

    private var draftVault: String? {
        let v = vault.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private var draftPrefixes: [String]? {
        let list = prefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }

    private var changed: Bool {
        draftVault != appState.config.appleOrgKeyVault || draftPrefixes != appState.config.appleOrgSecretPrefixes
    }

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Windows").appFont(.body, weight: .medium)
                        Text(appState.config.isGraphConfigured
                             ? "Registrations are read through the Devices connection."
                             : "Connect Devices to read Windows registrations.")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "pc").foregroundStyle(.secondary)
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac, iPad and iPhone").appFont(.body, weight: .medium)
                        Text(store.profiles.isEmpty
                             ? "Add an enrollment organization below."
                             : "\(store.profiles.count) organization\(store.profiles.count == 1 ? "" : "s") read.")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                }
            } header: {
                Text("Enrollment Records")
            } footer: {
                Text("Enrollment records appear in Devices beside each device's management record, so devices that are registered but not yet enrolled show up too. Switch Enrollment off in General to stop reading them.")
                    .settingsFooter()
            }

            Section {
                if store.profiles.isEmpty {
                    Text(store.sources.isEmpty
                         ? "No Key Vault is set, so no organization is read."
                         : "No organization could be read. Check that az is signed in and can read the vault.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    HStack {
                        Image(systemName: "building.2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.label(for: profile.name)).appFont(.body, weight: .medium)
                            Text("Secrets: \(profile.name)ClientId, \(profile.name)KeyId, \(profile.name)PrivateKeyPem")
                                .appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Apple School and Business Manager")
            } footer: {
                Text("Every organization is read. The API credentials are read from Key Vault with your az sign-in each session and are never stored on this Mac.")
                    .settingsFooter()
            }

            Section("Key Vault") {
                TextField("Key Vault name", text: $vault)
                    .appFont(.body, design: .monospaced)
                TextField("Secret prefixes", text: $prefixes, prompt: Text(AppleOrgSource.defaultPrefix))
                    .appFont(.body, design: .monospaced)
                Text("One prefix per organization, separated by commas. Each needs the secrets <prefix>ClientId, <prefix>KeyId and <prefix>PrivateKeyPem.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .disabled(!changed)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            vault = appState.config.appleOrgKeyVault ?? ""
            prefixes = appState.config.appleOrgSecretPrefixes?.joined(separator: ", ") ?? ""
        }
    }

    private func save() {
        var config = appState.config
        config.appleOrgKeyVault = draftVault
        config.appleOrgSecretPrefixes = draftPrefixes
        appState.saveConfig(config)
    }
}
