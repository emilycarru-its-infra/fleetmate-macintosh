import Foundation

// MARK: - Project Scope

/// Scope from which to query GitHub Projects v2.
public enum ProjectScope: String, Codable, Sendable, CaseIterable {
    case organization
    case user
    case repository
}

// MARK: - GitHub Project

/// Represents a GitHub Projects v2 project.
public struct GitHubProject: Identifiable, Codable, Sendable {
    public let id: String
    public let number: Int
    public var title: String
    public var shortDescription: String?
    public var url: String?
    public var closed: Bool
    public var isPublic: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, number, title, shortDescription, url, closed
        case isPublic = "public"
        case createdAt, updatedAt, closedAt
    }

    public init(
        id: String, number: Int, title: String,
        shortDescription: String? = nil, url: String? = nil,
        closed: Bool = false, isPublic: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date(),
        closedAt: Date? = nil
    ) {
        self.id = id; self.number = number; self.title = title
        self.shortDescription = shortDescription; self.url = url
        self.closed = closed; self.isPublic = isPublic
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.closedAt = closedAt
    }
}

// MARK: - Project Item

/// Represents an item in a GitHub Projects v2 project.
/// Items can be Issues, Pull Requests, or Draft Issues.
public struct GitHubProjectItem: Identifiable, Codable, Sendable {
    public let id: String
    public let type: String // ISSUE, PULL_REQUEST, DRAFT_ISSUE, REDACTED
    public let createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool

    /// The content of this item (Issue or PR details). Nil for DRAFT_ISSUE.
    public var content: GitHubProjectItemContent?

    /// The draft title/body for DRAFT_ISSUE items.
    public var draftContent: GitHubProjectDraftContent?

    /// Field values applied to this item within the project.
    public var fieldValues: [GitHubProjectFieldValue]

    public init(
        id: String, type: String,
        createdAt: Date = Date(), updatedAt: Date = Date(),
        isArchived: Bool = false,
        content: GitHubProjectItemContent? = nil,
        draftContent: GitHubProjectDraftContent? = nil,
        fieldValues: [GitHubProjectFieldValue] = []
    ) {
        self.id = id; self.type = type
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.content = content; self.draftContent = draftContent
        self.fieldValues = fieldValues
    }
}

/// Content of a project item when it's an Issue or Pull Request.
public struct GitHubProjectItemContent: Codable, Sendable {
    public let id: String
    public let number: Int
    public var title: String
    public var body: String?
    public var state: String? // OPEN, CLOSED, MERGED (PRs)
    public var url: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var assignees: [String]
    public var labels: [String]
    public var isPullRequest: Bool
    public var repository: String? // owner/repo

    public init(
        id: String, number: Int, title: String,
        body: String? = nil, state: String? = nil, url: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(),
        closedAt: Date? = nil, assignees: [String] = [],
        labels: [String] = [], isPullRequest: Bool = false,
        repository: String? = nil
    ) {
        self.id = id; self.number = number; self.title = title
        self.body = body; self.state = state; self.url = url
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.closedAt = closedAt; self.assignees = assignees
        self.labels = labels; self.isPullRequest = isPullRequest
        self.repository = repository
    }
}

/// Draft content for a DRAFT_ISSUE project item.
public struct GitHubProjectDraftContent: Codable, Sendable {
    public var title: String
    public var body: String?

    public init(title: String, body: String? = nil) {
        self.title = title; self.body = body
    }
}

// MARK: - Project Fields

/// Represents a field definition in a GitHub Projects v2 project.
public struct GitHubProjectField: Identifiable, Codable, Sendable {
    public let id: String
    public var name: String
    public var dataType: String // TEXT, NUMBER, DATE, SINGLE_SELECT, ITERATION

    /// Options available for SINGLE_SELECT fields (e.g., Status column options).
    public var options: [GitHubProjectSelectOption]

    /// Iterations for ITERATION fields.
    public var iterations: [GitHubProjectIteration]

    public init(
        id: String, name: String, dataType: String,
        options: [GitHubProjectSelectOption] = [],
        iterations: [GitHubProjectIteration] = []
    ) {
        self.id = id; self.name = name; self.dataType = dataType
        self.options = options; self.iterations = iterations
    }
}

/// An option in a single-select field.
public struct GitHubProjectSelectOption: Identifiable, Codable, Sendable {
    public let id: String
    public var name: String
    public var color: String?
    public var optionDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case optionDescription = "description"
    }

    public init(id: String, name: String, color: String? = nil, description: String? = nil) {
        self.id = id; self.name = name; self.color = color
        self.optionDescription = description
    }
}

/// An iteration in an iteration field.
public struct GitHubProjectIteration: Identifiable, Codable, Sendable {
    public let id: String
    public var title: String
    public var startDate: String?
    public var duration: Int?

    public init(id: String, title: String, startDate: String? = nil, duration: Int? = nil) {
        self.id = id; self.title = title
        self.startDate = startDate; self.duration = duration
    }
}

// MARK: - Field Values

/// A field value set on a project item.
public struct GitHubProjectFieldValue: Codable, Sendable {
    public var fieldId: String
    public var fieldName: String
    public var dataType: String

