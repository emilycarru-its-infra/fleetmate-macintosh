import Foundation

// MARK: - Task Provider Protocol

/// Protocol for task providers (Azure DevOps, GitHub, Gitea).
/// Abstracts provider-specific APIs behind a unified interface.
public protocol TaskProvider: Actor {
    /// Provider identifier (e.g., "azdevops", "github", "gitea").
    var providerId: String { get }
    
    /// Human-readable provider name for display.
    var providerName: String { get }
    
    /// Whether the provider is currently configured and enabled.
    var isEnabled: Bool { get }
    
    /// Authenticates with the provider. Call before other operations.
    /// - Returns: True if authenticated successfully.
    func authenticate() async throws -> Bool
    
    /// Lists all tasks matching the optional filter.
    /// - Parameter filter: Optional filter criteria.
    /// - Returns: List of unified tasks.
    func listTasks(filter: TaskFilter?) async throws -> [UnifiedTask]
    
    /// Gets a single task by ID.
    /// - Parameter taskId: Provider-specific task ID.
    /// - Returns: The task, or nil if not found.
    func getTask(taskId: String) async throws -> UnifiedTask?
    
    /// Creates a new task.
    /// - Parameter request: Task creation request.
    /// - Returns: The created task.
    func createTask(request: CreateTaskRequest) async throws -> UnifiedTask
    
    /// Updates an existing task.
    /// - Parameters:
    ///   - taskId: Provider-specific task ID.
    ///   - request: Update request (nil fields are not updated).
    /// - Returns: The updated task.
    func updateTask(taskId: String, request: UpdateTaskRequest) async throws -> UnifiedTask
    
    /// Deletes a task.
    /// - Parameter taskId: Provider-specific task ID.
    /// - Returns: True if deleted successfully.
    func deleteTask(taskId: String) async throws -> Bool
    
    /// Lists available buckets/columns/milestones.
    /// - Returns: List of buckets.
    func listBuckets() async throws -> [TaskBucket]
    
    /// Lists available labels/tags.
    /// - Returns: List of labels.
    func listLabels() async throws -> [TaskLabel]
}

// MARK: - Task Filter

/// Filter criteria for listing tasks.
public struct TaskFilter: Sendable {
    /// Filter by state(s). Nil = all states.
    public var states: [TaskState]?
    
    /// Filter by assignee(s). Nil = all assignees.
    public var assignees: [String]?
    
    /// Filter by label(s). Nil = all labels.
    public var labels: [String]?
    
    /// Filter by bucket. Nil = all buckets.
    public var bucket: String?
    
    /// Search text in title/description. Nil = no text filter.
    public var searchText: String?
    
    /// Maximum number of tasks to return. Nil = provider default.
    public var limit: Int?
    
    /// Include closed tasks. Default is false (open tasks only).
    public var includeClosed: Bool
    
    public init(
        states: [TaskState]? = nil,
        assignees: [String]? = nil,
        labels: [String]? = nil,
        bucket: String? = nil,
        searchText: String? = nil,
        limit: Int? = nil,
        includeClosed: Bool = false
    ) {
        self.states = states
        self.assignees = assignees
        self.labels = labels
        self.bucket = bucket
        self.searchText = searchText
        self.limit = limit
        self.includeClosed = includeClosed
    }
}

// MARK: - Task Provider Error

/// Errors that can occur during task provider operations.
public enum TaskProviderError: Error, LocalizedError {
    case notAuthenticated
    case notConfigured
    case taskNotFound(String)
    case apiError(String)
    case networkError(Error)
    case parseError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized
    case forbidden
    
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with the task provider"
        case .notConfigured:
            return "Task provider is not configured"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .apiError(let message):
            return "API error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited"
        case .unauthorized:
            return "Unauthorized - check credentials"
        case .forbidden:
            return "Forbidden - insufficient permissions"
        }
    }
}
