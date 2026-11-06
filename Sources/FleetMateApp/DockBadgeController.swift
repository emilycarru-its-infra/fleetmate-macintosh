import AppKit
import Combine
import UserNotifications
import FleetMateCore

/// Shows the ticket inbox's unread count on the app's Dock icon, as Mail does
/// for unread mail, and keeps it current as comments arrive or are read.
///
/// The Dock badge needs no notification permission. macOS hides it only when
/// someone turns off badges for the app in System Settings ▸ Notifications,
/// which `DockBadgeSystemSetting` reads so Settings can say so.
@MainActor
final class DockBadgeController {
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    /// Nil in the background inbox helper, which has no Dock icon.
    static func make(for appState: AppState) -> DockBadgeController? {
        InboxAgent.isAgentProcess ? nil : DockBadgeController(appState: appState)
    }

    private init(appState: AppState) {
        self.appState = appState
        // objectWillChange fires before the change lands; reading on the next
        // run-loop turn sees the new count. The debounce also folds a burst
        // of changes, such as a scan saving after every ticket, into one.
        Publishers.Merge3(
            appState.ticketInbox.objectWillChange.map { _ in () },
            appState.$modules.map { _ in () },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }
        )
        .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
        .store(in: &cancellables)
    }

    func update() {
        guard let appState else { return }
        let inbox = appState.ticketInbox
        let label = InboxBadge.dockLabel(
            unreadCount: inbox.unreadCount,
            inboxReady: inbox.isReady,
            enabled: InboxBadge.isDockBadgeEnabled(),
            ticketsOn: AppEdition.current.isTicketsOnly || appState.modules.isOn(.tickets),
            isHelper: InboxAgent.isAgentProcess
        )
        let tile = NSApplication.shared.dockTile
        if tile.badgeLabel != label { tile.badgeLabel = label }
    }
}

/// Whether System Settings ▸ Notifications lets this app badge its icon.
enum DockBadgeSystemSetting {
    /// False only when someone has turned badges off for the app. An app that
    /// has never asked for notification permission badges freely.
    static func badgesAllowed() async -> Bool {
        // UNUserNotificationCenter traps outside an app bundle (swift run).
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return true }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined { return true }
        return settings.badgeSetting != .disabled
    }

    /// This app's page in System Settings ▸ Notifications.
    static var settingsURL: URL? {
        let id = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    }
}
