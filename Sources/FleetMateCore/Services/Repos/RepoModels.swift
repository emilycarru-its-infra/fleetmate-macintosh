import Foundation

// MARK: - Identity

/// Where a repository is hosted.
public enum RepoProvider: String, Codable, Sendable, CaseIterable {
    case azureDevOps = "azdo"
    case gitHub = "github"
    /// Any other git host. Such a checkout can be linked and operated on, but
    /// never appears in the catalog.
    case other

    /// Folder name used by the default clone layout.
    public var layoutFolder: String {
        switch self {
        case .azureDevOps: "AzDevOps"
        case .gitHub: "GitHub"
        case .other: "Other"
        }
    }
}

/// The provider-neutral identity of a repository, derived from its remote URL
/// or from the provider's API. Two URLs naming the same repository — https or
/// ssh, any case, with or without `.git` — produce the same key.
///
/// - Azure DevOps: `owner` is the organization, `project` the project.
/// - GitHub: `owner` is the user or organization; `project` is nil.
/// - Other: `owner` is the host; `name` the remaining path.
public struct RepoKey: Hashable, Codable, Sendable, Comparable {
    public let provider: RepoProvider
    public let owner: String
    public let project: String?
    public let name: String

    public init(provider: RepoProvider, owner: String, project: String? = nil, name: String) {
        self.provider = provider
        self.owner = owner
        self.project = project
        self.name = name
    }

    /// Stable registry id, lowercased: `azdo:org/project/repo`,
    /// `github:owner/repo`, `other:host/path`.
    public var id: String {
        let parts = [owner, project, name].compactMap { $0 }
        return "\(provider.rawValue):" + parts.joined(separator: "/").lowercased()
    }

    /// What people type and read: `Project/Repo` or `owner/repo`.
    public var displayName: String {
        switch provider {
        case .azureDevOps: "\(project ?? owner)/\(name)"
        case .gitHub, .other: "\(owner)/\(name)"
        }
    }

    /// The scope a short name is qualified with: the project for Azure DevOps,
    /// the owner otherwise.
    public var scope: String { project ?? owner }

    public static func < (lhs: RepoKey, rhs: RepoKey) -> Bool { lhs.id < rhs.id }
}

// MARK: - Catalog

/// One repository the signed-in user can see on a provider.
public struct CatalogRepo: Codable, Sendable, Hashable, Identifiable {
    public let key: RepoKey
    public let cloneUrl: String
    public let sshUrl: String?
    public let webUrl: String?
    /// Short branch name (`main`), without `refs/heads/`.
    public let defaultBranch: String?
    public let isArchived: Bool
    public let isFork: Bool
    public let isPrivate: Bool?

    public var id: String { key.id }

    public init(
        key: RepoKey,
        cloneUrl: String,
        sshUrl: String? = nil,
        webUrl: String? = nil,
        defaultBranch: String? = nil,
        isArchived: Bool = false,
        isFork: Bool = false,
        isPrivate: Bool? = nil
    ) {
        self.key = key
        self.cloneUrl = cloneUrl
        self.sshUrl = sshUrl
        self.webUrl = webUrl
        self.defaultBranch = defaultBranch.map(RepoKey.shortBranch)
        self.isArchived = isArchived
        self.isFork = isFork
        self.isPrivate = isPrivate
    }
}

extension RepoKey {
    /// `refs/heads/main` → `main`.
    public static func shortBranch(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }
}

/// A catalog fetch: what each provider returned, and why any provider failed.
/// A failure in one provider never hides the other's results.
public struct RepoCatalog: Codable, Sendable {
    public var repos: [CatalogRepo]
    public var errors: [String]
    public var fetchedAt: Date

    public init(repos: [CatalogRepo] = [], errors: [String] = [], fetchedAt: Date = Date()) {
        self.repos = repos
        self.errors = errors
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Status

/// One changed path, from `git status --porcelain=v2`.
public struct RepoFileChange: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case changed, renamed, unmerged, untracked, ignored
    }

    public let path: String
    /// The source path of a rename or copy.
    public let originalPath: String?
    public let kind: Kind
    /// Index (staged) status letter: `M`, `A`, `D`, `R`, `C`, `T`, `U`, or `.` for none.
    public let indexStatus: Character
    /// Worktree (unstaged) status letter, same alphabet.
    public let worktreeStatus: Character

    public var id: String { path }
    public var isStaged: Bool { kind != .untracked && kind != .ignored && indexStatus != "." }
    public var isUnstaged: Bool { kind != .untracked && kind != .ignored && worktreeStatus != "." }

    public init(path: String, originalPath: String? = nil, kind: Kind, indexStatus: Character, worktreeStatus: Character) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }

    enum CodingKeys: String, CodingKey { case path, originalPath, kind, indexStatus, worktreeStatus, staged, unstaged }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(originalPath, forKey: .originalPath)
        try c.encode(kind, forKey: .kind)
        try c.encode(String(indexStatus), forKey: .indexStatus)
        try c.encode(String(worktreeStatus), forKey: .worktreeStatus)
        try c.encode(isStaged, forKey: .staged)
        try c.encode(isUnstaged, forKey: .unstaged)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        originalPath = try c.decodeIfPresent(String.self, forKey: .originalPath)
        kind = try c.decode(Kind.self, forKey: .kind)
        indexStatus = try c.decode(String.self, forKey: .indexStatus).first ?? "."
        worktreeStatus = try c.decode(String.self, forKey: .worktreeStatus).first ?? "."
    }
}

