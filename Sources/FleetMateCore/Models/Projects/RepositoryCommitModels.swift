import Foundation

// MARK: - Recent commits per repository (Development › Commits)

/// A repository with its most recent commits on the default branch, from
/// either provider, flattened into one shape for the Commits list.
public struct RepositoryCommits: Identifiable, Sendable, Hashable {
    public let source: PullRequestSource
    /// AzDO: project name. GitHub: owner login.
    public let container: String
    public let repository: String
    /// Repository id the provider wants back on detail calls (AzDO GUID;
    /// GitHub has none and uses owner/name).
    public let repositoryId: String?
    public let webUrl: String
    public let defaultBranch: String?
    /// Newest first.
    public let commits: [PullRequestCommit]

    public var id: String { "\(source.rawValue):\(container)/\(repository)" }
    public var displayName: String { "\(container)/\(repository)" }
    public var latestDate: Date { commits.first?.date ?? .distantPast }

    public init(
        source: PullRequestSource,
        container: String,
        repository: String,
        repositoryId: String? = nil,
        webUrl: String,
        defaultBranch: String?,
        commits: [PullRequestCommit]
    ) {
        self.source = source
        self.container = container
        self.repository = repository
        self.repositoryId = repositoryId
        self.webUrl = webUrl
        self.defaultBranch = defaultBranch
        self.commits = commits
    }

    public static func == (lhs: RepositoryCommits, rhs: RepositoryCommits) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One commit opened in the viewer: full message, and either per-file
/// diffs (GitHub) or a bare change list (Azure DevOps, whose commit API
/// returns paths and change types but no patch).
public struct CommitDetail: Sendable {
    public var message: String
    public var files: [DiffFile]
    public var changes: [CommitChange]
    public var additions: Int
    public var deletions: Int
    public var truncated: Bool

    public init(message: String, files: [DiffFile] = [], changes: [CommitChange] = [],
                additions: Int = 0, deletions: Int = 0, truncated: Bool = false) {
        self.message = message
        self.files = files
        self.changes = changes
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
    }
}

public struct CommitChange: Identifiable, Sendable, Hashable {
    public let path: String
    /// add, edit, delete, rename — the provider's own word, lowercased.
    public let changeType: String

    public var id: String { "\(changeType):\(path)" }

    public init(path: String, changeType: String) {
        self.path = path
        self.changeType = changeType
    }
}
