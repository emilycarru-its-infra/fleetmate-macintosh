import SwiftUI
import FleetMateCore

/// Development: repositories, pull requests, pipelines and the coding agent.
/// It needs no credentials of its own, only the CLI sign-ins it reads through
/// and where your checkouts live.
struct OnboardingDevelopmentStep: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: OnboardingWizardState

    @State private var gh: CliAccount?
    @State private var az: CliAccount?
    @State private var checked = false
    @State private var signingInAz = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Development")
                    .appFont(.title2, weight: .bold)
                Text("Repositories, pull requests and pipelines come from your own command-line sign-ins. The agent terminal opens in your checkouts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section {
                    signInRow(
                        title: "GitHub CLI",
                        account: gh,
                        detail: "Repositories, pull requests and Actions runs on GitHub",
                        action: ("gh auth login", {
                            note = CliSignIn.ghLoginInTerminal().message
                        })
                    )
                    signInRow(
                        title: "Azure CLI",
                        account: az,
                        detail: "Repositories, pull requests and pipelines on Azure DevOps",
                        action: ("az login", { signInAz() })
                    )
                    if let note {
                        Text(note).appFont(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Sign-ins")
                        Spacer()
                        Button("Check Again") { Task { await check() } }
                            .controlSize(.small)
                    }
                } footer: {
                    Text("Either one is enough. FleetMate reads with your own identity and never stores a token.")
                    .settingsFooter()
                }

                Section {
                    TextField("Clone into", text: $wizardState.repoCloneRoot, prompt: Text("~/Developer"))
                    TextField("Find checkouts in", text: $wizardState.repoScanRoot, prompt: Text("~/Developer"))
                    TextField("Extra GitHub owners", text: $wizardState.repoGitHubOwners, prompt: Text("Optional, comma-separated"))
                } header: {
                    Text("Repositories")
                } footer: {
                    Text("Choose which repositories to track in Settings ▸ Repositories once setup is done.")
                    .settingsFooter()
                }
            }
            .formStyle(.grouped)
        }
        .task { await check() }
    }

    private func signInRow(title: String, account: CliAccount?, detail: String, action: (String, () -> Void)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account != nil ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(account != nil ? Color.green : Color.secondary)
                .accessibilityLabel(account != nil ? "Signed in" : "Not signed in")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(.body, weight: .medium)
                Text(account.map { "Signed in as \($0.user)" } ?? (checked ? "Not signed in. \(detail)." : "Checking…"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if checked && account == nil {
                if title == "Azure CLI" && signingInAz {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action.0, action: action.1).controlSize(.small)
                }
            }
        }
    }

    private func check() async {
        async let ghAccount = CliAccountProbe.ghAccount()
        async let azAccount = CliAccountProbe.azAccount()
        gh = await ghAccount
        az = await azAccount
        checked = true
    }

    private func signInAz() {
        signingInAz = true
        Task {
            let outcome = await CliSignIn.azLogin(config: appState.config)
            note = outcome.message
            signingInAz = false
            await check()
        }
    }
}
