import Foundation

/// Azure DevOps service — REST API via URLSession with Bearer token authentication.
/// Token is injected externally by AppState after SSO authentication completes.
/// **NO CLI shelling, NO PAT** — all operations use OAuth2 access tokens.
public class AzureDevOpsService {
    private let config: FleetMateConfig
    private let orgUrl: String
    private let project: String

    // Bearer token (injected by AppState after SSO)
    private var bearerToken: String?
    private var tokenExpiry: Date = .distantPast

    // Caches
    private var sprintCache: [Sprint]?
    private var sprintCacheExpiry: Date = .distantPast
    private var defaultTeamCache: String?
    private let cacheDuration: TimeInterval

    // URLSession
    private let session: URLSession

    public var isConfigured: Bool {
        config.isDevOpsConfigured
    }

    public var baseUrl: String {
        orgUrl
    }

    /// Whether we have a valid Bearer token
    public var hasValidToken: Bool {
        guard let token = bearerToken, !token.isEmpty else { return false }
        return Date().addingTimeInterval(60) < tokenExpiry
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)
        self.orgUrl = "https://azure-devops.example.com/\(config.devopsOrganization ?? "")"
        self.project = config.devopsProject ?? ""

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Token Management

    /// Set the Bearer token (called by AppState after SSO succeeds)
    public func setBearerToken(_ token: String, expiry: Date) {
        self.bearerToken = token
        self.tokenExpiry = expiry
        dbg.info("AzDO Bearer token set, expires \(expiry)", category: "azdo-auth")
    }

    /// Clear the Bearer token (called on sign-out)
    public func clearBearerToken() {
        self.bearerToken = nil
        self.tokenExpiry = .distantPast
        self.sprintCache = nil
        self.defaultTeamCache = nil
    }

    // MARK: - REST API Helper