    public var textValue: String?
    public var numberValue: Double?
    public var dateValue: Date?
    public var singleSelectValue: String?
    public var singleSelectOptionId: String?
    public var iterationValue: String?
    public var iterationId: String?

    public init(
        fieldId: String, fieldName: String, dataType: String,
        textValue: String? = nil, numberValue: Double? = nil,
        dateValue: Date? = nil, singleSelectValue: String? = nil,
        singleSelectOptionId: String? = nil,
        iterationValue: String? = nil, iterationId: String? = nil
    ) {
        self.fieldId = fieldId; self.fieldName = fieldName; self.dataType = dataType
        self.textValue = textValue; self.numberValue = numberValue
        self.dateValue = dateValue; self.singleSelectValue = singleSelectValue
        self.singleSelectOptionId = singleSelectOptionId
        self.iterationValue = iterationValue; self.iterationId = iterationId
    }
}

// MARK: - Project View

/// Represents a saved view in a GitHub Projects v2 project (Board, Table, etc.).
public struct GitHubProjectView: Identifiable, Codable, Sendable {
    public let id: String
    public let number: Int
    public var name: String
    public var layout: String // BOARD_LAYOUT, TABLE_LAYOUT, ROADMAP_LAYOUT

    public init(id: String, number: Int, name: String, layout: String) {
        self.id = id; self.number = number; self.name = name; self.layout = layout
    }
}

// MARK: - Issue Detail (REST v3)

/// Detailed issue data from the GitHub REST v3 API.
public struct GitHubIssueDetail: Codable, Sendable {
    public let id: Int
    public let nodeId: String
    public let number: Int
    public var title: String
    public var body: String?
    public var state: String          // "open" or "closed"
    public var locked: Bool
    public let htmlUrl: String
    public var milestone: GitHubMilestone?
    public var assignees: [GitHubUser]
    public var labels: [GitHubLabelDetail]
    public let createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var user: GitHubUser?      // issue author
    public var pullRequest: GitHubPullRequestRef?

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, locked, milestone, assignees, labels, user
        case nodeId = "node_id"
        case htmlUrl = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
    }

    public init(
        id: Int, nodeId: String, number: Int, title: String,
        body: String? = nil, state: String = "open", locked: Bool = false,
        htmlUrl: String = "", milestone: GitHubMilestone? = nil,
        assignees: [GitHubUser] = [], labels: [GitHubLabelDetail] = [],
        createdAt: Date = Date(), updatedAt: Date = Date(),
        closedAt: Date? = nil, user: GitHubUser? = nil,
        pullRequest: GitHubPullRequestRef? = nil
    ) {
        self.id = id; self.nodeId = nodeId; self.number = number
        self.title = title; self.body = body; self.state = state
        self.locked = locked; self.htmlUrl = htmlUrl
        self.milestone = milestone; self.assignees = assignees; self.labels = labels
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.closedAt = closedAt
        self.user = user; self.pullRequest = pullRequest
    }
}

// MARK: - GitHub User

public struct GitHubUser: Codable, Sendable {
    public let id: Int
    public let login: String
    public var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, login
        case avatarUrl = "avatar_url"
    }

    public init(id: Int, login: String, avatarUrl: String? = nil) {
        self.id = id; self.login = login; self.avatarUrl = avatarUrl
    }
}

// MARK: - GitHub Milestone

public struct GitHubMilestone: Identifiable, Codable, Sendable {
    public let id: Int
    public let nodeId: String
    public let number: Int
    public var title: String
    public var state: String
    public var dueOn: Date?

    enum CodingKeys: String, CodingKey {
        case id, number, title, state
        case nodeId = "node_id"
        case dueOn = "due_on"
    }

    public init(id: Int, nodeId: String, number: Int, title: String, state: String = "open", dueOn: Date? = nil) {
        self.id = id; self.nodeId = nodeId; self.number = number
        self.title = title; self.state = state; self.dueOn = dueOn
    }
}

// MARK: - GitHub Label Detail

public struct GitHubLabelDetail: Identifiable, Codable, Sendable {
    public let id: Int
    public let nodeId: String
    public var name: String
    public var color: String
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, description
        case nodeId = "node_id"
    }

    public init(id: Int, nodeId: String, name: String, color: String = "ccc", description: String? = nil) {
        self.id = id; self.nodeId = nodeId; self.name = name
        self.color = color; self.description = description
    }
}

// MARK: - Pull Request Ref (on an issue when linked)

public struct GitHubPullRequestRef: Codable, Sendable {
    public var url: String?
    public var htmlUrl: String?
    public var mergedAt: Date?

    enum CodingKeys: String, CodingKey {
        case url
        case htmlUrl = "html_url"
        case mergedAt = "merged_at"
    }

    public init(url: String? = nil, htmlUrl: String? = nil, mergedAt: Date? = nil) {
        self.url = url; self.htmlUrl = htmlUrl; self.mergedAt = mergedAt
    }
}

// MARK: - Issue Comment (REST v3)

public struct GitHubComment: Identifiable, Codable, Sendable {
    public let id: Int
    public let nodeId: String
    public var user: GitHubUser?
    public var body: String
    public let createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case nodeId = "node_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: Int, nodeId: String, user: GitHubUser? = nil, body: String,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.nodeId = nodeId; self.user = user; self.body = body
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
