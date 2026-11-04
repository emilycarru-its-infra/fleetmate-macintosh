import Foundation

/// Where the background inbox helper lives inside the app, and what state its
/// launchd job is in.
///
/// The helper used to be the app's own executable started with
/// `--inbox-agent`. Because that process carried the app's bundle id, macOS
/// sent Dock clicks and links to it. It is now a separate bundle nested in the
/// app, and a job still pointing at the app's executable has to be registered
/// again to pick up the new program.
public enum InboxHelperJob {
    /// Folder inside the app bundle that holds the helper bundle.
    public static let helperDirectory = "Contents/Library/LoginItems"

    /// The helper's bundle name for an app display name.
    public static func helperBundleName(displayName: String) -> String {
        "\(displayName) Inbox Helper.app"
    }

    public enum State: Equatable, Sendable {
        /// launchd has no job under the label in this login session.
        case notLoaded
        /// The job runs the app's own executable: an install from before the
        /// helper had its own bundle.
        case legacyProgram
        /// The job runs the nested helper.
        case current
    }

    /// Reads `launchctl print gui/<uid>/<label>`. A failed print means no job.
    /// A job whose program identifier is outside the helper folder is the
    /// old registration; output without a program line is taken as current,
    /// so an unexpected format never causes a reload loop.
    public static func state(launchctlPrintOutput output: String, exitStatus: Int32) -> State {
        guard exitStatus == 0 else { return .notLoaded }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["program identifier = ", "program = "] where trimmed.hasPrefix(prefix) {
                let program = trimmed.dropFirst(prefix.count)
                return program.contains(helperDirectory + "/") ? .current : .legacyProgram
            }
        }
        return .current
    }

    /// What the window app does with a registration it finds enabled.
    public static func needsReload(_ state: State) -> Bool {
        state != .current
    }
}
