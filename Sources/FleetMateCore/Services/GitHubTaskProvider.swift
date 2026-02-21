import Foundation
import Alamofire

/// GitHub task provider using GitHub Issues API.
/// Maps GitHub Issues to UnifiedTask format.
public actor GitHubTaskProvider: TaskProvider {
    private let config: GitHubProviderConfig
    private let tokenSource: GitHubTokenSource
    private let session: Session
    private var cachedToken: String?
    private var authenticated: Bool = false
    
    public nonisolated let providerId: String = "github"
    public nonisolated let providerName: String = "GitHub"
    
    public var isEnabled: Bool {
        config.enabled &&
        config.owner != nil && !config.owner!.isEmpty &&
        config.repo != nil && !config.repo!.isEmpty
    }
    
    public init(config: FleetMateConfig, deviceFlowPrompt: ((String, URL) async -> Void)? = nil) {
        let githubConfig = config.tasks?.providers.github ?? GitHubProviderConfig()
        self.config = githubConfig
        self.tokenSource = GitHubTokenSource(config: githubConfig, deviceFlowPrompt: deviceFlowPrompt)
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = Session(configuration: configuration)
    }
    
    public func authenticate() async throws -> Bool {
        guard let token = await tokenSource.token() else {
            print("GitHub: No token available")
            return false
        }
        
        cachedToken = token
        
        // Verify token by getting authenticated user
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        
        do {
            let _: GitHubUser = try await fetch(url: "https://api.github.com/user", headers: headers)
            authenticated = true
            print("Authenticated with GitHub as owner: \(config.owner ?? "")")
            return true
        } catch {
            print("GitHub authentication failed: \(error)")
            authenticated = false
            return false
        }
    }
    
    private func headers() -> HTTPHeaders {
        [
            "Authorization": "Bearer \(cachedToken ?? "")",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
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
            queryParams.append("labels=\(labels.joined(separator: ","))")
        }
        
        // Assignee filter
        if let assignees = filter?.assignees, let first = assignees.first {
            queryParams.append("assignee=\(first)")
        }
        
        // Milestone (bucket) filter
        if let bucket = filter?.bucket {
            queryParams.append("milestone=\(bucket)")
        }
        
        // Limit
        let perPage = min(filter?.limit ?? 100, 100)
        queryParams.append("per_page=\(perPage)")
        
        let url = "https://api.github.com/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues?\(queryParams.joined(separator: "&"))"
        
        var issues: [GitHubIssue] = try await fetch(url: url, headers: headers())
        
        // Filter out pull requests
        issues = issues.filter { $0.pullRequest == nil }
        
        // Apply search text filter client-side if needed
        if let searchText = filter?.searchText?.lowercased() {
            issues = issues.filter { issue in
                issue.title.lowercased().contains(searchText) ||
                (issue.body?.lowercased().contains(searchText) ?? false)
            }
        }
        
        return issues.map { mapToUnifiedTask($0) }
    }
    
    public func getTask(taskId: String) async throws -> UnifiedTask? {
        let url = "https://api.github.com/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues/\(taskId)"
        
        do {
            let issue: GitHubIssue = try await fetch(url: url, headers: headers())
            return mapToUnifiedTask(issue)
        } catch {
            return nil
        }
    }
    
    public func createTask(request: CreateTaskRequest) async throws -> UnifiedTask {
        var labels = request.labels ?? []
        labels.append(contentsOf: config.defaultLabels)
        labels = Array(Set(labels))
        
        var body: [String: Any] = [
            "title": request.title
        ]
        
        if let description = request.description {
            body["body"] = description
        }
        if !labels.isEmpty {
            body["labels"] = labels
        }
        if let assignees = request.assignees {
            body["assignees"] = assignees
        }
        if let bucket = request.bucket, let milestone = Int(bucket) {
            body["milestone"] = milestone
        }
        
        let url = "https://api.github.com/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues"
        let issue: GitHubIssue = try await post(url: url, body: body, headers: headers())
        
        print("GitHub: Created issue #\(issue.number): \(request.title)")
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
            body["labels"] = labels
        }
        if let assignees = request.assignees {
            body["assignees"] = assignees
        }
        if let bucket = request.bucket, let milestone = Int(bucket) {
            body["milestone"] = milestone
        }
        
        let url = "https://api.github.com/repos/\(config.owner ?? "")/\(config.repo ?? "")/issues/\(taskId)"
        let issue: GitHubIssue = try await patch(url: url, body: body, headers: headers())
        
        return mapToUnifiedTask(issue)
    }
    
    public func deleteTask(taskId: String) async throws -> Bool {
        // GitHub doesn't support deleting issues, only closing them
        _ = try await updateTask(taskId: taskId, request: UpdateTaskRequest(state: .closed))
        return true
    }
    
    public func listBuckets() async throws -> [TaskBucket] {
        let url = "https://api.github.com/repos/\(config.owner ?? "")/\(config.repo ?? "")/milestones?state=open"
        
        let milestones: [GitHubMilestone] = try await fetch(url: url, headers: headers())
        
        return milestones.enumerated().map { index, milestone in
            TaskBucket(
                id: String(milestone.number),
                name: milestone.title,
                order: index
            )
        }
    }
    
    public func listLabels() async throws -> [TaskLabel] {
        let url = "https://api.github.com/repos/\(config.owner ?? "")/\(config.repo ?? "")/labels"
        
        let labels: [GitHubLabel] = try await fetch(url: url, headers: headers())
        
        return labels.map { label in
            TaskLabel(
                name: label.name,
                color: label.color.map { "#\($0)" },
                description: label.labelDescription
            )
        }
    }
    
    private func mapToUnifiedTask(_ issue: GitHubIssue) -> UnifiedTask {
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
                .responseDecodable(of: T.self, decoder: gitHubDecoder) { response in
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
                .responseDecodable(of: T.self, decoder: gitHubDecoder) { response in
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
                .responseDecodable(of: T.self, decoder: gitHubDecoder) { response in
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

// MARK: - GitHub API Models

private struct GitHubIssue: Decodable {
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let state: String
    let assignees: [GitHubUser]?
    let labels: [GitHubLabel]?
    let milestone: GitHubMilestone?
    let pullRequest: GitHubPullRequest?
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

private struct GitHubLabel: Decodable {
    let name: String
    let color: String?
    let labelDescription: String?
    
    enum CodingKeys: String, CodingKey {
        case name, color
        case labelDescription = "description"
    }
}

private struct GitHubPullRequest: Decodable {
    let url: String?
}

// Custom decoder for GitHub dates
private let gitHubDecoder: JSONDecoder = {
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
