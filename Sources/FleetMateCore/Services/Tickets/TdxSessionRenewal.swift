import Foundation

// The app window and the background inbox helper are two processes holding
// one TeamDynamix sign-in. The session lives in the keychain
// (`TdxSessionCache`); each process keeps a copy in memory. These pieces keep
// the copies in step and decide when to renew, so neither process sits on an
// expired token while the other holds a fresh one.

/// When to renew the TeamDynamix session, and how to back off when silent
/// sign-in keeps failing.
public struct TdxRenewalSchedule: Sendable, Equatable {
    /// Renew this long before the session expires.
    public var lead: TimeInterval
    /// Waits after the 1st, 2nd, 3rd… consecutive failure; the last repeats.
    public var retryDelays: [TimeInterval]
    /// A session with less than this left is treated as already gone.
    public var expiryMargin: TimeInterval
    /// Consecutive failures, with no usable session, before the person is
    /// asked to sign in.
    public var failuresBeforeSignInPrompt: Int

    public init(lead: TimeInterval = 2 * 3600,
                retryDelays: [TimeInterval] = [60, 5 * 60, 15 * 60],
                expiryMargin: TimeInterval = 5 * 60,
                failuresBeforeSignInPrompt: Int = 2) {
        self.lead = lead
        self.retryDelays = retryDelays
        self.expiryMargin = expiryMargin
        self.failuresBeforeSignInPrompt = failuresBeforeSignInPrompt
    }

    public static let standard = TdxRenewalSchedule()

    /// The wait after `failures` consecutive failed attempts: 1, 5, then
    /// 15 minutes, and every 15 minutes after that.
    public func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0, !retryDelays.isEmpty else { return 0 }
        return retryDelays[min(failures, retryDelays.count) - 1]
    }

    /// True when `expiry` leaves enough time to keep using the session.
    public func isUsable(expiry: Date?, now: Date) -> Bool {
        guard let expiry else { return false }
        return expiry > now.addingTimeInterval(expiryMargin)
    }

    /// When the next renewal attempt is due.
    ///
    /// After a failure the backoff decides, whatever the session's state.
    /// Otherwise a missing or nearly expired session is renewed now, and a
    /// healthy one `lead` before it expires.
    public func nextAttempt(expiry: Date?, failures: Int, lastAttempt: Date?, now: Date) -> Date {
        if failures > 0, let lastAttempt {
            return max(now, lastAttempt.addingTimeInterval(retryDelay(afterFailures: failures)))
        }
        guard let expiry, isUsable(expiry: expiry, now: now) else { return now }
        return max(now, expiry.addingTimeInterval(-lead))
    }

    /// True when silent renewal has failed enough times, with no usable
    /// session left, that only the person can fix it.
    public func needsInteractiveSignIn(expiry: Date?, failures: Int, now: Date) -> Bool {
        !isUsable(expiry: expiry, now: now) && failures >= failuresBeforeSignInPrompt
    }
}

/// What the TeamDynamix row in the sign-in panel may claim.
public enum TdxAuthStatus {
    /// The state to show. A probe's `.valid` stands only while a usable
    /// session is still held: once it lapses the row says Expired, whatever
    /// the last probe found, so "Valid" never sits beside "not signed in".
    /// A service account is a usable credential of its own.
    public static func effectiveState(reported: AuthTokenState,
                                      hasUserSession: Bool,
                                      hasServiceAccount: Bool) -> AuthTokenState {
        guard case .valid = reported else { return reported }
        return hasUserSession || hasServiceAccount ? reported : .expired
    }
}

extension TdxSessionCache {
    /// The expiry a TeamDynamix JWT carries, or nil when it is not a JWT.
    public static func jwtExpiry(_ token: String) -> Date? {
        TdxCliSessionCache.tokenExpiry(token)
    }

    /// Worth adopting in place of the session a process holds: verified for
    /// the expected address on this tenant, and with at least `margin` left.
    /// Unlike `matches`, a session with under an hour left still counts —
    /// it is better than none, and renewal replaces it.
    public func isAdoptable(expectedUpn: String?, baseUrl: String?, now: Date,
                            margin: TimeInterval = TdxRenewalSchedule.standard.expiryMargin) -> Bool {
        guard expiry > now.addingTimeInterval(margin),
              let expected = expectedUpn?.trimmingCharacters(in: .whitespaces).lowercased(),
              !expected.isEmpty,
              let baseUrl, baseUrl == self.baseUrl else { return false }
        return confirmedUpn == expected
    }
}

/// Tells the other process when the saved session changed, and keeps both
/// from running the sign-in chain at the same moment.
public enum TdxSessionSync {
    /// Posted after a process saves or clears the shared session.
    public static var changedNotification: Notification.Name {
        Notification.Name("\(AppIdentity.mainBundleIdentifier ?? "fleetmate").tdx-session-changed")
    }

    /// This process, so an observer can skip its own posts.
    public static var senderId: String { String(ProcessInfo.processInfo.processIdentifier) }

    public static func postChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: senderId, userInfo: nil, deliverImmediately: true)
    }

    /// Run `body` with the renewal lock held, or return nil without running
    /// it when the other process is renewing right now.
    @MainActor
    public static func withRenewalLock<T>(at path: String = defaultLockPath,
                                          _ body: () async -> T) async -> T? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return await body() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return await body()
    }

    public static var defaultLockPath: String {
        let dir = NSString(string: AppEdition.current.supportDirectory).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("tdx-renewal.lock")
    }
}
