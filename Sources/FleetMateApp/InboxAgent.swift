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
            // Login Items can say enabled while launchd has no job, after an
            // install unloads it. Register again so it runs without a re-login.
            guard !isJobLoaded else { return }
            do {
                try? service.unregister()
                try service.register()
                dbg.info("Inbox helper was not loaded; registered it again", category: "inbox")
            } catch {
                dbg.warn("Inbox helper reload failed: \(error.localizedDescription)", category: "inbox")
            }
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

    /// Whether launchd has the helper's job in this login session.
    private static var isJobLoaded: Bool {
        let label = (plistName as NSString).deletingPathExtension
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return true
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
        dbg.info("Inbox helper started", category: "inbox")
        signInTask = Task { await self.run() }
    }

    /// launchd restarts the helper whenever it exits, so it never quits on
    /// purpose: with TeamDynamix not set up yet it checks again each hour.
    private func run() async {
        while !Task.isCancelled {
            let state = AppState()
            if state.config.isTdxConfigured {
                appState = state
                await keepSignedIn(state)
                return
            }
            dbg.info("Inbox helper waiting: TeamDynamix is not configured", category: "inbox")
            try? await Task.sleep(for: .seconds(3600))
        }
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

    /// Posted by the helper with a link's text as the object, for the window
    /// copy of the app to open.
    nonisolated static var openURLNotification: Notification.Name {
        Notification.Name("\(Bundle.main.bundleIdentifier ?? "ca.ecuad.macadmin.fleetmate").open-url")
    }

    /// The copy of the app with a window, when one is already running.
    private var windowInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy == .regular }
    }

    /// macOS can hand a Dock click or a link to the helper rather than the
    /// window copy, since both share the bundle. Pass it on to the window copy
    /// when one is running, and start one only when none is.
    private func openWindowInstance(urls: [URL]) {
        if let running = windowInstance {
            running.activate()
            for url in urls {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.openURLNotification, object: url.absoluteString,
                    userInfo: nil, deliverImmediately: true)
            }
            return
        }
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
