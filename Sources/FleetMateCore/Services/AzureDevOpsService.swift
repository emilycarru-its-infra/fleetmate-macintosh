import Foundation
import Alamofire

/// Azure DevOps service for work item management
/// Uses Azure CLI SSO for authentication on macOS
public class AzureDevOpsService {
    private let config: FleetMateConfig
    private let session: Session
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast
    private var ssoToken: String?
    private var ssoTokenExpiry: Date = .distantPast
    private var ssoUserId: String?
    private var ssoUserName: String?

    // Caches
    private var sprintCache: [Sprint]?
    private var sprintCacheExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval

    private let adoResourceId = "499b84ac-1321-427f-aa17-267ca6975798"

    public var isConfigured: Bool {
        return config.isDevOpsConfigured
    }

    public var baseUrl: String {
        "https://azure-devops.example.com/\(config.devopsOrganization ?? "")"
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = Session(configuration: configuration)
    }

    // MARK: - Authentication

    /// Whether browser SSO is required (no PAT and no Azure CLI)
    public var requiresSsoLogin: Bool {
        if config.devopsPat != nil { return false }
        // Check if az CLI is available
        let azPaths = ["/usr/local/bin/az", "/opt/homebrew/bin/az"]
        let azAvailable = azPaths.contains { FileManager.default.fileExists(atPath: $0) }
        return !azAvailable
    }

    /// Set SSO token from browser-based OAuth2 flow
    public func setSsoToken(_ token: String, expiry: Date, userId: String?, userName: String?) {
        ssoToken = token
        ssoTokenExpiry = expiry
        ssoUserId = userId
        ssoUserName = userName
        cachedToken = token
        tokenExpiry = expiry
    }

    /// Clear SSO token
    public func clearSsoToken() {
        ssoToken = nil
        ssoTokenExpiry = .distantPast
        ssoUserId = nil
        ssoUserName = nil
        cachedToken = nil
        tokenExpiry = .distantPast
    }

    /// Check if SSO token is valid
    public var hasSsoToken: Bool {
        ssoToken != nil && Date() < ssoTokenExpiry
    }

