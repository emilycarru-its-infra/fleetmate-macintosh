import SwiftUI
import FleetMateCore

/// Shown along the top of Tickets when the TeamDynamix session has lapsed
/// and silent renewal has stopped working, so the person sees why tickets
/// will not load and has one way out, instead of a generic error per call.
struct TdxSignInBanner: View {
    @EnvironmentObject var appState: AppState

    private var detail: String {
        if let reason = appState.tdxService.refusedSsoReason {
            return reason
        }
        return "Your TeamDynamix session has expired and signing in again in the background did not work. Tickets will not load until you sign in."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not signed in to TeamDynamix")
                    .appFont(.callout)
                    .fontWeight(.semibold)
                Text(detail)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Try Again") { appState.attemptSilentTdxSso(useCache: false) }
                .help("Sign in again in the background, without a window")
                .disabled(appState.tdxSignInStage != nil)
            Button("Sign In…") { appState.signInToTdxInteractively() }
                .buttonStyle(.borderedProminent)
                .help("Open the TeamDynamix sign-in window")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Not signed in to TeamDynamix")
    }
}
