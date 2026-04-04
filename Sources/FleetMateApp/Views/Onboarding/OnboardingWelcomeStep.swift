import SwiftUI

struct OnboardingWelcomeStep: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: OnboardingWizardState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Welcome to FleetMate")
                    .font(.title.bold())
                Text("Unified fleet management for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("This wizard will help you connect your IT systems.\nYou only need URLs and IDs — authentication happens via SSO.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            Spacer()

            VStack(spacing: 10) {
                Button(action: { wizardState.goNext() }) {
                    Text("Get Started")
                        .frame(maxWidth: 200)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                Button("Skip Setup") { dismiss() }
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
            }

            Text("You can run this wizard again from Settings at any time.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)

            Spacer()
        }
        .padding(24)
    }
}
