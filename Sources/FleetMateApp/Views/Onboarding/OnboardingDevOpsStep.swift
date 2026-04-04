import SwiftUI

struct OnboardingDevOpsStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Azure DevOps")
                    .font(.title2.bold())
                Text("Connect to Azure DevOps for project boards and work items.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section("Organization") {
                    TextField("Organization Name", text: $wizardState.devopsOrganization, prompt: Text("my-org"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Project Name", text: $wizardState.devopsProject, prompt: Text("Optional — can be auto-discovered"))
                        .textFieldStyle(.roundedBorder)
                }

                Section("SSO Authentication") {
                    TextField("OAuth Client ID", text: $wizardState.devopsClientId, prompt: Text("Azure AD App Registration GUID"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Tenant ID", text: $wizardState.devopsTenantId, prompt: Text(wizardState.graphTenantId.isEmpty ? "Azure AD Tenant GUID" : "Defaults to Graph tenant"))
                        .textFieldStyle(.roundedBorder)
                    if !wizardState.graphTenantId.isEmpty && wizardState.devopsTenantId.isEmpty {
                        Label("Will use the Microsoft Graph tenant ID if left blank.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