    /// Make an authenticated REST API request and decode the JSON response.
    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        contentType: String = "application/json",
        orgLevel: Bool = false
    ) async throws -> T {
        guard let token = bearerToken, !token.isEmpty else {
            throw AzDevOpsError.notLoggedIn
        }

        let basePath = orgLevel ? orgUrl : "\(orgUrl)/\(project)"
        guard let url = URL(string: "\(basePath)\(path)") else {
            throw AzDevOpsError.invalidUrl(path)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Suppress", forHTTPHeaderField: "X-TFS-FedAuthRedirect")
        if let body = body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        dbg.debug("AzDO \(method) \(url.absoluteString)", category: "azdo")

        let (data, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzDevOpsError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            dbg.error("AzDO \(method) \(path) → \(httpResponse.statusCode): \(errBody.prefix(500))", category: "azdo")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AzDevOpsError.notLoggedIn
            }
            throw AzDevOpsError.httpError(code: httpResponse.statusCode, message: errBody)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Make an authenticated request without decoding (for status-check calls)
    private func requestRaw(_ method: String, path: String, orgLevel: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let token = bearerToken, !token.isEmpty else {
            throw AzDevOpsError.notLoggedIn
        }

        let basePath = orgLevel ? orgUrl : "\(orgUrl)/\(project)"
        guard let url = URL(string: "\(basePath)\(path)") else {
            throw AzDevOpsError.invalidUrl(path)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Suppress", forHTTPHeaderField: "X-TFS-FedAuthRedirect")

        let (data, response) = try await session.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzDevOpsError.invalidResponse
        }
        return (data, httpResponse)
    }

    // MARK: - Auth Check

    /// Verify the REST API is accessible with the current token.
    public func verifyAuth() async throws -> Bool {
        do {
            let (_, resp) = try await requestRaw("GET", path: "/_apis/projects?api-version=7.0&$top=1", orgLevel: true)
            let ok = resp.statusCode == 200
            dbg.info("AzDO auth verified: \(ok) (status=\(resp.statusCode))", category: "azdo-auth")
            return ok
        } catch AzDevOpsError.notLoggedIn {
            return false
        } catch {
            dbg.error("AzDO auth verification failed: \(error)", category: "azdo-auth")
            return false
        }
    }

    // MARK: - Work Items

    /// Query work items via WIQL (2-step: query → batch get)
    func queryWorkItems(_ wiql: String) async throws -> [WorkItem] {
        dbg.debug("AzDO queryWorkItems: \(wiql.prefix(120))...", category: "azdo")

        // Step 1: WIQL query returns work item references (IDs only)
        let wiqlBody = try JSONEncoder().encode(["query": wiql])
        let queryResult: WorkItemQueryResult = try await request(
            "POST",
            path: "/_apis/wit/wiql?api-version=7.0",
            body: wiqlBody
        )

        guard let refs = queryResult.workItems, !refs.isEmpty else {
            dbg.info("AzDO WIQL query returned 0 items", category: "azdo")
            return []
        }

        // Step 2: Batch get work items by ID (max 200 per request)
        let ids = refs.map { $0.id }
        dbg.info("AzDO WIQL returned \(ids.count) IDs, batch fetching...", category: "azdo")
        return try await getWorkItemsByIds(ids)
    }

    public func getWorkItem(id: Int) async throws -> WorkItem? {
        dbg.debug("AzDO getWorkItem(\(id))", category: "azdo")
        let item: WorkItem = try await request(
            "GET",
            path: "/_apis/wit/workitems/\(id)?$expand=all&api-version=7.0",
            orgLevel: true
        )
        return item
    }

    public func getWorkItemsByIds(_ ids: [Int]) async throws -> [WorkItem] {
        guard !ids.isEmpty else { return [] }
        var allItems: [WorkItem] = []

        // Batch in groups of 200 (Azure DevOps limit)
        for chunk in ids.chunked(into: 200) {
            let idList = chunk.map(String.init).joined(separator: ",")
            let batch: WorkItemBatchResponse = try await request(
                "GET",
                path: "/_apis/wit/workitems?ids=\(idList)&$expand=all&api-version=7.0",
                orgLevel: true
            )
            if let items = batch.value {
                allItems.append(contentsOf: items)
            }
        }

        return allItems
    }

    public func getWorkItems(state: String? = nil, type: String? = nil, assignedTo: String? = nil, limit: Int = 50) async throws -> [WorkItem] {
        var conditions = ["[System.TeamProject] = @project"]
        if let state = state { conditions.append("[System.State] = '\(escapeWiql(state))'") }
        if let type = type { conditions.append("[System.WorkItemType] = '\(escapeWiql(type))'") }
        if let assignedTo = assignedTo { conditions.append("[System.AssignedTo] = '\(escapeWiql(assignedTo))'") }
        let wiql = "SELECT [System.Id] FROM WorkItems WHERE \(conditions.joined(separator: " AND ")) ORDER BY [System.ChangedDate] DESC"
        let items = try await queryWorkItems(wiql)
        return Array(items.prefix(limit))
    }

    public func createWorkItem(_ request: CreateWorkItemRequest) async throws -> WorkItem? {
        dbg.info("AzDO createWorkItem: \(request.title)", category: "azdo")

        // Build JSON Patch operations
        var ops: [[String: Any]] = [
            ["op": "add", "path": "/fields/System.Title", "value": request.title],
        ]
        if let desc = request.description {
            ops.append(["op": "add", "path": "/fields/System.Description", "value": desc])
        }
        if let assignee = request.assignedTo {
            ops.append(["op": "add", "path": "/fields/System.AssignedTo", "value": assignee])
        }
        if let priority = request.priority {
            ops.append(["op": "add", "path": "/fields/Microsoft.VSTS.Common.Priority", "value": priority])
        }
        if let iter = request.iterationPath {
            ops.append(["op": "add", "path": "/fields/System.IterationPath", "value": iter])
        }
        if let area = request.areaPath {
            ops.append(["op": "add", "path": "/fields/System.AreaPath", "value": area])
        }
        if let tags = request.tags, !tags.isEmpty {
            ops.append(["op": "add", "path": "/fields/System.Tags", "value": tags.joined(separator: "; ")])
        }

        let body = try JSONSerialization.data(withJSONObject: ops)
        let encodedType = request.type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.type

        let item: WorkItem = try await self.request(
            "POST",
            path: "/_apis/wit/workitems/$\(encodedType)?api-version=7.0",
            body: body,
            contentType: "application/json-patch+json"
        )
        return item
    }

    public func updateWorkItem(id: Int, request: UpdateWorkItemRequest) async throws -> WorkItem? {
        dbg.info("AzDO updateWorkItem(\(id))", category: "azdo")

        var ops: [[String: Any]] = []
        if let title = request.title {
            ops.append(["op": "replace", "path": "/fields/System.Title", "value": title])
        }
        if let state = request.state {
            ops.append(["op": "replace", "path": "/fields/System.State", "value": state])
        }
        if let assignee = request.assignedTo {
            ops.append(["op": "replace", "path": "/fields/System.AssignedTo", "value": assignee])
        }
        if let priority = request.priority {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.Common.Priority", "value": priority])
        }
        if let iter = request.iterationPath {
            ops.append(["op": "replace", "path": "/fields/System.IterationPath", "value": iter])
        }
        if let comment = request.comment {
            ops.append(["op": "add", "path": "/fields/System.History", "value": comment])
        }

        guard !ops.isEmpty else { return try await getWorkItem(id: id) }

        let body = try JSONSerialization.data(withJSONObject: ops)

        let item: WorkItem = try await self.request(
            "PATCH",
            path: "/_apis/wit/workitems/\(id)?api-version=7.0",
            body: body,
            contentType: "application/json-patch+json",
            orgLevel: true
        )
        return item
    }

    // MARK: - Sprints / Iterations

    public func getSprints(forceRefresh: Bool = false) async throws -> [Sprint] {
        if !forceRefresh, let cached = sprintCache, Date() < sprintCacheExpiry {
            dbg.debug("AzDO getSprints: using cache (\(cached.count) sprints)", category: "azdo")
            return cached
        }

        dbg.info("AzDO getSprints via REST API", category: "azdo")
        let team = try await getDefaultTeam()
        let encodedTeam = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team

        let response: IterationsResponse = try await request(
            "GET",
            path: "/\(encodedTeam)/_apis/work/teamsettings/iterations?api-version=7.0"
        )

        let sprints = response.value ?? []
        sprintCache = sprints
        sprintCacheExpiry = Date().addingTimeInterval(cacheDuration)
        dbg.info("AzDO getSprints: \(sprints.count) sprints loaded", category: "azdo")
        return sprints
    }

    public func getCurrentSprint() async throws -> Sprint? {
        let sprints = try await getSprints()
        return sprints.first { $0.isCurrent }
    }

    private func getDefaultTeam() async throws -> String {
        if let cached = defaultTeamCache { return cached }

        struct TeamsResponse: Decodable { let value: [TeamInfo]? }
        struct TeamInfo: Decodable { let name: String; let id: String }

        let response: TeamsResponse = try await request(
            "GET",
            path: "/_apis/projects/\(project)/teams?api-version=7.0",
            orgLevel: true
        )

        let teams = response.value ?? []
        let defaultTeam = teams.first { $0.name == "\(project) Team" } ?? teams.first
        let name = defaultTeam?.name ?? project
        defaultTeamCache = name
        dbg.debug("AzDO default team: \(name)", category: "azdo")
        return name
    }

    // MARK: - Boards

    public func getBoards() async throws -> [Board] {
        let team = try await getDefaultTeam()
        let encodedTeam = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team

        let response: BoardsResponse = try await request(
            "GET",
            path: "/\(encodedTeam)/_apis/work/boards?api-version=7.0"
        )
        return response.value ?? []
    }

    // MARK: - Projects

    public func listProjects() async throws -> [DevOpsProject] {
        dbg.info("AzDO listProjects via REST API", category: "azdo")

        struct ProjectsResponse: Decodable {
            let value: [DevOpsProject]?
        }

        let response: ProjectsResponse = try await request(
            "GET",
            path: "/_apis/projects?api-version=7.0",
            orgLevel: true
        )
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

    // MARK: - SSO backward-compat shims (referenced by AppState/views)
    public var requiresSsoLogin: Bool { !hasValidToken }
    public var hasSsoToken: Bool { hasValidToken }
    public func setSsoToken(_ token: String, expiry: Date, userId: String?, userName: String?) {
        setBearerToken(token, expiry: expiry)
    }
    public func clearSsoToken() { clearBearerToken() }

    // MARK: - WIQL Escaping

    /// Escape a value for safe inclusion in a WIQL string literal.
    /// WIQL uses single-quoted strings; escape `'` as `''`.
    func escapeWiql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - Error

public enum AzDevOpsError: Error, LocalizedError {
    case notLoggedIn
    case httpError(code: Int, message: String)
    case invalidUrl(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not authenticated to Azure DevOps. SSO login required."
        case .httpError(let code, let message):
            return "Azure DevOps API error (\(code)): \(message)"
        case .invalidUrl(let path):
            return "Invalid API URL: \(path)"
        case .invalidResponse:
            return "Invalid response from Azure DevOps API"
        }
    }
}

// MARK: - REST API Project Model

public struct DevOpsProject: Decodable {
    public let id: String
    public let name: String
    public let state: String?
}

// MARK: - Helpers

extension Array where Element == Int {
    func chunked(into size: Int) -> [[Int]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
