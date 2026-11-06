import AppKit
import ServiceManagement
import FleetMateCore

/// Picks between the app window and the background inbox helper. The helper
/// is a copy of this binary in its own bundle nested inside the app, at
/// Contents/Library/LoginItems, started by launchd at login.
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
/// on the app's own schedule.
///
/// The helper bundle has its own bundle id (the app's plus `.inbox-agent`),
/// so macOS never mistakes it for the app: Dock clicks and links go to the
/// app itself. Everything it reads — config folder, edition, preference
/// domain, keychain items — is resolved through `AppIdentity` to the app's
/// identity, which the helper's Info.plist names.
@MainActor
final class InboxAgent: NSObject, NSApplicationDelegate {
    nonisolated static let argument = "--inbox-agent"

    nonisolated static var isAgentProcess: Bool {
        AppIdentity.isInboxHelperBundle || CommandLine.arguments.contains(argument)
    }

    /// The app's bundle id, from the app or from inside the helper.
    nonisolated static var mainBundleIdentifier: String {
        AppIdentity.mainBundleIdentifier ?? "ca.ecuad.macadmin.fleetmate"
    }

    /// The launchd job label, which is also the helper's bundle id.
    nonisolated static var label: String {
        AppIdentity.inboxHelperIdentifier(main: mainBundleIdentifier)
    }

    /// The launchd plist bundled at Contents/Library/LaunchAgents.
    nonisolated static var plistName: String { "\(label).plist" }

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
            // install unloads it; and a job registered by an older install
            // still runs the app's own executable instead of the helper.
            // Register again so the current helper runs without a re-login.
            let state = jobState
            guard InboxHelperJob.needsReload(state) else { return }
            do {
                try? service.unregister()
                try service.register()
                dbg.info("Inbox helper registered again (was \(state))", category: "inbox")
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

    /// Move a registration from an older install onto the helper bundle as
    /// soon as the app opens, without waiting for sign-in. Does nothing when
    /// the helper is not registered yet: first registration still waits until
    /// TeamDynamix is signed in.
    static func migrateLegacyRegistration() {
        guard !isAgentProcess, Bundle.main.bundlePath.hasPrefix("/Applications/"),
              SMAppService.agent(plistName: plistName).status == .enabled,
              jobState == .legacyProgram else { return }
        registerIfInstalled()
    }

    /// The helper's launchd job in this login session.
    private static var jobState: InboxHelperJob.State {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/\(label)"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return InboxHelperJob.state(launchctlPrintOutput: String(decoding: data, as: UTF8.self),
                                        exitStatus: task.terminationStatus)
        } catch {
            return .current
        }
    }

    nonisolated static func run() {
        MainActor.assumeIsolated {
            guard AppIdentity.isInboxHelperBundle else {
                retireLegacyAgent()
                return
            }
            // Settings the helper reads through UserDefaults.standard live in
            // the app's domain, not the helper's own.
            UserDefaults.standard.addSuite(named: mainBundleIdentifier)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let agent = InboxAgent()
            app.delegate = agent
            withExtendedLifetime(agent) { app.run() }
        }
    }

    /// launchd started the app's own executable as the helper: a job
    /// registered by an install from before the helper had its own bundle.
    /// Running as the app's bundle id is what made macOS send it Dock clicks,
    /// so don't stay up. Remove the old job; the app registers the helper
    /// bundle the next time it opens and signs in.
    private static func retireLegacyAgent() {
        dbg.info("Old inbox helper registration found; removing it for the helper bundle", category: "inbox")
        try? SMAppService.agent(plistName: plistName).unregister()
        exit(0)
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

    /// Sign in, find who "me" is (which starts the inbox), and keep the
    /// session renewed. Renewal is shared with the app window: whichever
    /// process renews first saves the session, and the other adopts it.
    private func keepSignedIn(_ state: AppState) async {
        // The first sign-in may reuse the app's saved session.
        state.attemptSilentTdxSso(useCache: true)
        state.startTdxRenewal()
        while !Task.isCancelled {
            await state.resolveTdxMe()
            try? await Task.sleep(for: .seconds(state.tdxMe == nil ? 30 : 600))
        }
    }
}
