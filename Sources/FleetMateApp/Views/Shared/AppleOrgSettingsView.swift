import SwiftUI
import UniformTypeIdentifiers
import FleetMateCore

/// Settings ▸ Apple: the Apple School / Business Manager API profiles behind
/// the Devices tab's Mac view. These are asbmutil's profiles — one added here
/// works with `asbmutil`, and one made with `asbmutil config set` shows here.
struct AppleOrgSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        AppleOrgSettingsForm(store: appState.appleOrg)
    }
}

private struct AppleOrgSettingsForm: View {
    @ObservedObject var store: AppleOrgStore

    @State private var name = ""
    @State private var clientId = ""
    @State private var keyId = ""
    @State private var keyFile: URL?
    @State private var showImporter = false
    @State private var saveError: String?
    @State private var profilePendingDelete: AppleOrgProfile?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientId.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyId.trimmingCharacters(in: .whitespaces).isEmpty
            && keyFile != nil
    }

    var body: some View {
        Form {
            Section {
                if store.profiles.isEmpty {
                    Text("No profiles yet. Add one below, or run `asbmutil config set`.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    HStack {
                        Image(systemName: profile.name == store.activeProfileName ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.name == store.activeProfileName ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).appFont(.body, weight: .medium)
                            Text(profile.serviceName).appFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.name != store.activeProfileName {
                            Button("Use") { store.switchProfile(profile.name) }
                        }
                        Button {
                            profilePendingDelete = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this profile from the keychain")
                    }
                }
            } header: {
                Text("Apple School and Business Manager")
            } footer: {
                Text("Profiles are shared with the asbmutil command-line tool. The private key is kept in the keychain.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Add a Profile") {
                TextField("Profile name", text: $name)
                TextField("Client ID", text: $clientId)
                    .appFont(.body, design: .monospaced)
                TextField("Key ID", text: $keyId)
                    .appFont(.body, design: .monospaced)
                HStack {
                    Text(keyFile?.lastPathComponent ?? "No private key chosen")
                        .foregroundStyle(keyFile == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Private Key…") { showImporter = true }
                }
                Text("Create the API account in Apple School or Business Manager under Preferences ▸ API, with the Device Enrollment Manager role or higher, and download its private key (.pem).")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .appFont(.caption)
                }
                HStack {
                    Spacer()
                    Button("Save Profile") { save() }
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "pem") ?? .data, .data]) { result in
            if case .success(let url) = result { keyFile = url }
        }
        .alert("Remove Profile", isPresented: Binding(get: { profilePendingDelete != nil }, set: { if !$0 { profilePendingDelete = nil } }), presenting: profilePendingDelete) { profile in
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                AppleOrgService.deleteProfile(profile.name)
                store.reloadProfiles()
            }
        } message: { profile in
            Text("Remove '\(profile.name)' from the keychain? The asbmutil command-line tool loses it too.")
        }
        .onAppear { store.reloadProfiles() }
    }

    private func save() {
        guard let keyFile else { return }
        saveError = nil
        let accessing = keyFile.startAccessingSecurityScopedResource()
        defer { if accessing { keyFile.stopAccessingSecurityScopedResource() } }
        do {
            let profileName = name.trimmingCharacters(in: .whitespaces)
            try AppleOrgService.saveProfile(name: profileName, clientId: clientId, keyId: keyId, privateKeyFile: keyFile)
            store.reloadProfiles()
            name = ""; clientId = ""; keyId = ""; self.keyFile = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
