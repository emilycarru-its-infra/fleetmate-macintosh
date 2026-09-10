import SwiftUI
import FleetMateCore

/// Settings ▸ Manage: where the roster and command library live, how SSH
/// and Screen Sharing sessions open. Edits are staged and saved together.
struct ManageSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var draft = ManageConfig()
    @State private var loaded = false
    @State private var screenSharingPassword = ""
    @State private var screenSharingPasswordIsSet = false
    @State private var credentialError: String?

    static let terminalThemes = ["", "Basic", "Grass", "Homebrew", "Man Page", "Novel", "Ocean", "Pro", "Red Sands", "Silver Aerogel"]

    private var saved: ManageConfig { appState.config.manage ?? ManageConfig() }
    private var isDirty: Bool { draft != saved }
    private var rosterResolved: String { draft.resolvedRosterPath(repoRoot: appState.config.repoRoot) }
    private var rosterExists: Bool { !rosterResolved.isEmpty && FileManager.default.fileExists(atPath: rosterResolved) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $draft.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the Manage tab").appFont(.body, weight: .medium)
                        Text("Lab operations over SSH and Screen Sharing").appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text(draft.fetchesRoster
                         ? "Roster is fetched from \(draft.rosterSourceLabel)\(draft.rosterRepoPath) at load; the path below is only the fallback."
                         : "Roster fetch is off; the path below is used as is.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !appState.manageState.rosterSource.isEmpty {
                    Text("Current: \(appState.manageState.rosterSource)")
                        .appFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                PathPickerRow(label: "Roster (computers.csv)", value: $draft.rosterPath,
                              placeholder: appState.config.repoRoot.map { "\($0)/\(ManageConfig.defaultRosterRelativePath)" } ?? "Choose computers.csv",
                              buttonLabel: "Choose CSV…")
                HStack(spacing: 6) {
                    Image(systemName: rosterExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(rosterExists ? Color.manageSuccess : Color.manageWarning)
                    Text(rosterResolved.isEmpty ? "No roster path; set one or configure the Munki repo root." : rosterResolved)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                PathPickerRow(label: "Command library", value: $draft.commandsPath,
                              placeholder: ManageStateStore().commandsPath, buttonLabel: "Choose YAML…")
                Toggle("Include machines that have left service", isOn: $draft.includeRetired)
                Toggle("Include the Provisioning catalog as a lab", isOn: $draft.includeProvisioning)
            } header: {
                Text("Data")
            } footer: {
                Text("Leave the library path empty to use the per-user copy FleetMate seeds and keeps up to date.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PathPickerRow(label: "SSH key", value: $draft.sshKeyPath, placeholder: ManageConfig.defaultSshKeyPath, buttonLabel: "Choose key…")
                HStack(spacing: 6) {
                    Image(systemName: draft.hasSshKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(draft.hasSshKey ? Color.manageSuccess : Color.manageWarning)
                    Text(draft.hasSshKey ? draft.resolvedSshKeyPath : "Key not found; scanning still works, but machine info and commands need it.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Text("SSH user")
                    Spacer()
                    TextField(ManageConfig.defaultSshUser, text: $draft.sshUser)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Picker("Terminal profile", selection: $draft.terminalTheme) {
                    ForEach(Self.terminalThemes, id: \.self) { theme in
                        Text(theme.isEmpty ? "Terminal default" : theme).tag(theme)
                    }
                }
                Stepper(value: $draft.probeConcurrency, in: 1...64) {
                    HStack {
                        Text("Parallel probes")
                        Spacer()
                        Text("\(draft.probeConcurrency)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("SSH")
            }

            Section {
                HStack {
                    Text("Screen Sharing user")
                    Spacer()
                    TextField("Same as SSH user", text: $draft.screenSharingUser)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                HStack {
                    Text("Password")
                    Spacer()
                    if screenSharingPasswordIsSet {
                        Text("Stored in Keychain").foregroundStyle(.secondary)
                        Button("Clear") {
                            do {
                                try ScreenSharingCredentialStore.clear()
                                screenSharingPasswordIsSet = false
                                credentialError = nil
                            } catch {
                                credentialError = error.localizedDescription
                            }
                        }
                        .controlSize(.small)
                    } else {
                        Text("Not set").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(screenSharingPasswordIsSet ? "Replace" : "New password")
                    Spacer()
                    SecureField("Screen Sharing password", text: $screenSharingPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Store") {
                        do {
                            try ScreenSharingCredentialStore.save(screenSharingPassword)
                            screenSharingPassword = ""
                            screenSharingPasswordIsSet = true
                            credentialError = nil
                        } catch {
                            credentialError = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                    .disabled(screenSharingPassword.isEmpty)
                }
                if let credentialError {
                    Text(credentialError).appFont(.caption).foregroundStyle(Color.manageFailure)
                }
            } header: {
                Text("Screen Sharing")
            } footer: {
                Text("With a stored password Screen Sharing opens straight to the desktop. It lives in the login Keychain under FleetMate, never in a file.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reload Roster") { appState.manageState.loadRoster() }
                    Spacer()
                    Button("Revert") { draft = saved }.disabled(!isDirty)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { draft = saved; loaded = true }
            screenSharingPasswordIsSet = ScreenSharingCredentialStore.isSet
        }
        .onChange(of: appState.config.manage) { _, _ in
            if !isDirty || !loaded { draft = saved }
        }
    }

    private func save() {
        var config = appState.config
        config.manage = draft
        appState.saveConfig(config)
    }
}
