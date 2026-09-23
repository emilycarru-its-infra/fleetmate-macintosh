import Foundation

// MARK: - GitHub notifications (the inbox)

/// What a notification is about. GitHub's `subject.type` is an open string;
/// the cases here are the ones the app can route somewhere useful.
public enum GitHubNotificationSubjectType: String, Codable, Sendable {
    case pullRequest = "PullRequest"
    case issue = "Issue"
    case release = "Release"
    case discussion = "Discussion"
    case commit = "Commit"
    case checkSuite = "CheckSuite"
    case repositoryVulnerabilityAlert = "RepositoryVulnerabilityAlert"
    case other

    public init(raw: String?) {
        self = GitHubNotificationSubjectType(rawValue: raw ?? "") ?? .other
    }

    public var symbolName: String {
        switch self {
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "smallcircle.filled.circle"
        case .release: return "tag"
        case .discussion: return "bubble.left.and.bubble.right"
        case .commit: return "circle.dotted.and.circle"
        case .checkSuite: return "checkmark.seal"
        case .repositoryVulnerabilityAlert: return "exclamationmark.shield"
        case .other: return "bell"
        }
    }
}

/// Why the signed-in user received the notification. Mirrors GitHub's
/// documented reasons; anything new falls back to `.other` with the raw text.
public enum GitHubNotificationReason: Sendable, Hashable {
    case assign, author, comment, ciActivity, invitation, manual, memberFeatureRequested
    case mention, reviewRequested, securityAlert, stateChange, subscribed, teamMention
    case other(String)

    public init(raw: String?) {
        switch raw ?? "" {
        case "assign": self = .assign
        case "author": self = .author
        case "comment": self = .comment
        case "ci_activity": self = .ciActivity
        case "invitation": self = .invitation
        case "manual": self = .manual
        case "member_feature_requested": self = .memberFeatureRequested
        case "mention": self = .mention
        case "review_requested": self = .reviewRequested
        case "security_alert": self = .securityAlert
        case "state_change": self = .stateChange
        case "subscribed": self = .subscribed
        case "team_mention": self = .teamMention
        case let raw: self = .other(raw)
        }
    }

    /// Short human label for the reason pill.
    public var displayName: String {
        switch self {
        case .assign: return "Assigned"
        case .author: return "Author"
        case .comment: return "Comment"
        case .ciActivity: return "CI"
        case .invitation: return "Invitation"
        case .manual: return "Subscribed"
        case .memberFeatureRequested: return "Feature request"
        case .mention: return "Mentioned"
        case .reviewRequested: return "Review requested"
        case .securityAlert: return "Security"
        case .stateChange: return "State change"
        case .subscribed: return "Watching"
        case .teamMention: return "Team mention"
        case .other(let raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Reasons that ask something of the user sort above passive ones.
    public var isActionable: Bool {
        switch self {
        case .assign, .mention, .reviewRequested, .securityAlert, .invitation, .teamMention: return true
        default: return false
        }
    }
}

/// One notification thread from `GET /notifications`.
public struct GitHubNotification: Identifiable, Sendable, Hashable {
    /// Thread id, the handle every write endpoint takes.
    public let id: String
    public let reason: GitHubNotificationReason
    public var unread: Bool
    public let updatedAt: Date?
    public let lastReadAt: Date?
    public let subjectTitle: String
    public let subjectType: GitHubNotificationSubjectType
    /// API URL of the subject (e.g. `.../repos/o/r/pulls/12`), nil for some types.
    public let subjectApiUrl: String?
    /// "owner/name"
    public let repository: String
    public let repositoryWebUrl: String

    public init(
        id: String,
        reason: GitHubNotificationReason,
        unread: Bool,
        updatedAt: Date?,
        lastReadAt: Date?,
        subjectTitle: String,
        subjectType: GitHubNotificationSubjectType,
        subjectApiUrl: String?,
        repository: String,
        repositoryWebUrl: String
    ) {
        self.id = id
        self.reason = reason
        self.unread = unread
        self.updatedAt = updatedAt
        self.lastReadAt = lastReadAt
        self.subjectTitle = subjectTitle
        self.subjectType = subjectType
        self.subjectApiUrl = subjectApiUrl
        self.repository = repository
        self.repositoryWebUrl = repositoryWebUrl
    }

    /// Owner login, from "owner/name".
    public var owner: String { repository.split(separator: "/").first.map(String.init) ?? "" }
    /// Repository name, from "owner/name".
    public var repositoryName: String { repository.split(separator: "/").dropFirst().first.map(String.init) ?? "" }

    /// The PR or issue number when the subject is one, parsed off the API URL.
    public var subjectNumber: Int? {
        guard let subjectApiUrl, let last = subjectApiUrl.split(separator: "/").last else { return nil }
        return Int(last)
    }

    /// Best-effort browser URL for the subject. The API only hands back API
    /// URLs, so PRs and issues are rewritten; everything else lands on the repo.
    public var webUrl: String {
        switch subjectType {
        case .pullRequest:
            if let number = subjectNumber { return "\(repositoryWebUrl)/pull/\(number)" }
        case .issue:
            if let number = subjectNumber { return "\(repositoryWebUrl)/issues/\(number)" }
        case .release:
            return "\(repositoryWebUrl)/releases"
        case .discussion:
            if let number = subjectNumber { return "\(repositoryWebUrl)/discussions/\(number)" }
        case .commit:
            if let sha = subjectApiUrl?.split(separator: "/").last { return "\(repositoryWebUrl)/commit/\(sha)" }
        case .checkSuite:
            return "\(repositoryWebUrl)/actions"
        case .repositoryVulnerabilityAlert:
            return "\(repositoryWebUrl)/security/dependabot"
        case .other:
            break
        }
        return repositoryWebUrl
    }

    public static func == (lhs: GitHubNotification, rhs: GitHubNotification) -> Bool {
        lhs.id == rhs.id && lhs.unread == rhs.unread && lhs.updatedAt == rhs.updatedAt
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
