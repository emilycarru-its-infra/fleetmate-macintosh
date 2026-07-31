import Foundation

// MARK: - Unified PR detail

/// Everything the in-app PR viewer shows for one pull request, provider-
/// agnostic: DevOps and GitHub both reduce to this shape.
public struct PullRequestDetail: Sendable {
    /// Markdown (GitHub) or HTML (Azure DevOps) — MarkdownTextView detects.
    public var body: String?
    public var commits: [PullRequestCommit]
    public var comments: [PullRequestComment]
    public var files: [DiffFile]
    /// True when the file list or a file's content was capped for size.
    public var truncated: Bool

    public init(body: String? = nil,
                commits: [PullRequestCommit] = [],
                comments: [PullRequestComment] = [],
                files: [DiffFile] = [],
                truncated: Bool = false) {
        self.body = body
        self.commits = commits
        self.comments = comments
        self.files = files
        self.truncated = truncated
    }
}

public struct PullRequestCommit: Sendable, Identifiable, Hashable {
    /// Full SHA.
    public let id: String
    public let message: String
    public let authorName: String?
    public let date: Date?

    public var shortSha: String { String(id.prefix(8)) }
    /// First line of the message.
    public var subject: String {
        message.split(separator: "\n").first.map(String.init) ?? message
    }

    public init(id: String, message: String, authorName: String?, date: Date?) {
        self.id = id
        self.message = message
        self.authorName = authorName
        self.date = date
    }
}

public struct PullRequestComment: Sendable, Identifiable, Hashable {
    public let id: String
    public let authorName: String
    /// Markdown (GitHub) or HTML (Azure DevOps).
    public let body: String
    public let date: Date?
    /// Vote/status noise like "X approved the pull request" — rendered
    /// smaller and gray rather than as a conversation entry.
    public let isSystem: Bool

    public init(id: String, authorName: String, body: String, date: Date?, isSystem: Bool) {
        self.id = id
        self.authorName = authorName
        self.body = body
        self.date = date
        self.isSystem = isSystem
    }
}
