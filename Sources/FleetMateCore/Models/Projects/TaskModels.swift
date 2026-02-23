import Foundation

// MARK: - Task State

/// Unified task state across all providers.
/// Maps to provider-specific states (e.g., Azure DevOps states, GitHub open/closed).
public enum TaskState: String, Codable, CaseIterable, Sendable {
    case open = "Open"
    case inProgress = "InProgress"
    case closed = "Closed"
    
    /// Display name for UI
    public var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .closed: return "Closed"
        }
    }
}

// MARK: - Unified Task

/// Represents a task from any provider (Azure DevOps, GitHub, Gitea) in a unified format.
public struct UnifiedTask: Identifiable, Codable, Sendable {
    /// Unique identifier within the provider.
    public let id: String
    
    /// Provider that owns this task (azdevops, github, gitea).
    public let provider: String
    
    /// Task title/summary.
    public var title: String
    
    /// Task description/body (markdown supported).
    public var description: String?
    
    /// Current state of the task.
    public var state: TaskState
    
    /// List of assignee usernames/emails.
    public var assignees: [String]
    
    /// Labels/tags applied to the task.
    public var labels: [String]
    
    /// Bucket/column/milestone the task belongs to.
    public var bucket: String?
    
    /// Due date for the task.
    public var dueDate: Date?
    
    /// When the task was created.
    public let createdAt: Date
    
    /// When the task was last updated.
    public var updatedAt: Date
    
    /// When the task was closed (nil if still open).
    public var closedAt: Date?
    
    /// URL to view the task in the provider's web UI.
    public var externalUrl: String?
    
    /// Priority level (1 = highest, 4 = lowest). Nil if not set.
    public var priority: Int?
    
    /// Provider-specific metadata (e.g., areaPath, iterationPath, workItemType for Azure DevOps).
    public var metadata: [String: String]
    
    /// Creates a composite key for this task across providers.
    public var compositeKey: String {
        "\(provider):\(id)"
    }
    
    public init(
        id: String,
        provider: String,
        title: String,
        description: String? = nil,
        state: TaskState = .open,
        assignees: [String] = [],
        labels: [String] = [],
        bucket: String? = nil,
        dueDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        closedAt: Date? = nil,
        externalUrl: String? = nil,
        priority: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.description = description
        self.state = state
        self.assignees = assignees
        self.labels = labels
        self.bucket = bucket
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.externalUrl = externalUrl
        self.priority = priority
        self.metadata = metadata
    }
}

// MARK: - Create Task Request

/// Request to create a new task.
public struct CreateTaskRequest: Codable, Sendable {
    /// Task title (required).
    public let title: String
    
    /// Task description/body.
    public var description: String?
    
    /// Initial state (defaults to Open).
    public var state: TaskState
    
    /// Assignee usernames/emails.
    public var assignees: [String]?
    
    /// Labels to apply.
    public var labels: [String]?
    
    /// Bucket/column/milestone to place the task in.
    public var bucket: String?
    
    /// Due date.
    public var dueDate: Date?
    
    /// Priority (1-4).
    public var priority: Int?
    
    public init(
        title: String,
        description: String? = nil,
        state: TaskState = .open,
        assignees: [String]? = nil,
        labels: [String]? = nil,
        bucket: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.state = state
        self.assignees = assignees
        self.labels = labels
        self.bucket = bucket
        self.dueDate = dueDate
        self.priority = priority
    }
}

// MARK: - Update Task Request

/// Request to update an existing task. Nil fields are not updated.
public struct UpdateTaskRequest: Codable, Sendable {
    /// New title (nil = keep existing).
    public var title: String?
    
    /// New description (nil = keep existing).
    public var description: String?
    
    /// New state (nil = keep existing).
    public var state: TaskState?
    
    /// New assignees (nil = keep existing, empty = clear).
    public var assignees: [String]?
    
    /// New labels (nil = keep existing, empty = clear).
    public var labels: [String]?
    
    /// New bucket (nil = keep existing).
    public var bucket: String?
    
    /// New due date (nil = keep existing).
    public var dueDate: Date?
    
    /// New priority (nil = keep existing).
    public var priority: Int?
    
    public init(
        title: String? = nil,
        description: String? = nil,
        state: TaskState? = nil,
        assignees: [String]? = nil,
        labels: [String]? = nil,
        bucket: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.state = state
        self.assignees = assignees
        self.labels = labels
        self.bucket = bucket
        self.dueDate = dueDate
        self.priority = priority
    }
}

// MARK: - Task Bucket

/// Represents a bucket/column/milestone for organizing tasks.
public struct TaskBucket: Identifiable, Codable, Sendable {
    /// Unique identifier within the provider.
    public let id: String
    
    /// Display name.
    public var name: String
    
    /// Order for display (lower = first).
    public var order: Int
    
    public init(id: String, name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }
}

// MARK: - Task Label

/// Represents a label/tag that can be applied to tasks.
public struct TaskLabel: Identifiable, Codable, Sendable {
    /// Label name/identifier.
    public var id: String { name }
    public let name: String
    
    /// Color in hex format (e.g., "#FF0000").
    public var color: String?
    
    /// Label description.
    public var labelDescription: String?
    
    public init(name: String, color: String? = nil, description: String? = nil) {
        self.name = name
        self.color = color
        self.labelDescription = description
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case color
        case labelDescription = "description"
    }
}


