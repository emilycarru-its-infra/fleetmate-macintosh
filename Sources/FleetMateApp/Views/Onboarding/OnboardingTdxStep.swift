import SwiftUI

struct OnboardingTdxStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TeamDynamix")
                    .appFont(.title2, weight: .bold)
                Text("Connect to TDX for ticket management.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section("Connection") {
                    TextField("Web API Base URL", text: $wizardState.tdxBaseUrl, prompt: Text("https://yourorg.teamdynamix.com/TDWebApi/api"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Ticketing App ID", text: $wizardState.tdxTicketingAppId, prompt: Text("e.g. 115"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Authentication") {
                    Picker("Auth Mode", selection: $wizardState.tdxAuthMode) {
                        ForEach(TdxWizardAuthMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if wizardState.tdxAuthMode == .sso {
                        Label("SSO login will appear automatically when you open the Tickets tab.", systemImage: "info.circle")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("BEID", text: $wizardState.tdxBeid)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Web Services Key", text: $wizardState.tdxWebServicesKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Found in TDX Admin > BEID and Web Services Key.")
                            .appFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