/// One entry of `git worktree list --porcelain`.
public struct RepoWorktree: Codable, Sendable, Hashable {
    public let path: String
    public let head: String?
    /// Short branch name, nil when detached or bare.
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(path: String, head: String?, branch: String?, isDetached: Bool, isBare: Bool, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Branch header and changes from `git status --porcelain=v2 --branch`.
public struct GitStatusSnapshot: Codable, Sendable, Hashable {
    public var headOid: String?
    /// Nil when HEAD is detached.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [RepoFileChange]

    public var stagedCount: Int { changes.filter(\.isStaged).count }
    public var unstagedCount: Int { changes.filter(\.isUnstaged).count }
    public var untrackedCount: Int { changes.filter { $0.kind == .untracked }.count }
    public var conflictedCount: Int { changes.filter { $0.kind == .unmerged }.count }
    public var isClean: Bool { changes.allSatisfy { $0.kind == .ignored } }

    public init(headOid: String? = nil, branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changes: [RepoFileChange] = []) {
        self.headOid = headOid
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }
}

/// Everything `fleetmate repos status` reports for one repository.
public struct RepoStatus: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let staged: Int
    public let unstaged: Int
    public let untracked: Int
    public let conflicted: Int
    public let isClean: Bool
    public let changes: [RepoFileChange]
    public let worktrees: [RepoWorktree]
    /// The repository's agent instructions (`AGENTS.md`), when it has one.
    /// Agents read it before working in the repository.
    public let agentsFile: String?
    /// When HEAD was last committed; nil for an empty repository.
    public let lastCommitAt: Date?
    public let error: String?

    public init(id: String, displayName: String, path: String, snapshot: GitStatusSnapshot?, worktrees: [RepoWorktree], agentsFile: String?, lastCommitAt: Date? = nil, error: String?) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.branch = snapshot?.branch
        self.upstream = snapshot?.upstream
        self.ahead = snapshot?.ahead ?? 0
        self.behind = snapshot?.behind ?? 0
        self.staged = snapshot?.stagedCount ?? 0
        self.unstaged = snapshot?.unstagedCount ?? 0
        self.untracked = snapshot?.untrackedCount ?? 0
        self.conflicted = snapshot?.conflictedCount ?? 0
        self.isClean = snapshot?.isClean ?? false
        self.changes = snapshot?.changes ?? []
        self.worktrees = worktrees
        self.agentsFile = agentsFile
        self.lastCommitAt = lastCommitAt
        self.error = error
    }

    /// Staged, unstaged and untracked paths together.
    public var changedCount: Int { staged + unstaged + untracked }
}

// MARK: - History, search, results

public struct RepoCommit: Codable, Sendable, Hashable {
    public let sha: String
    public let shortSha: String
    public let author: String
    public let email: String
    public let date: Date?
    public let subject: String
}

public struct RepoGrepMatch: Codable, Sendable, Hashable {
    public let path: String
    public let line: Int
    public let column: Int
    public let text: String
}

/// The outcome of one git operation on one repository, for batch commands.
public struct RepoOperationResult: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let operation: String
    public let succeeded: Bool
    public let output: String
    public let error: String?

    public init(id: String, displayName: String, operation: String, succeeded: Bool, output: String, error: String?) {
        self.id = id
        self.displayName = displayName
        self.operation = operation
        self.succeeded = succeeded
        self.output = output
        self.error = error
    }
}

// MARK: - Errors

public enum RepoError: LocalizedError, Equatable {
    case notFound(String)
    case ambiguous(String, candidates: [String])
    case notLocal(String)
    case notAGitRepository(String)
    case protectedBranch(String)
    case pathOutsideRepository(String)
    case destinationExists(String)
    case gitFailed(command: String, message: String)
    case nothingToCommit
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let arg):
            "No repository matches '\(arg)'. Run 'fleetmate repos catalog' to refresh the list."
        case .ambiguous(let arg, let candidates):
            "'\(arg)' matches several repositories; qualify it as project/name or owner/name:\n  " + candidates.joined(separator: "\n  ")
        case .notLocal(let name):
            "\(name) has no local checkout. Clone it with 'fleetmate repos clone' or link one with 'fleetmate repos link'."
        case .notAGitRepository(let path):
            "\(path) is not a git checkout."
        case .protectedBranch(let branch):
            "Refusing to commit or push on '\(branch)'. Work on a branch and open a pull request, or pass --allow-main."
        case .pathOutsideRepository(let path):
            "\(path) is outside the repository."
        case .destinationExists(let path):
            "\(path) already exists."
        case .gitFailed(let command, let message):
            "git \(command) failed: \(message)"
        case .nothingToCommit:
            "Nothing to commit."
        case .invalidArgument(let message):
            message
        }
    }
}
