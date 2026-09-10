import SwiftUI
import FleetMateCore

/// Wizard step for the Manage module: the roster and the fleet SSH key.
struct OnboardingManageStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState
    @EnvironmentObject var appState: AppState

    private var rosterResolved: String {
        var c = ManageConfig()
        c.rosterPath = wizardState.manageRosterPath
        return c.resolvedRosterPath(repoRoot: appState.config.repoRoot)
    }

    private var rosterExists: Bool {
        !rosterResolved.isEmpty && FileManager.default.fileExists(atPath: rosterResolved)
    }

    private var keyPath: String {
        var c = ManageConfig()
        c.sshKeyPath = wizardState.manageSshKeyPath
        return c.resolvedSshKeyPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manage")
                    .appFont(.title2, weight: .bold)
                Text("Lab operations over SSH and Screen Sharing: rooms come from the enrollment roster, commands run over the fleet SSH key.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            Form {
                Section {
                    PathPickerRow(label: "Roster (computers.csv)", value: $wizardState.manageRosterPath,
                                  placeholder: appState.config.repoRoot.map { "\($0)/\(ManageConfig.defaultRosterRelativePath)" } ?? "Choose computers.csv",
                                  buttonLabel: "Choose CSV…")
                    HStack(spacing: 6) {
                        Image(systemName: rosterExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(rosterExists ? Color.manageSuccess : Color.manageWarning)
                        Text(rosterResolved.isEmpty ? "Choose the enrollment roster to continue." : rosterResolved)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Roster")
                } footer: {
                    Text("The Munki repo's deployment/enroll/computers.csv when the repo root is known; any file with the same columns otherwise.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    PathPickerRow(label: "SSH key", value: $wizardState.manageSshKeyPath,
                                  placeholder: ManageConfig.defaultSshKeyPath, buttonLabel: "Choose key…")
                    HStack {
                        Text("SSH user")
                        Spacer()
                        TextField(ManageConfig.defaultSshUser, text: $wizardState.manageSshUser)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: FileManager.default.fileExists(atPath: keyPath) ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(FileManager.default.fileExists(atPath: keyPath) ? Color.manageSuccess : Color.secondary)
                        Text(FileManager.default.fileExists(atPath: keyPath) ? keyPath : "No key yet. Scanning works without one; machine info and commands need it.")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Fleet SSH")
                }
            }
            .formStyle(.grouped)
        }
    }
}
