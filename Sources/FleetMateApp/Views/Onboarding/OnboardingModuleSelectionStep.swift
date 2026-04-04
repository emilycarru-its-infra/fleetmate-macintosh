import SwiftUI

struct OnboardingModuleSelectionStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Your Modules")
                    .font(.title2.bold())
                Text("Select the systems you want to connect. You can change this later in Settings.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section {
                    moduleToggle(
                        isOn: $wizardState.enableGraph,
                        icon: "shield.checkered",
                        title: "Devices & Identity",
                        subtitle: "Microsoft Intune devices, Entra ID users and groups"
                    )
                    moduleToggle(
                        isOn: $wizardState.enableSnipe,
                        icon: "tag",
                        title: "Inventory",
                        subtitle: "Snipe-IT asset management"
                    )
                    moduleToggle(
                        isOn: $wizardState.enableTdx,
                        icon: "ticket",
                        title: "Tickets",
                        subtitle: "TeamDynamix service desk"
                    )
                    moduleToggle(
                        isOn: $wizardState.enableDevOps,
                        icon: "square.stack.3d.up",
                        title: "Projects",
                        subtitle: "Azure DevOps boards and work items"
                    )
                }
            }
            .formStyle(.grouped)

            if !wizardState.canGoNext {
                Text("Select at least one module to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func moduleToggle(isOn: Binding<Bool>, icon: String, title: String, subtitle: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}
