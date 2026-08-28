import Foundation
import Alamofire

/// Service to sync tasks one-way to Microsoft Planner.
/// Uses MS Graph API to push UnifiedTask items as Planner tasks.
public actor PlannerSyncService {
    private let config: PlannerSyncConfig
    private let session: Session
    private var accessToken: String?
    
    private let baseUrl = "https://graph.microsoft.com/v1.0/"
    
    public var isEnabled: Bool {
        config.enabled && config.planId != nil && !config.planId!.isEmpty
    }
    
    public init(config: FleetMateConfig) {
        self.config = config.tasks?.planner ?? PlannerSyncConfig()
        self.session = Session(configuration: .default)
    }
    
    /// Authenticate using Azure CLI SSO token for MS Graph.
    public func authenticate() async throws -> Bool {
        let result = await ProcessRunner.run(
            "az",
            ["account", "get-access-token", "--resource",
             "https://graph.microsoft.com", "--query", "accessToken", "-o", "tsv"]
        )
        guard result.succeeded else {
            print("Planner: Could not get Graph token from Azure CLI. \(result.stderr)")
            return false
        }

        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            print("Planner: Empty token from Azure CLI")
            return false
        }

        accessToken = token
        print("Planner: Authenticated via Azure CLI")
        return true
    }
    
    private func headers() -> HTTPHeaders {
        [
            "Authorization": "Bearer \(accessToken ?? "")",
            "Content-Type": "application/json"
        ]
    }
    
    /// Get all tasks in the configured Planner plan.
    public func getPlannerTasks() async throws -> [PlannerTask] {
        guard let planId = config.planId else { return [] }
        
        var allTasks: [PlannerTask] = []
        var url: String? = "\(baseUrl)planner/plans/\(planId)/tasks"
        
        while let currentUrl = url {
            let response: ODataResponse<PlannerTask> = try await fetch(url: currentUrl)
            allTasks.append(contentsOf: response.value ?? [])
            url = response.nextLink
        }
        
        return allTasks
    }
    
    /// Create a new task in the Planner plan.
    public func createTask(_ task: UnifiedTask) async throws -> PlannerTask? {
        guard let planId = config.planId else { return nil }
        
        let bucketId = try await getOrCreateBucket(name: task.bucket ?? "Tasks")
        
        var body: [String: Any] = [
            "planId": planId,
            "title": task.title,
            "percentComplete": task.state == .closed ? 100 : (task.state == .inProgress ? 50 : 0),
            "priority": mapPriority(task.priority)
        ]
        
        if let bucketId = bucketId {
            body["bucketId"] = bucketId
        }
        if let dueDate = task.dueDate {
            body["dueDateTime"] = ISO8601DateFormatter().string(from: dueDate)
        }
        if !task.assignees.isEmpty {
            body["assignments"] = Dictionary(uniqueKeysWithValues: task.assignees.map { ($0, [:]) })
        }
        if !task.labels.isEmpty {
            body["appliedCategories"] = mapLabelsToCategories(task.labels)
        }
        
        let created: PlannerTask = try await post(url: "\(baseUrl)planner/tasks", body: body)
        
        // Add description in task details
        if let description = task.description, !description.isEmpty {
            await updateTaskDetails(taskId: created.id, description: description, task: task)
        }
        
        print("Planner: Created task '\(task.title)'")
        return created
    }
    
    /// Update an existing Planner task.
    public func updateTask(plannerTaskId: String, task: UnifiedTask, etag: String) async throws -> Bool {
        var body: [String: Any] = [
            "title": task.title,
            "percentComplete": task.state == .closed ? 100 : (task.state == .inProgress ? 50 : 0)
        ]
        
        if let dueDate = task.dueDate {
            body["dueDateTime"] = ISO8601DateFormatter().string(from: dueDate)
        }
        if let priority = task.priority {
            body["priority"] = mapPriority(priority)
        }
        if !task.labels.isEmpty {
            body["appliedCategories"] = mapLabelsToCategories(task.labels)
        }
        
        var headers = self.headers()
        headers.add(name: "If-Match", value: etag)
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request("\(baseUrl)planner/tasks/\(plannerTaskId)", 
                          method: .patch, 
                          parameters: body, 
                          encoding: JSONEncoding.default,
                          headers: headers)
                .response { response in
                    if let error = response.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: response.response?.statusCode == 204 || 
                                                      response.response?.statusCode == 200)
                    }
                }
        }
    }
    
    /// Sync all tasks from unified providers to Planner.
    public func syncTasks(_ tasks: [UnifiedTask]) async throws -> SyncResult {
        guard isEnabled else {
            return SyncResult(success: false, message: "Planner sync not enabled")
        }
        
        var result = SyncResult()
        let existingTasks = try await getPlannerTasks()
        let existingByTitle = Dictionary(uniqueKeysWithValues: existingTasks.map { ($0.title, $0) })
        
        for task in tasks {
            do {
                if let existing = existingByTitle[task.title] {
                    // Task exists - update if needed
                    if try await updateTask(plannerTaskId: existing.id, task: task, etag: existing.etag ?? "") {
                        result.updated += 1
                    }
                } else {
                    // Create new task
                    if try await createTask(task) != nil {
                        result.created += 1
                    }
                }
            } catch {
                print("Planner: Error syncing task '\(task.title)': \(error)")
                result.errors += 1
            }
        }
        
        result.success = result.errors == 0
        result.message = "Synced to Planner: \(result.created) created, \(result.updated) updated, \(result.errors) errors"
        print(result.message)
        
        return result
    }
    
    private func updateTaskDetails(taskId: String, description: String, task: UnifiedTask) async {
        do {
            // Get details to get etag - simplified, just try to update
            let reference = "Source: [\(task.provider)#\(task.id)](\(task.externalUrl ?? ""))"
            let fullDescription = "\(description)\n\n---\n\(reference)"
            
            let body: [String: Any] = ["description": fullDescription]
            
            var headers = self.headers()
            headers.add(name: "If-Match", value: "*") // Use wildcard for simplicity
            
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                session.request("\(baseUrl)planner/tasks/\(taskId)/details",
                              method: .patch,
                              parameters: body,
                              encoding: JSONEncoding.default,
                              headers: headers)
                    .response { response in
                        continuation.resume(returning: ())
                    }
            }
        } catch {
            print("Planner: Could not update task details - \(error)")
        }
    }
    
    private func getOrCreateBucket(name: String) async throws -> String? {
        guard let planId = config.planId else { return nil }
        
        // Get existing buckets
        let response: ODataResponse<PlannerBucket> = try await fetch(url: "\(baseUrl)planner/plans/\(planId)/buckets")
        
        if let existing = response.value?.first(where: { $0.name == name }) {
            return existing.id
        }
        
        // Create new bucket
        let body: [String: Any] = ["planId": planId, "name": name]
        let created: PlannerBucket = try await post(url: "\(baseUrl)planner/buckets", body: body)
        return created.id
    }
    
    private func mapPriority(_ priority: Int?) -> Int {
        switch priority {
        case 1: return 1      // Urgent
        case 2: return 3      // High
        case 3: return 5      // Medium
        case 4: return 7      // Low
        case 5: return 9      // Lowest
        default: return 5     // Default to Medium
        }
    }
    
    private func mapLabelsToCategories(_ labels: [String]) -> [String: Bool] {
        var categories: [String: Bool] = [:]
        for (index, _) in labels.prefix(6).enumerated() {
            categories["category\(index + 1)"] = true
        }
        return categories
    }
    
    // MARK: - HTTP Helpers
    
    private func fetch<T: Decodable>(url: String) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers())
                .validate()
                .responseDecodable(of: T.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    private func post<T: Decodable>(url: String, body: [String: Any]) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers())
                .validate()
                .responseDecodable(of: T.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
}

// MARK: - Planner API Models

public struct PlannerTask: Codable, Sendable {
    public let id: String
    public let title: String
    public let planId: String?
    public let bucketId: String?
    public let percentComplete: Int
    public let priority: Int
    public let dueDateTime: Date?
    public let etag: String?
    
    enum CodingKeys: String, CodingKey {
        case id, title, planId, bucketId, percentComplete, priority, dueDateTime
        case etag = "@odata.etag"
    }
}

public struct PlannerBucket: Codable, Sendable {
    public let id: String
    public let name: String
}

public struct ODataResponse<T: Codable>: Codable {
    public let value: [T]?
    public let nextLink: String?
    
    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

public struct SyncResult: Sendable {
    public var success: Bool = false
    public var message: String = ""
    public var created: Int = 0
    public var updated: Int = 0
    public var deleted: Int = 0
    public var errors: Int = 0
    
    public init(success: Bool = false, message: String = "") {
        self.success = success
        self.message = message
    }
}