    private func getAccessToken() async throws -> String? {
        if let token = cachedToken, Date() < tokenExpiry {
            return token
        }

        // Try SSO token first
        if let token = ssoToken, Date() < ssoTokenExpiry {
            cachedToken = token
            tokenExpiry = ssoTokenExpiry
            return token
        }

        // Try PAT if configured
        if let pat = config.devopsPat, !pat.isEmpty {
            cachedToken = pat
            tokenExpiry = Date.distantFuture
            return pat
        }

        // Use Azure CLI SSO
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/az")
        process.arguments = ["account", "get-access-token", "--resource", adoResourceId, "--query", "accessToken", "-o", "tsv"]

        // Try Homebrew arm64 path
        if !FileManager.default.fileExists(atPath: "/usr/local/bin/az") {
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/az") {
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/az")
            } else {
                print("Azure CLI not found and no PAT configured.")
                return nil
            }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                print("Azure CLI failed. Run 'az login' first.")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            cachedToken = token
            tokenExpiry = Date().addingTimeInterval(55 * 60)

            return token
        } catch {
            print("Failed to run Azure CLI: \(error)")
            return nil
        }
    }

    private func headers() async -> HTTPHeaders? {
        guard let token = try? await getAccessToken() else { return nil }

        // If using PAT, use Basic auth
        if config.devopsPat != nil {
            let auth = ":\(token)".data(using: .utf8)?.base64EncodedString() ?? ""
            return [
                "Authorization": "Basic \(auth)",
                "Content-Type": "application/json"
            ]
        }

        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    // MARK: - Work Items

    func queryWorkItems(_ wiql: String) async throws -> [WorkItem] {
        guard let headers = await headers() else { return [] }

        let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/wit/wiql?api-version=7.0"
        let body = ["query": wiql]

        let queryResult: WorkItemQueryResult = try await post(url: url, body: body, headers: headers)

        guard let workItemRefs = queryResult.workItems, !workItemRefs.isEmpty else {
            return []
        }

        let ids = workItemRefs.map { $0.id }
        return try await getWorkItemsByIds(ids)
    }

    public func getWorkItemsByIds(_ ids: [Int]) async throws -> [WorkItem] {
        guard !ids.isEmpty, let headers = await headers() else { return [] }

        var allItems: [WorkItem] = []

        // Batch requests (max 200 per request)
        for batch in ids.chunked(into: 200) {
            let idsParam = batch.map { String($0) }.joined(separator: ",")
            let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/wit/workitems?ids=\(idsParam)&api-version=7.0"

            let response: WorkItemBatchResponse = try await fetch(url: url, headers: headers)
            if let items = response.value {
                allItems.append(contentsOf: items)
            }
        }

        return allItems
    }

    public func getWorkItem(id: Int) async throws -> WorkItem? {
        guard let headers = await headers() else { return nil }

        let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/wit/workitems/\(id)?api-version=7.0"
        return try await fetch(url: url, headers: headers)
    }

    public func getWorkItems(state: String? = nil, type: String? = nil, assignedTo: String? = nil, limit: Int = 50) async throws -> [WorkItem] {
        var conditions = ["[System.TeamProject] = @project"]

        if let state = state {
            conditions.append("[System.State] = '\(state)'")
        }
        if let type = type {
            conditions.append("[System.WorkItemType] = '\(type)'")
        }
        if let assignedTo = assignedTo {
            conditions.append("[System.AssignedTo] = '\(assignedTo)'")
        }

        let wiql = "SELECT [System.Id] FROM WorkItems WHERE \(conditions.joined(separator: " AND ")) ORDER BY [System.ChangedDate] DESC"

        let items = try await queryWorkItems(wiql)
        return Array(items.prefix(limit))
    }

    public func createWorkItem(_ request: CreateWorkItemRequest) async throws -> WorkItem? {
        guard let headers = await headers() else { return nil }

        var operations: [[String: Any]] = [
            ["op": "add", "path": "/fields/System.Title", "value": request.title]
        ]

        if let description = request.description {
            operations.append(["op": "add", "path": "/fields/System.Description", "value": description])
        }
        if let assignedTo = request.assignedTo {
            operations.append(["op": "add", "path": "/fields/System.AssignedTo", "value": assignedTo])
        }
        if let priority = request.priority {
            operations.append(["op": "add", "path": "/fields/Microsoft.VSTS.Common.Priority", "value": priority])
        }
        if let iterationPath = request.iterationPath {
            operations.append(["op": "add", "path": "/fields/System.IterationPath", "value": iterationPath])
        }
        if let areaPath = request.areaPath {
            operations.append(["op": "add", "path": "/fields/System.AreaPath", "value": areaPath])
        }
        if let tags = request.tags, !tags.isEmpty {
            operations.append(["op": "add", "path": "/fields/System.Tags", "value": tags.joined(separator: "; ")])
        }

        let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/wit/workitems/$\(request.type)?api-version=7.0"

        var patchHeaders = headers
        patchHeaders.add(name: "Content-Type", value: "application/json-patch+json")

        return try await postPatch(url: url, body: operations, headers: patchHeaders)
    }

    public func updateWorkItem(id: Int, request: UpdateWorkItemRequest) async throws -> WorkItem? {
        guard let headers = await headers() else { return nil }

        var operations: [[String: Any]] = []

        if let title = request.title {
            operations.append(["op": "add", "path": "/fields/System.Title", "value": title])
        }
        if let state = request.state {
            operations.append(["op": "add", "path": "/fields/System.State", "value": state])
        }
        if let assignedTo = request.assignedTo {
            operations.append(["op": "add", "path": "/fields/System.AssignedTo", "value": assignedTo])
        }
        if let priority = request.priority {
            operations.append(["op": "add", "path": "/fields/Microsoft.VSTS.Common.Priority", "value": priority])
        }
        if let iterationPath = request.iterationPath {
            operations.append(["op": "add", "path": "/fields/System.IterationPath", "value": iterationPath])
        }
        if let comment = request.comment {
            operations.append(["op": "add", "path": "/fields/System.History", "value": comment])
        }

        guard !operations.isEmpty else {
            return try await getWorkItem(id: id)
        }

        let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/wit/workitems/\(id)?api-version=7.0"

        var patchHeaders = headers
        patchHeaders.add(name: "Content-Type", value: "application/json-patch+json")

        return try await patchRequest(url: url, body: operations, headers: patchHeaders)
    }

    // MARK: - Sprints

    public func getSprints(forceRefresh: Bool = false) async throws -> [Sprint] {
        if !forceRefresh, let cached = sprintCache, Date() < sprintCacheExpiry {
            return cached
        }

        guard let headers = await headers() else { return sprintCache ?? [] }

        let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/work/teamsettings/iterations?api-version=7.0"

        let response: IterationsResponse = try await fetch(url: url, headers: headers)
        sprintCache = response.value ?? []
        sprintCacheExpiry = Date().addingTimeInterval(cacheDuration)

        return sprintCache ?? []
    }

    public func getCurrentSprint() async throws -> Sprint? {
        let sprints = try await getSprints()
        return sprints.first { $0.isCurrent }
    }

    // MARK: - Boards

    public func getBoards() async throws -> [Board] {
        guard let headers = await headers() else { return [] }

        let url = "\(baseUrl)/\(config.devopsProject ?? "")/_apis/work/boards?api-version=7.0"

        let response: BoardsResponse = try await fetch(url: url, headers: headers)
        return response.value ?? []
    }

    // MARK: - Error Creation

    public func createFromError(deviceName: String, itemName: String, errorMessage: String, assignedTo: String? = nil, priority: Int = 2) async throws -> WorkItem? {
        let title = "[FleetMate] \(itemName) failed on \(deviceName)"
        let description = """
        <h3>Installation Failure</h3>
        <p><strong>Device:</strong> \(deviceName)</p>
        <p><strong>Package:</strong> \(itemName)</p>
        <p><strong>Error:</strong></p>
        <pre>\(errorMessage)</pre>
        <hr/>
        <p><em>Created automatically by FleetMate</em></p>
        """

        let request = CreateWorkItemRequest(
            title: title,
            type: config.devopsDefaultWorkItemType,
            description: description,
            assignedTo: assignedTo,
            priority: priority,
            tags: ["FleetMate", "AutoGenerated", itemName]
        )

        return try await createWorkItem(request)
    }

    // MARK: - Private Helpers

    private func fetch<T: Decodable>(url: String, headers: HTTPHeaders) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
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

    private func post<T: Decodable>(url: String, body: [String: Any], headers: HTTPHeaders) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
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

    private func postPatch<T: Decodable>(url: String, body: [[String: Any]], headers: HTTPHeaders) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body.asParameters(), encoding: ArrayEncoding(), headers: headers)
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

    private func patchRequest<T: Decodable>(url: String, body: [[String: Any]], headers: HTTPHeaders) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .patch, parameters: body.asParameters(), encoding: ArrayEncoding(), headers: headers)
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

// MARK: - Helpers

extension Array where Element == Int {
    func chunked(into size: Int) -> [[Int]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension Array where Element == [String: Any] {
    func asParameters() -> Parameters {
        return ["": self]
    }
}

struct ArrayEncoding: ParameterEncoding {
    func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        var request = try urlRequest.asURLRequest()
        guard let array = parameters?[""] as? [[String: Any]] else { return request }
        request.httpBody = try JSONSerialization.data(withJSONObject: array)
        return request
    }
}
