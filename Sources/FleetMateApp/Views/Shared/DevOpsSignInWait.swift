import SwiftUI
import FleetMateCore

/// The shared half of holding an Azure DevOps request until sign-in finishes.
///
/// A view that loads something from Azure DevOps records whether DevOps was
/// signed in when the load began, asks `AppState.devOpsRetry(startedSignedIn:)`
/// what to do when it fails, and, while it waits, shows
/// `DevOpsSignInWaitView` and re-runs the load from `onDevOpsSignIn`.
extension View {
    /// Run `action` each time Azure DevOps sign-in completes.
    func onDevOpsSignIn(_ appState: AppState, perform action: @escaping () -> Void) -> some View {
        onChange(of: appState.devOpsSsoAuthenticated) { _, signedIn in
            if signedIn { action() }
        }
    }
}

/// Stands in for a detail that can't load until Azure DevOps sign-in finishes.
/// Once a sign-in attempt has failed it shows the failure with a way to sign
/// in again; the held request still runs if any later sign-in succeeds.
struct DevOpsSignInWaitView: View {
    @EnvironmentObject private var appState: AppState
    /// What is waiting, as in "Waiting for Azure DevOps sign-in to open <subject>…".
    let subject: String
    /// The failure the held request reported, shown once sign-in has failed.
    let error: String?

    var body: some View {
        VStack(spacing: 12) {
            if appState.devOpsSignInStatus == .failed {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .appFont(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Azure DevOps sign-in didn't finish, so \(subject) can't open yet.")
                    .appFont(.body)
                    .multilineTextAlignment(.center)
                if let error {
                    Text(error)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                // The held request reloads from `onDevOpsSignIn` once this lands.
                Button("Sign In Again") { appState.retryDevOpsRequest(reload: {}) }
                    .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text("Waiting for Azure DevOps sign-in to open \(subject)…")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
