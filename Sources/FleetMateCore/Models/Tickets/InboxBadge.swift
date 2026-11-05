import Foundation

/// The unread count the ticket inbox shows as a red badge: on the toolbar's
/// mail icon, and on the app's Dock icon the way Mail shows unread mail.
public enum InboxBadge {
    /// UserDefaults key for Settings ▸ Appearance ▸ "Show unread count on
    /// Dock icon".
    public static let dockSettingKey = "tickets.showDockBadge"

    /// The Dock badge is on until someone turns it off.
    public static let dockSettingDefault = true

    /// Above this the badge reads "999+", so it stays a badge and not a bar.
    public static let cap = 999

    /// The badge's text for a count, or nil at zero, where no badge shows.
    public static func text(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > cap ? "\(cap)+" : "\(count)"
    }

    /// The Dock icon's badge label, or nil to clear it.
    ///
    /// - Parameters:
    ///   - unreadCount: unread comments in the inbox.
    ///   - inboxReady: false until the first full pass finishes; until then
    ///     the count is incomplete and the inbox is hidden, so is the badge.
    ///   - enabled: the Settings switch.
    ///   - ticketsOn: false in FleetMate with the Tickets module switched off.
    ///   - isHelper: the background inbox helper has no Dock icon to badge.
    public static func dockLabel(unreadCount: Int, inboxReady: Bool, enabled: Bool,
                                 ticketsOn: Bool, isHelper: Bool) -> String? {
        guard !isHelper, enabled, ticketsOn, inboxReady else { return nil }
        return text(count: unreadCount)
    }

    /// The Settings switch, defaulting on when nothing is stored.
    public static func isDockBadgeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: dockSettingKey) as? Bool ?? dockSettingDefault
    }
}
