import Foundation

/// Runs the two CLI sign-ins FleetMate depends on but can't perform itself.
///
/// `az login` is the trust anchor for Azure DevOps and for every `aze`
/// elevation session; `gh auth login` backs the GitHub task provider. Both
/// previously left the operator to find a terminal and remember the incantation
/// — including which tenant and subscription to target, which is the part
/// that's easy to get wrong and easy for the app to know.
public enum CliSignIn {

    public struct Outcome: Sendable {
        public let succeeded: Bool
        /// One line, suitable for a status row.
        public let message: String

        public init(succeeded: Bool, message: String) {
            self.succeeded = succeeded
            self.message = message
        }
    }

    // MARK: - Azure

    /// The command `azLogin` will run, for display next to the button.
    ///
    /// Built from config rather than hard-coded: the GUIDs are overridable in
    /// config.yaml, and a login scoped to the wrong tenant is worse than none.
    public static func azLoginCommandDescription(config: FleetMateConfig) -> String {
        "az login --tenant \(config.effectiveAzureTenantId)"
    }

    /// Sign in to Azure, scoped to the configured tenant, then select the
    /// configured subscription.
    ///
    /// `az login` opens the browser itself and needs no terminal, so this runs
    /// in-process and reports back. stdin is deliberately `/dev/null`: without
    /// it a device-code fallback would sit waiting for input that can never
    /// arrive, and the button would hang instead of failing.
    public static func azLogin(config: FleetMateConfig) async -> Outcome {
        let az = resolveExecutable("az")
        let tenant = config.effectiveAzureTenantId
        let subscription = config.effectiveAzureSubscriptionId

        let login = await run(az, ["login", "--tenant", tenant, "--output", "none", "--only-show-errors"])
        guard login.code == 0 else {
            let detail = login.stderr.isEmpty ? "az login failed (exit \(login.code))" : login.stderr.firstLine
            return Outcome(succeeded: false, message: detail)
        }

        // Best-effort: some identities have no subscription, which doesn't make
        // the sign-in itself a failure.
        let select = await run(az, ["account", "set", "--subscription", subscription, "--only-show-errors"])
        if select.code != 0 {
            return Outcome(succeeded: true, message: "Signed in — subscription not set: \(select.stderr.firstLine)")
        }
        return Outcome(succeeded: true, message: "Signed in to tenant \(tenant.prefix(8))…")
    }

    // MARK: - GitHub

    public static let ghLoginCommandDescription = "gh auth login --web"

    /// Start `gh auth login` in Terminal.
    ///
    /// Unlike `az`, gh prompts on the TTY even with every flag supplied, so it
    /// can't run in-process. This writes a one-shot `.command` script and opens
    /// it, which hands the job to Terminal without needing Apple Events
    /// permission the way scripting Terminal directly would.
    public static func ghLoginInTerminal() -> Outcome {
        let gh = resolveExecutable("gh")
        let script = """
        #!/bin/zsh
        echo "FleetMate: signing in to GitHub…"
        exec "\(gh)" auth login --hostname github.com --git-protocol https --web
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmate-gh-login-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return Outcome(succeeded: false, message: "Couldn't stage the login script: \(error.localizedDescription)")
        }

        guard openInTerminal(url) else {
            return Outcome(succeeded: false, message: "Couldn't open Terminal — run `gh auth login` manually")
        }
        return Outcome(succeeded: true, message: "Continue in Terminal, then Re-check")
    }

    // MARK: - Plumbing

    /// Hand a `.command` file to Terminal via `open`, which avoids the Apple
    /// Events permission prompt that scripting Terminal directly would trigger.
    private static func openInTerminal(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", url.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Absolute path where we can find it — a GUI app's PATH doesn't include
    /// Homebrew, so bare names would resolve only via the `env` fallback.
    public static func resolveExecutable(_ name: String) -> String {
        ProcessRunner.resolve(name)
    }

    private struct RunResult {
        let stdout: String
        let stderr: String
        let code: Int32
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> RunResult {
        let result = await ProcessRunner.run(executable, arguments)
        return RunResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }
}

private extension String {
    /// First non-empty line, for squeezing az's multi-line errors into a row.
    var firstLine: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? self
    }
}
