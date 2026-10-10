import Foundation

/// What the Inventory widgets show when the assets could not be loaded. A
/// failed preload used to leave them reading "No asset data", which looks like
/// an empty inventory rather than a sign-in that did not work. FleetMate for
/// Windows uses the same words.
public enum AssetsLoadFailure {
    /// The reason in the words the app shows: a token that could not be had is
    /// a failed sign-in, which is fixed differently from Snipe-IT failing.
    public static func reason(_ error: Error) -> String {
        if let token = error as? AzTokenError { return "Sign-in failed: \(token.description)" }
        return error.localizedDescription
    }

    /// The few words a widget shows in place of its chart.
    public static func headline(_ reason: String?) -> String {
        guard let reason else { return "No asset data" }
        let lower = reason.lowercased()
        if lower.hasPrefix("sign-in failed")
            || lower.contains("refused the sign-in")
            || lower.contains("status code was unacceptable: 401")
            || lower.contains("status code was unacceptable: 403") {
            return "Sign-in failed"
        }
        return "Could not load assets"
    }
}
