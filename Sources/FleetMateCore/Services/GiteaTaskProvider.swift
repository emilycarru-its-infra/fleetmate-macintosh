import Foundation
import Alamofire

/// Gitea task provider using Gitea Issues API.
/// Maps Gitea Issues to UnifiedTask format.
public actor GiteaTaskProvider: TaskProvider {
    private let config: GiteaProviderConfig
    private let session: Session
    private var token: String?
    private var authenticated: Bool = false
    
    public nonisolated let providerId: String = "gitea"
    public nonisolated let providerName: String = "Gitea"
    
    public var isEnabled: Bool {
        config.enabled &&
        config.url != nil && !config.url!.isEmpty &&
        config.owner != nil && !config.owner!.isEmpty &&
        config.repo != nil && !config.repo!.isEmpty
    }
    
    private var baseUrl: String {
        (config.url ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    public init(config: FleetMateConfig) {
        self.config = config.tasks?.providers.gitea ?? GiteaProviderConfig()
        self.token = self.config.token
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = Session(configuration: configuration)
    }
    
    public func authenticate() async throws -> Bool {
        // Try environment variable if no token configured
        if token == nil || token!.isEmpty {
            token = ProcessInfo.processInfo.environment["GITEA_TOKEN"]
        }
        
        guard let token = token, !token.isEmpty else {
            print("Gitea: No token configured")
            return false
        }
        
        // Verify token by getting authenticated user
        do {
            let _: GiteaUser = try await fetch(url: "\(baseUrl)/api/v1/user", headers: headers())
            authenticated = true
            print("Authenticated with Gitea: \(baseUrl)")
            return true
        } catch {
            print("Gitea authentication failed: \(error)")
            authenticated = false
            return false
        }
    }
    
    private func headers() -> HTTPHeaders {
        [
            "Authorization": "token \(token ?? "")",
            "Accept": "application/json"
        ]
    }
    
    public func listTasks(filter: TaskFilter?) async throws -> [UnifiedTask] {
        var queryParams: [String] = []
        
        // State filter
        if let states = filter?.states, !states.isEmpty {
            if states.allSatisfy({ $0 == .closed }) {
                queryParams.append("state=closed")
            } else {
                queryParams.append("state=open")
            }
        } else if filter?.includeClosed == true {
            queryParams.append("state=all")
        } else {
            queryParams.append("state=open")
        }
        
        // Labels filter
        if let labels = filter?.labels, !labels.isEmpty {
            for label in labels {
                queryParams.append("labels=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? label)")
            }
        }
        
        // Milestone (bucket) filter
        if let bucket = filter?.bucket {
            queryParams.append("milestones=\(bucket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bucket)")
        }
        
        // Limit
        let limit = filter?.limit ?? 50
        queryParams.append("limit=\(limit)")
        
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues?\(queryParams.joined(separator: "&"))"
        
        var issues: [GiteaIssue] = try await fetch(url: url, headers: headers())
        
        // Filter out pull requests
        issues = issues.filter { $0.pullRequest == nil }
        
        // Apply search text filter client-side if needed
        if let searchText = filter?.searchText?.lowercased() {
            issues = issues.filter { issue in
                issue.title.lowercased().contains(searchText) ||
                (issue.body?.lowercased().contains(searchText) ?? false)
            }
        }
        
        // Assignee filter (client-side for Gitea)
        if let assignees = filter?.assignees, !assignees.isEmpty {
            issues = issues.filter { issue in
                issue.assignees?.contains(where: { assignees.contains($0.login) }) ?? false
            }
        }
        
        return issues.map { mapToUnifiedTask($0) }
    }
    
    public func getTask(taskId: String) async throws -> UnifiedTask? {
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues/\(taskId)"
        
        do {
            let issue: GiteaIssue = try await fetch(url: url, headers: headers())
            return mapToUnifiedTask(issue)
        } catch {
            return nil
        }
    }
    
    public func createTask(request: CreateTaskRequest) async throws -> UnifiedTask {
        var labels = request.labels ?? []
        labels.append(contentsOf: config.defaultLabels)
        labels = Array(Set(labels))
        
        // Get label IDs (Gitea requires IDs, not names)
        let labelIds = await getLabelIdsByNames(labels)
        
        var body: [String: Any] = [
            "title": request.title
        ]
        
        if let description = request.description {
            body["body"] = description
        }
        if !labelIds.isEmpty {
            body["labels"] = labelIds
        }
        if let assignees = request.assignees {
            body["assignees"] = assignees
        }
        if let bucket = request.bucket, let milestoneId = Int(bucket) {
            body["milestone"] = milestoneId
        }
        
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues"
        let issue: GiteaIssue = try await post(url: url, body: body, headers: headers())
        
        print("Gitea: Created issue #\(issue.number): \(request.title)")
        return mapToUnifiedTask(issue)
    }
    
    public func updateTask(taskId: String, request: UpdateTaskRequest) async throws -> UnifiedTask {
        var body: [String: Any] = [:]
        
        if let title = request.title {
            body["title"] = title
        }
        if let description = request.description {
            body["body"] = description
        }
        if let state = request.state {
            body["state"] = state == .closed ? "closed" : "open"
        }
        if let labels = request.labels {
            let labelIds = await getLabelIdsByNames(labels)
            body["labels"] = labelIds
        }
        if let assignees = request.assignees {
            body["assignees"] = assignees
        }
        if let bucket = request.bucket, let milestoneId = Int(bucket) {
            body["milestone"] = milestoneId
        }
        
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues/\(taskId)"
        let issue: GiteaIssue = try await patch(url: url, body: body, headers: headers())
        
        return mapToUnifiedTask(issue)
    }
    
    public func deleteTask(taskId: String) async throws -> Bool {
        // Gitea supports deleting issues (unlike GitHub)
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues/\(taskId)"
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .delete, headers: headers())
                .response { response in
                    if let error = response.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: response.response?.statusCode == 204)
                    }
                }
        }
    }
    
    public func listBuckets() async throws -> [TaskBucket] {
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/milestones?state=open"
        
        let milestones: [GiteaMilestone] = try await fetch(url: url, headers: headers())
        
        return milestones.enumerated().map { index, milestone in
            TaskBucket(
                id: String(milestone.id),
                name: milestone.title,
                order: index
            )
        }
    }
    
    public func listLabels() async throws -> [TaskLabel] {
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/labels"
        
        let labels: [GiteaLabel] = try await fetch(url: url, headers: headers())
        
        return labels.map { label in
            let color = label.color?.hasPrefix("#") == true ? label.color : label.color.map { "#\($0)" }
            return TaskLabel(
                name: label.name,
                color: color,
                description: label.labelDescription
            )
        }
    }
    
    private func getLabelIdsByNames(_ names: [String]) async -> [Int] {
        let url = "\(baseUrl)/api/v1/repos/\(config.owner ?? "")/\(config.repo ?? "")/labels"
        
        do {
            let labels: [GiteaLabel] = try await fetch(url: url, headers: headers())
            let labelMap = Dictionary(uniqueKeysWithValues: labels.map { ($0.name.lowercased(), $0.id) })
            
            return names.compactMap { labelMap[$0.lowercased()] }
        } catch {
            return []
        }
    }
    
    private func mapToUnifiedTask(_ issue: GiteaIssue) -> UnifiedTask {
        UnifiedTask(
            id: String(issue.number),
            provider: providerId,
            title: issue.title,
            description: issue.body,
            state: issue.state == "closed" ? .closed : .open,
            assignees: issue.assignees?.map { $0.login } ?? [],
            labels: issue.labels?.map { $0.name } ?? [],
            bucket: issue.milestone?.title,
            dueDate: issue.milestone?.dueOn,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt,
            closedAt: issue.closedAt,
            externalUrl: issue.htmlUrl,
            priority: nil
        )
    }
    
    // MARK: - HTTP Helpers
    
    private func fetch<T: Decodable>(url: String, headers: HTTPHeaders) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: T.self, decoder: giteaDecoder) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    private func post<T: Decodable>(url: String, body: [String: Any], headers: HTTPHeaders) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseDecodable(of: T.self, decoder: giteaDecoder) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    private func patch<T: Decodable>(url: String, body: [String: Any], headers: HTTPHeaders) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .patch, parameters: body, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseDecodable(of: T.self, decoder: giteaDecoder) { response in
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

// MARK: - Gitea API Models

private struct GiteaIssue: Decodable {
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let state: String
    let assignees: [GiteaUser]?
    let labels: [GiteaLabel]?
    let milestone: GiteaMilestone?
    let pullRequest: GiteaPullRequest?
    let htmlUrl: String?
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, assignees, labels, milestone
        case pullRequest = "pull_request"
        case htmlUrl = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
    }
}

private struct GiteaUser: Decodable {
    let id: Int
    let login: String
}

private struct GiteaLabel: Decodable {
    let id: Int
    let name: String
    let color: String?
    let labelDescription: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, color
        case labelDescription = "description"
    }
}

private struct GiteaMilestone: Decodable {
    let id: Int
    let title: String
    let dueOn: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, title
        case dueOn = "due_on"
    }
}

private struct GiteaPullRequest: Decodable {
    let url: String?
}

// Custom decoder for Gitea dates
private let giteaDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)
        
        // Try with fractional seconds first
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
    }
    
    return decoder
}()
