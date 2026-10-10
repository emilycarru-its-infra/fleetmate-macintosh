import SwiftUI
import FleetMateCore

struct OnboardingModuleSelectionStep: View {
    @EnvironmentObject var wizardState: OnboardingWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Your Modules")
                    .appFont(.title2, weight: .bold)
                Text("Pick what you want FleetMate to show. The next steps connect each one; you can change this later in Settings.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Form {
                Section {
                    ForEach(FleetModule.allCases) { module in
                        moduleToggle(module)
                    }
                }
            }
            .formStyle(.grouped)

            if !wizardState.canGoNext {
                Text("Select at least one module to continue.")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func binding(_ module: FleetModule) -> Binding<Bool> {
        Binding(
            get: { wizardState.selectedModules.contains(module) },
            set: { on in
                if on { wizardState.selectedModules.insert(module) } else { wizardState.selectedModules.remove(module) }
            }
        )
    }

    private func moduleToggle(_ module: FleetModule) -> some View {
        Toggle(isOn: binding(module)) {
            HStack(spacing: 12) {
                Image(systemName: module.icon)
                    .appFont(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).appFont(.body, weight: .medium)
                    Text(module.summary).appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}
