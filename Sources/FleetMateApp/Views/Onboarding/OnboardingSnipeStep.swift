import SwiftUI

struct OnboardingSnipeStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Snipe-IT")
                    .appFont(.title2, weight: .bold)
                Text("Connect to your Snipe-IT instance for asset inventory.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section("Connection") {
                    TextField("Instance URL", text: $wizardState.snipeUrl, prompt: Text("https://snipe.example.com"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("Authentication") {
                    Picker("Auth Mode", selection: $wizardState.snipeAuthMode) {
                        ForEach(SnipeWizardAuthMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if wizardState.snipeAuthMode == .sso {
                        Label("SSO login happens automatically via Platform SSO when you open the Inventory tab.", systemImage: "info.circle")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("API Key", text: $wizardState.snipeApiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Generate an API key in Snipe-IT under your user profile > API Keys.")
                            .appFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
