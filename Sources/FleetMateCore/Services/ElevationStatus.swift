import Foundation

/// What the user's elevation session for one domain is doing, as far as the
/// app can tell. Shown in the window chrome so a slow first action of the day
/// reads as "starting" rather than a hang.
public enum ElevationStatus: Sendable, Equatable {
    /// No session container exists; the next action starts one.
    case idle
    /// The container is being created or has not reached Running yet.
    case starting
    /// Running, until `expires` (nil when the container carries no expiry tag).
    case ready(expires: Date?)
    /// Past its expiry or stopped; the next action restarts it.
    case expired
    /// The state could not be read (az failed for another reason).
    case unknown

    /// Severity for aggregating several domains into one indicator:
    /// starting > unknown > expired > idle > ready.
    public var rank: Int {
        switch self {
        case .starting: return 4
        case .unknown: return 3
        case .expired: return 2
        case .idle: return 1
        case .ready: return 0
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .expired: return "Stopped"
        case .unknown: return "Unknown"
        }
    }
}

/// Plain-language wording for elevated sessions, shared by the toolbar and
/// the Authentication popover so both say the same thing.
public enum ElevationWording {
    /// What the feature is called wherever it is listed.
    public static let title = "Elevated sessions"

    /// One line on what an elevated session is, for tooltips.
    public static let explainer = "Elevated sessions are Azure containers that run admin actions as a managed identity, "
        + "authorized by your az sign-in. One starts on first use, takes about a minute, "
        + "and then stays ready for up to \(ElevationSession.defaultTtlHours) hours."

    /// The toolbar's text beside the shield. Nil when there is nothing worth
    /// saying: a stopped or idle session restarts on its own when needed.
    public static func toolbarText(_ status: ElevationStatus) -> String? {
        switch status {
        case .starting: return "Elevation starting…"
        case .ready: return "Elevation ready"
        case .idle, .expired, .unknown: return nil
        }
    }

    /// The short state shown in a session's pill.
    public static func stateLabel(_ status: ElevationStatus) -> String {
        switch status {
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .idle, .expired: return "Stopped"
        case .unknown: return "Not checked"
        }
    }

    /// The line under a session's name: what happens next, or time left.
    public static func detail(_ status: ElevationStatus, at now: Date = Date()) -> String {
        switch status {
        case .ready(let expires?):
            return "Ready, \(remaining(expires.timeIntervalSince(now))) left"
        case .ready:
            return "Ready"
        case .starting:
            return "Starting… a cold start takes about a minute"
        case .idle, .expired:
            return "Stopped, restarts on next use"
        case .unknown:
            return "Not checked yet"
        }
    }

    /// "3h 12m" or "45m"; never negative.
    public static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// What a domain's session is used for, so its row reads as more than
    /// an internal name.
    public static func domainTitle(_ domain: GraphDomain) -> String {
        switch domain {
        case .devices: return "Devices (Intune, Microsoft Graph)"
        case .identity: return "Identity (Entra ID)"
        case .systems: return "Systems (app registrations)"
        case .cloud: return "Cloud (SharePoint, Teams)"
        case .security: return "Security"
        case .terraform: return "Infrastructure"
        }
    }
}

/// A snapshot of one session container, read with `az container show`.
public struct ElevationSessionInfo: Sendable, Equatable {
    /// `instanceView.state`, e.g. Running, Pending, Terminated.
    public var state: String?
    /// The container's `expires` tag (unix seconds), written when it is created.
    public var expires: Date?
    /// True when az reported the container does not exist.
    public var notFound: Bool
    /// True when az failed for any other reason.
    public var failed: Bool

    public init(state: String? = nil, expires: Date? = nil, notFound: Bool = false, failed: Bool = false) {
        self.state = state
        self.expires = expires
        self.notFound = notFound
        self.failed = failed
    }

    /// Classify the snapshot at `now`. `creating` marks a create call in
    /// flight in this process, before any container exists to read.
    public func status(at now: Date = Date(), creating: Bool = false) -> ElevationStatus {
        if creating { return .starting }
        if notFound { return .idle }
        if failed { return .unknown }
        switch (state ?? "").lowercased() {
        case "running":
            if let expires, expires <= now { return .expired }
            return .ready(expires: expires)
        case "pending", "waiting", "creating", "":
            return .starting
        case "terminated", "stopped", "succeeded", "failed":
            return .expired
        default:
            return .unknown
        }
    }
}

extension ElevationSession {
    /// Read-only snapshot of a domain's session container: state and expiry.
    public func sessionInfo(_ domain: GraphDomain) async -> ElevationSessionInfo {
        let result = await ProcessRunner.run(Self.locateAz(), [
            "container", "show",
            "--resource-group", Self.sessionsResourceGroup,
            "--name", Self.sessionName(for: domain),
            "--query", "{state:instanceView.state, expires:tags.expires}",
            "-o", "json",
        ])
        guard result.succeeded else {
            let err = result.stderr
            if err.contains("ResourceNotFound") || err.contains("was not found") || err.contains("could not be found") {
                return ElevationSessionInfo(notFound: true)
            }
            return ElevationSessionInfo(failed: true)
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ElevationSessionInfo(failed: true) }
        let expires = (json["expires"] as? String).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        return ElevationSessionInfo(state: json["state"] as? String, expires: expires)
    }
}
