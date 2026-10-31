import AppKit
import ServiceManagement
import FleetMateCore

/// Picks between the app window and the background inbox helper. The helper
/// is the same binary, started by launchd at login with `--inbox-agent`.
@main
enum AppMain {
    static func main() {
        if InboxAgent.isAgentProcess {
            InboxAgent.run()
        } else {
            FleetMateApp.main()
        }
    }
}

/// Keeps the ticket inbox current while the app is closed.
///
/// It has no Dock icon, menu bar or window. It signs in to TDX the way the
/// app does — silently, never with a sign-in sheet — then builds the inbox
/// on the app's own schedule. When someone opens the app while the helper is
/// running, macOS hands the request to the helper, which starts a separate
/// window instance.
@MainActor
final class InboxAgent: NSObject, NSApplicationDelegate {
    static let argument = "--inbox-agent"

    nonisolated static var isAgentProcess: Bool {
        CommandLine.arguments.contains(argument)
    }

    /// The launchd plist bundled at Contents/Library/LaunchAgents.
    nonisolated static var plistName: String {
        "\(Bundle.main.bundleIdentifier ?? "ca.ecuad.macadmin.fleetmate").inbox-agent.plist"
    }

    /// Register the helper with macOS, once, from an installed copy of the
    /// app. A build run from anywhere else would register its own path.
    static func registerIfInstalled() {
        guard !isAgentProcess, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }

        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            // Turned off in System Settings ▸ Login Items; respect that.
            dbg.info("Inbox helper is turned off in Login Items", category: "inbox")
            return
        default:
            do {
                try service.register()
                dbg.info("Inbox helper registered", category: "inbox")
            } catch {
                dbg.warn("Inbox helper registration failed: \(error.localizedDescription)", category: "inbox")
            }
        }
    }

    nonisolated static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let agent = InboxAgent()
            app.delegate = agent
            withExtendedLifetime(agent) { app.run() }
        }
    }

    private var appState: AppState?
    private var signInTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        guard state.config.isTdxConfigured else {
            dbg.info("Inbox helper exiting: TeamDynamix is not configured", category: "inbox")
            exit(0)
        }
        dbg.info("Inbox helper started", category: "inbox")
        appState = state
        signInTask = Task { await self.keepSignedIn(state) }
    }

    /// Sign in, find who "me" is (which starts the inbox), and refresh the
    /// sign-in twice a day, inside the session's one-day lifetime.
    private func keepSignedIn(_ state: AppState) async {
        var useCache = true
        while !Task.isCancelled {
            // The first sign-in may reuse the app's saved session; each later
            // one is a fresh sign-in, which renews the saved session for the
            // app's next launch.
            state.attemptSilentTdxSso(useCache: useCache)
            useCache = false
            for _ in 0..<20 where state.tdxMe == nil {
                try? await Task.sleep(for: .seconds(30))
                await state.resolveTdxMe()
            }
            if state.tdxMe == nil {
                dbg.warn("Inbox helper couldn't sign in; retrying in an hour", category: "inbox")
                try? await Task.sleep(for: .seconds(3600))
            } else {
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }

    // MARK: - Opening the app while the helper runs

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindowInstance(urls: [])
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openWindowInstance(urls: urls)
    }

    private func openWindowInstance(urls: [URL]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
        }
    }
}
