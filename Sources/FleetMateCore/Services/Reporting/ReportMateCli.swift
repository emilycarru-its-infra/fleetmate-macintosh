import Foundation

/// The `reportmate` admin CLI, when it is installed on this Mac.
///
/// The CLI is the reference client for the ReportMate API: it tracks every
/// route the API has and prints the API's JSON unchanged. When it is present
/// FleetMate routes its ReportMate reads through it, so one binary owns the
/// API contract and a route change reaches FleetMate by updating the CLI
/// rather than by shipping a new FleetMate. When it is absent, or cannot be
/// launched, `ReportMateService` falls back to its own HTTP client.
///
/// A non-zero exit from a CLI that *did* launch is an API answer (a 404, a
/// 403 for a missing scope, a 5xx) and is surfaced, not retried over HTTP:
/// the HTTP path would only reproduce the same answer.
public struct ReportMateCli: Sendable {
    /// Directories a fleet install may put the binary in, checked before the
    /// `PATH` search so a GUI app launched from Finder still finds it.
    static let candidateDirectories = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/reportmate/bin"]

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The installed CLI, or nil when no executable `reportmate` exists.
    ///
    /// `REPORTMATE_CLI` in the environment pins a specific binary, which is
    /// how a test points the service at a stub and how an operator tries a
    /// development build. Set it to an empty string to disable the CLI path.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> ReportMateCli? {
        if let pinned = environment["REPORTMATE_CLI"] {
            let trimmed = pinned.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) else { return nil }
            return ReportMateCli(path: trimmed)
        }
        for directory in candidateDirectories {
            let candidate = "\(directory)/reportmate"
            if FileManager.default.isExecutableFile(atPath: candidate) { return ReportMateCli(path: candidate) }
        }
        let resolved = ProcessRunner.resolve("reportmate")
        return resolved.hasPrefix("/") ? ReportMateCli(path: resolved) : nil
    }

    public enum Failure: Error, Equatable {
        /// The binary could not be started at all; the caller should use HTTP.
        case launchFailed(String)
        /// The CLI ran and the API (or the CLI itself) refused the request.
        case failed(exitCode: Int32, stderr: String)

        /// True for the one API answer the service treats as "no such thing".
        public var isNotFound: Bool {
            if case .failed(_, let stderr) = self { return stderr.contains("-> 404") }
            return false
        }
    }

    /// Runs `reportmate <arguments> --output json` and returns stdout.
    ///
    /// `credentials` carries the `REPORTMATE_API_URL` and one credential
    /// variable; nothing else from FleetMate's environment is forwarded, so a
    /// stray `REPORTMATE_*` variable in the operator's shell cannot redirect
    /// the call.
    public func run(_ arguments: [String], credentials: [String: String]) async -> Result<Data, Failure> {
        var environment: [String: String] = ["HOME": ProcessInfo.processInfo.environment["HOME"] ?? "/"]
        for (key, value) in credentials { environment[key] = value }
        let output = await ProcessRunner.run(path, arguments + ["--output", "json"], environment: environment)
        if output.exitCode == -1 {
            return .failure(.launchFailed(output.stderr))
        }
        guard output.succeeded else {
            return .failure(.failed(exitCode: output.exitCode, stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(Data(output.stdout.utf8))
    }
}
