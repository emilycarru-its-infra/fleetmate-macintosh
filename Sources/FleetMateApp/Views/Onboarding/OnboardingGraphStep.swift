import SwiftUI

struct OnboardingGraphStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Microsoft Graph")
                    .appFont(.title2, weight: .bold)
                Text("Connect to Intune for device management and Entra ID for identity.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section("Tenant") {
                    TextField("Azure AD Tenant ID", text: $wizardState.graphTenantId)
                        .textFieldStyle(.roundedBorder)
                    Text("GUID from Azure Portal > Azure Active Directory > Overview")
                        .appFont(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Authentication") {
                    Picker("Auth Mode", selection: $wizardState.graphAuthMode) {
                        ForEach(GraphAuthMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if wizardState.graphAuthMode == .sso {
                        Label("Uses Azure CLI. Run **az login** in Terminal before use.", systemImage: "info.circle")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        GroupBox("Devices Service Principal") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Client ID", text: $wizardState.devicesGraphId)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Client Secret", text: $wizardState.devicesGraphSecret)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(4)
                        }

                        GroupBox("Systems Service Principal") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Client ID", text: $wizardState.systemsGraphId)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Client Secret", text: $wizardState.systemsGraphSecret)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(4)
                        }

                        Text("At least one service principal is required.")
                            .appFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
