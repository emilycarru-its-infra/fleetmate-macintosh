import Foundation

// MARK: - Unified Pull Request

/// Which system a pull request came from.
public enum PullRequestSource: String, Codable, Sendable, CaseIterable {
    case azureDevOps
    case gitHub

    public var displayName: String {
        switch self {
        case .azureDevOps: return "Azure DevOps"
        case .gitHub:      return "GitHub"
        }
    }

    /// SF Symbol used as the row badge.
    public var symbolName: String {
        switch self {
        case .azureDevOps: return "infinity"
        case .gitHub:      return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// How the signed-in user relates to a pull request. Mirrors the two sections of
/// the Azure DevOps "My pull requests" page.
public enum PullRequestRelation: String, Codable, Sendable, CaseIterable {
    /// The user opened the PR.
    case createdByMe
    /// The user is a reviewer (AzDO) or a review is requested of them / they are
    /// an assignee (GitHub).
    case assignedToMe

    public var sectionTitle: String {
        switch self {
        case .createdByMe:  return "Created by me"
        case .assignedToMe: return "Assigned to me"
        }
    }
}

/// Lifecycle state, normalized across both providers.
public enum PullRequestState: String, Codable, Sendable {
    case open
    case draft
    case merged
    case closed

    public var displayName: String {
        switch self {
        case .open:   return "Open"
        case .draft:  return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }
}

/// A reviewer's standing on a pull request.
public enum PullRequestReviewVote: Int, Codable, Sendable {
    case rejected = -10
    case waitingForAuthor = -5
    case noVote = 0
    case approvedWithSuggestions = 5
    case approved = 10

    /// Maps an Azure DevOps `vote` integer onto the enum, tolerating unknowns.
    public static func fromAzureDevOps(_ raw: Int?) -> PullRequestReviewVote {
        guard let raw else { return .noVote }
        return PullRequestReviewVote(rawValue: raw) ?? .noVote
    }

    /// Maps a GitHub review state string onto the enum.
    public static func fromGitHub(_ raw: String?) -> PullRequestReviewVote {
        switch raw?.uppercased() {
        case "APPROVED":          return .approved
        case "CHANGES_REQUESTED": return .rejected
        case "COMMENTED":         return .approvedWithSuggestions
        default:                  return .noVote
        }
    }
}

/// One reviewer on a pull request.
public struct PullRequestReviewer: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let vote: PullRequestReviewVote
    public let isRequired: Bool

    public init(id: String, displayName: String, vote: PullRequestReviewVote = .noVote, isRequired: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.vote = vote
        self.isRequired = isRequired
    }

    /// Up to two letters for the avatar bubble, e.g. "Alex Doe" → "RC".
    public var initials: String {
        let parts = displayName
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// A pull request from either Azure DevOps or GitHub, flattened into one shape so
/// the dashboard queue can render both in a single list.
public struct UnifiedPullRequest: Identifiable, Sendable, Hashable {
    public let source: PullRequestSource
    /// PR number (AzDO `pullRequestId`, GitHub `number`).
    public let number: Int
    public let title: String
    public let authorName: String
    /// AzDO: the project name. GitHub: the owner/org login.
    public let container: String
    public let repository: String
    public let sourceBranch: String
    public let targetBranch: String
    public let createdAt: Date?
    /// Last comment/review activity. Azure DevOps does not return this on the PR
    /// list endpoint, so it is filled in during thread enrichment.
    public var updatedAt: Date?
    public let state: PullRequestState
    public let hasConflicts: Bool
    /// Human comment threads. Enriched separately for Azure DevOps.
    public var commentCount: Int
    public let reviewers: [PullRequestReviewer]
    public let webUrl: String
    /// A PR can be both created by and assigned to the same user; the queue shows
    /// it under every section it belongs to.
    public var relations: Set<PullRequestRelation>

    public var id: String { "\(source.rawValue):\(container)/\(repository)#\(number)" }

    public init(
        source: PullRequestSource,
        number: Int,
        title: String,
        authorName: String,
        container: String,
        repository: String,
        sourceBranch: String,
        targetBranch: String,
        createdAt: Date?,
        updatedAt: Date?,
        state: PullRequestState,
        hasConflicts: Bool = false,
        commentCount: Int = 0,
        reviewers: [PullRequestReviewer] = [],
        webUrl: String,
        relations: Set<PullRequestRelation> = []
    ) {
        self.source = source
        self.number = number
        self.title = title
        self.authorName = authorName
        self.container = container
        self.repository = repository
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.hasConflicts = hasConflicts
        self.commentCount = commentCount
        self.reviewers = reviewers
        self.webUrl = webUrl
        self.relations = relations
    }

    /// The `!10716` / `#42` reference shown next to the author.
    public var reference: String {
        switch source {
        case .azureDevOps: return "!\(number)"
        case .gitHub:      return "#\(number)"
        }
    }

    /// Most recent meaningful timestamp, used for sorting.
    public var lastActivity: Date {
        max(updatedAt ?? .distantPast, createdAt ?? .distantPast)
    }

    /// True when the PR has been touched since it was opened — drives the
    /// "Updated ..." vs "Created ..." wording, matching the Azure DevOps queue.
    public var wasUpdatedAfterCreation: Bool {
        guard let created = createdAt, let updated = updatedAt else { return false }
        return updated.timeIntervalSince(created) > 60
    }

    public static func == (lhs: UnifiedPullRequest, rhs: UnifiedPullRequest) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Queue

/// The signed-in user's pull request queue across every configured provider.
public struct PullRequestQueue: Sendable {
    public var pullRequests: [UnifiedPullRequest]
    /// Soft failures, one per provider that could not be reached. The queue still
    /// renders whatever the other providers returned.
    public var errors: [PullRequestQueueError]

    public init(pullRequests: [UnifiedPullRequest] = [], errors: [PullRequestQueueError] = []) {
        self.pullRequests = pullRequests
        self.errors = errors
    }

    public func section(_ relation: PullRequestRelation) -> [UnifiedPullRequest] {
        pullRequests
            .filter { $0.relations.contains(relation) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    public var isEmpty: Bool { pullRequests.isEmpty }

    /// Merges another provider's results in, unioning relations for PRs that
    /// appear in more than one query.
    public mutating func merge(_ other: PullRequestQueue) {
        for pr in other.pullRequests { insert(pr) }
        errors.append(contentsOf: other.errors)
    }

    public mutating func insert(_ pr: UnifiedPullRequest) {
        if let idx = pullRequests.firstIndex(where: { $0.id == pr.id }) {
            pullRequests[idx].relations.formUnion(pr.relations)
        } else {
            pullRequests.append(pr)
        }
    }
}

// MARK: - Date Parsing

/// Lenient ISO-8601 parsing. Azure DevOps and GitHub both emit timestamps with
/// and without fractional seconds depending on the endpoint.
public enum PullRequestDateParser {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return withFractionalSeconds.date(from: value) ?? plain.date(from: value)
    }
}

/// A provider that failed while building the queue.
public struct PullRequestQueueError: Sendable, Identifiable {
    public let source: PullRequestSource
    public let message: String

    public var id: String { "\(source.rawValue):\(message)" }

    public init(source: PullRequestSource, message: String) {
        self.source = source
        self.message = message
    }
}
