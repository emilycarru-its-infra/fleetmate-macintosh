import SwiftUI
import FleetMateCore

/// Settings ▸ Manage: where the roster and command library live, how SSH
/// and Screen Sharing sessions open. Edits are staged and saved together.
struct ManageSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var draft = ManageConfig()
    @State private var loaded = false

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
            } header: {
                Text("Screen Sharing")
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
