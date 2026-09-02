import Foundation

/// Azure DevOps service — REST API via URLSession with Bearer token authentication.
/// Token is injected externally by AppState after SSO authentication completes.
/// **NO CLI shelling, NO PAT** — all operations use OAuth2 access tokens.
public class AzureDevOpsService {
    private let config: FleetMateConfig
    private var orgUrl: String
    private var project: String

    // Bearer token (injected by AppState after SSO)
    private var bearerToken: String?
    private var tokenExpiry: Date = .distantPast

    /// Re-acquires a token silently when Azure DevOps rejects the current one.
    ///
    /// The service is handed its token from outside and had no way to recover on
    /// its own: a 401 surfaced to the user as "SSO login required" even while a
    /// silent `az` token was available for the asking. Set by AppState to the SSO
    /// service's refresh; returns the new token and its expiry, or nil.
    public var tokenRefreshHandler: (() async -> (token: String, expiry: Date)?)?

    /// Guards against a burst of concurrent 401s each kicking off its own refresh.
    private var refreshInFlight: Task<Bool, Never>?

    // Caches
    private var sprintCache: [Sprint]?
    private var sprintCacheExpiry: Date = .distantPast
    private var defaultTeamCache: String?
    private var identityCache: DevOpsIdentitySummary?
    private let cacheDuration: TimeInterval

    // URLSession
    private let session: URLSession

    /// Whether at least an organization is configured
    public var isConfigured: Bool {
        !orgUrl.hasSuffix("/") || orgUrl.count > (config.effectiveDevopsBaseUrl + "/").count
    }

    public var baseUrl: String {
        orgUrl
    }

    /// The resolved project name (may be empty until discovery)
    public var resolvedProject: String { project }

    /// Whether we have a valid Bearer token
    public var hasValidToken: Bool {
        guard let token = bearerToken, !token.isEmpty else { return false }
        return Date().addingTimeInterval(60) < tokenExpiry
    }

    /// Whether SSO has ever handed us a token this session, expired or not.
    /// An expired token is a refresh away from working; no token at all
    /// means sign-in has not happened.
    public var hasBearerToken: Bool {
        guard let token = bearerToken else { return false }
        return !token.isEmpty
    }

    /// Make sure the token is usable before a caller decides whether to hit
    /// the API at all. Access tokens from `az` last about an hour; callers
    /// that gated on `hasValidToken` alone stopped asking once it lapsed and
    /// never reached the refresh inside `request`, so the app looked signed
    /// out after sitting idle. Returns whether a valid token is now held.
    @discardableResult
    public func ensureValidToken() async -> Bool {
        if hasValidToken { return true }
        guard hasBearerToken else { return false }
        return await refreshToken()
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        // Resolve org: provider-level override > top-level config
        let org = config.tasks?.providers.azdevops?.organization
                  ?? config.devopsOrganization
                  ?? ""
        self.orgUrl = "\(config.effectiveDevopsBaseUrl)/\(org)"

        // Resolve project: provider-level override > top-level config (may be empty — auto-discovered later)
        self.project = config.tasks?.providers.azdevops?.project
                       ?? config.devopsProject
                       ?? ""

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: sessionConfig)

        dbg.info("AzDO service init: org=\(org) project=\(self.project.isEmpty ? "(will auto-discover)" : self.project)", category: "azdo")
    }

    // MARK: - Token Management

    /// Set the Bearer token (called by AppState after SSO succeeds)
    public func setBearerToken(_ token: String, expiry: Date) {
        self.bearerToken = token
        self.tokenExpiry = expiry
        dbg.info("AzDO Bearer token set, expires \(expiry)", category: "azdo-auth")
    }

    /// Re-acquire a token through the refresh handler, coalescing concurrent
    /// callers onto one attempt. A board that fans out several requests at once
    /// would otherwise fire a refresh per 401.
    private func refreshToken() async -> Bool {
        if let existing = refreshInFlight {
            return await existing.value
        }
        guard let handler = tokenRefreshHandler else { return false }

        let task = Task<Bool, Never> { [weak self] in
            guard let refreshed = await handler() else {
                dbg.warn("AzDO token refresh failed", category: "azdo-auth")
                return false
            }
            self?.setBearerToken(refreshed.token, expiry: refreshed.expiry)
            return true
        }
        refreshInFlight = task
        let ok = await task.value
        refreshInFlight = nil
        return ok
    }

    /// Clear the Bearer token (called on sign-out)
    public func clearBearerToken() {
        self.bearerToken = nil
        self.tokenExpiry = .distantPast
        self.sprintCache = nil
        self.defaultTeamCache = nil
        self.identityCache = nil
    }

    // MARK: - REST API Helper

    /// Make an authenticated REST API request and decode the JSON response.
    /// Internal (not private) so same-module extensions in other files —
    /// AzureDevOpsService+Queries — can build on it.
    func request<T: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        contentType: String = "application/json",
        orgLevel: Bool = false,
        forProject: String? = nil,
        allowRetryAfterRefresh: Bool = true
    ) async throws -> T {
        // Refresh proactively when the token is spent. Previously only emptiness
        // was checked, so an expired token was sent anyway and came back 401 —
        // reported to the user as "SSO login required" despite a silent token
        // being one `az` call away.
        if !hasValidToken, bearerToken != nil, allowRetryAfterRefresh {
            _ = await refreshToken()
        }

        guard let token = bearerToken, !token.isEmpty else {
            throw AzDevOpsError.notLoggedIn
        }

        let basePath: String
        if orgLevel {
            basePath = orgUrl
        } else {
            let proj = forProject ?? project
            basePath = "\(orgUrl)/\(proj)"
        }
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

            // A 401 here means the token we hold was rejected, which is recoverable:
            // re-acquire silently and replay the request once. Only a refresh that
            // fails is worth telling the user about.
            if httpResponse.statusCode == 401, allowRetryAfterRefresh {
                if await refreshToken() {
                    dbg.info("AzDO retrying \(method) \(path) with a refreshed token", category: "azdo-auth")
                    return try await request(
                        method,
                        path: path,
                        body: body,
                        contentType: contentType,
                        orgLevel: orgLevel,
                        forProject: forProject,
                        allowRetryAfterRefresh: false
                    )
                }
                throw AzDevOpsError.notLoggedIn
            }

            // 403 is authenticated-but-forbidden. Reporting it as "SSO login
            // required" sent people to re-authenticate over a permissions problem.
            if httpResponse.statusCode == 403 {
                throw AzDevOpsError.forbidden(message: errBody)
            }
            throw AzDevOpsError.httpError(code: httpResponse.statusCode, message: errBody)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Make an authenticated request without decoding (for status-check calls)
    private func requestRaw(_ method: String, path: String, orgLevel: Bool = false, forProject: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token = bearerToken, !token.isEmpty else {
            throw AzDevOpsError.notLoggedIn
        }

        let basePath: String
        if orgLevel {
            basePath = orgUrl
        } else {
            let proj = forProject ?? project
            basePath = "\(orgUrl)/\(proj)"
        }
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
    /// Set orgLevel=true to query across all projects in the organization.
    public func queryWorkItems(_ wiql: String, orgLevel: Bool = false) async throws -> [WorkItem] {
        dbg.debug("AzDO queryWorkItems (orgLevel=\(orgLevel)): \(wiql.prefix(120))...", category: "azdo")

        // Step 1: WIQL query returns work item references (IDs only)
        let wiqlBody = try JSONEncoder().encode(["query": wiql])
        let queryResult: WorkItemQueryResult = try await request(
            "POST",
            path: "/_apis/wit/wiql?api-version=7.0",
            body: wiqlBody,
            orgLevel: orgLevel
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
        // Query across all projects at org level — no project filter needed
        var conditions: [String] = []
        if let state = state { conditions.append("[System.State] = '\(escapeWiql(state))'") }
        if let type = type { conditions.append("[System.WorkItemType] = '\(escapeWiql(type))'") }
        if let assignedTo = assignedTo { conditions.append("[System.AssignedTo] = '\(escapeWiql(assignedTo))'") }
        let whereClause = conditions.isEmpty ? "" : " WHERE \(conditions.joined(separator: " AND "))"
        let wiql = "SELECT [System.Id] FROM WorkItems\(whereClause) ORDER BY [System.ChangedDate] DESC"
        let items = try await queryWorkItems(wiql, orgLevel: true)
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
            // Store the description as Markdown, not HTML — the sheet's
            // editor is plain text and ADO renders the Markdown natively.
            ops.append(["op": "add", "path": "/multilineFieldsFormat/System.Description", "value": "markdown"])
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
            // 7.1: the multilineFieldsFormat patch path (Markdown
            // descriptions) is not recognized by 7.0.
            path: "/_apis/wit/workitems/$\(encodedType)?api-version=7.1",
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
            ops.append(["op": "add", "path": "/fields/System.State", "value": state])
        }
        if let wiType = request.workItemType {
            ops.append(["op": "add", "path": "/fields/System.WorkItemType", "value": wiType])
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
        if let area = request.areaPath {
            ops.append(["op": "replace", "path": "/fields/System.AreaPath", "value": area])
        }
        if let desc = request.description {
            ops.append(["op": "replace", "path": "/fields/System.Description", "value": desc])
        }
        if let tags = request.tags {
            ops.append(["op": "replace", "path": "/fields/System.Tags", "value": tags])
        }
        if let remaining = request.remainingWork {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.Scheduling.RemainingWork", "value": remaining])
        }
        if let original = request.originalEstimate {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.Scheduling.OriginalEstimate", "value": original])
        }
        if let completed = request.completedWork {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.Scheduling.CompletedWork", "value": completed])
        }
        if let repro = request.reproSteps {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.TCM.ReproSteps", "value": repro])
        }
        if let criteria = request.acceptanceCriteria {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.Common.AcceptanceCriteria", "value": criteria])
        }
        if let comment = request.comment {
            ops.append(["op": "add", "path": "/fields/System.History", "value": comment])
        }
        if let dueDate = request.dueDate {
            ops.append(["op": "replace", "path": "/fields/Microsoft.VSTS.Scheduling.DueDate", "value": dueDate])
        }

        guard !ops.isEmpty else { return try await getWorkItem(id: id) }

        let body = try JSONSerialization.data(withJSONObject: ops)

        let item: WorkItem = try await self.request(
            "PATCH",
            path: "/_apis/wit/workitems/\(id)?bypassRules=true&api-version=7.0",
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

    private func getDefaultTeam(project forProject: String? = nil) async throws -> String {
        let proj = forProject ?? project
        if let cached = defaultTeamCache, forProject == nil { return cached }

        struct TeamsResponse: Decodable { let value: [TeamInfo]? }
        struct TeamInfo: Decodable { let name: String; let id: String }

        let response: TeamsResponse = try await request(
            "GET",
            path: "/_apis/projects/\(proj)/teams?api-version=7.0",
            orgLevel: true
        )

        let teams = response.value ?? []
        let defaultTeam = teams.first { $0.name == "\(proj) Team" } ?? teams.first
        let name = defaultTeam?.name ?? proj
        if forProject == nil { defaultTeamCache = name }
        dbg.debug("AzDO default team for '\(proj)': \(name)", category: "azdo")
        return name
    }

    // MARK: - Boards

    /// List all teams in a project
    public func listTeams(project: String? = nil) async throws -> [(name: String, id: String)] {
        let proj = project ?? self.project

        struct TeamsResponse: Decodable { let value: [TeamInfo]? }
        struct TeamInfo: Decodable { let name: String; let id: String }

        let response: TeamsResponse = try await request(
            "GET",
            path: "/_apis/projects/\(proj)/teams?api-version=7.0",
            orgLevel: true
        )
        return (response.value ?? []).map { ($0.name, $0.id) }
    }

    public func getBoards(project: String? = nil) async throws -> [Board] {
        let team = try await getDefaultTeam(project: project)
        return try await getBoards(team: team, project: project)
    }

    /// Get boards for a specific team
    public func getBoards(team: String, project: String? = nil) async throws -> [Board] {
        let encodedTeam = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team

        let response: BoardsResponse = try await request(
            "GET",
            path: "/\(encodedTeam)/_apis/work/boards?api-version=7.0",
            forProject: project
        )
        return response.value ?? []
    }

    /// Get columns for a specific board (returns them in the correct display order).
    public func getBoardColumns(boardName: String, project: String? = nil) async throws -> [BoardColumnDefinition] {
        let team = try await getDefaultTeam(project: project)
        return try await getBoardColumns(boardName: boardName, team: team, project: project)
    }

    /// Get columns for a specific board and team
    public func getBoardColumns(boardName: String, team: String, project: String? = nil) async throws -> [BoardColumnDefinition] {
        let encodedTeam = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team
        let encodedBoard = boardName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? boardName

        let response: BoardColumnsResponse = try await request(
            "GET",
            path: "/\(encodedTeam)/_apis/work/boards/\(encodedBoard)/columns?api-version=7.0",
            forProject: project
        )
        return response.value ?? []
    }

    /// Get all valid work item types for the project's process template.
    public func getWorkItemTypes(project: String? = nil) async throws -> [WorkItemTypeDefinition] {
        let response: WorkItemTypesResponse = try await request(
            "GET",
            path: "/_apis/wit/workitemtypes?api-version=7.0",
            forProject: project
        )
        return (response.value ?? []).filter { !($0.isDisabled ?? false) }
    }

    /// Get valid states for a specific work item type.
    public func getWorkItemTypeStates(type: String, project: String? = nil) async throws -> [WorkItemTypeState] {
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        let response: WorkItemTypeStatesResponse = try await request(
            "GET",
            path: "/_apis/wit/workitemtypes/\(encodedType)/states?api-version=7.0",
            forProject: project
        )
        return response.value ?? []
    }

    /// Move a work item to a board column by setting System.State to the column's mapped state.
    /// Board columns are readonly; the correct way to move items is to update the state
    /// using the column's stateMappings for the given work item type.
    public func moveWorkItemToBoardColumn(id: Int, targetState: String) async throws -> WorkItem? {
        let ops: [[String: Any]] = [
            ["op": "add", "path": "/fields/System.State", "value": targetState]
        ]
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

    /// Auto-discover and set the project. Called after SSO when no project is configured.
    /// Picks the project with the most active work items. Falls back to the first project.
    /// Returns the discovered project name, or nil if none found.
    @discardableResult
    public func discoverProject(retries: Int = 2) async throws -> String? {
        var lastError: Error?
        for attempt in 1...(retries + 1) {
            do {
                let projects = try await listProjects()
                dbg.info("AzDO discoverProject: found \(projects.count) projects: \(projects.map { $0.name }.joined(separator: ", "))", category: "azdo")

                guard !projects.isEmpty else {
                    dbg.warn("AzDO discoverProject: no projects in org", category: "azdo")
                    return nil
                }

                // If only one project, use it directly
                if projects.count == 1 {
                    let picked = projects[0]
                    self.project = picked.name
                    self.defaultTeamCache = nil
                    self.sprintCache = nil
                    dbg.info("AzDO discoverProject: using '\(picked.name)' (only project)", category: "azdo")
                    return picked.name
                }

                // Multiple projects — pick the one with the most active work items
                var bestProject = projects[0].name
                var bestCount = 0
                for p in projects {
                    self.project = p.name
                    let wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '\(escapeWiql(p.name))' AND [System.State] <> 'Closed' AND [System.State] <> 'Done' AND [System.State] <> 'Removed'"
                    do {
                        let wiqlBody = try JSONEncoder().encode(["query": wiql])
                        let result: WorkItemQueryResult = try await request("POST", path: "/_apis/wit/wiql?api-version=7.0&$top=1", body: wiqlBody)
                        let count = result.workItems?.count ?? 0
                        dbg.debug("AzDO discoverProject: '\(p.name)' has \(count > 0 ? "items" : "no items")", category: "azdo")
                        if count > bestCount {
                            bestCount = count
                            bestProject = p.name
                        }
                    } catch {
                        dbg.debug("AzDO discoverProject: '\(p.name)' query failed: \(error)", category: "azdo")
                    }
                }

                self.project = bestProject
                self.defaultTeamCache = nil
                self.sprintCache = nil
                dbg.info("AzDO discoverProject: using '\(bestProject)'\(bestCount > 0 ? " (has active items)" : " (fallback)")", category: "azdo")
                return bestProject
            } catch {
                lastError = error
                dbg.warn("AzDO discoverProject attempt \(attempt) failed: \(error)", category: "azdo")
                if attempt <= retries {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
            }
        }
        throw lastError!
    }

    /// Set the project explicitly (e.g., from user selection or config).
    public func setProject(_ name: String) {
        self.project = name
        self.defaultTeamCache = nil
        self.sprintCache = nil
        dbg.info("AzDO project set to '\(name)'", category: "azdo")
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
    public func escapeWiql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Work Item Comments

    /// Fetch all comments for a work item using the Comments API.
    /// Pass the work item's `teamProject` to ensure correct project-scoped URL.
    public func getComments(workItemId: Int, project: String? = nil) async throws -> [WorkItemComment] {
        dbg.info("AzDO getComments(\(workItemId)) project=\(project ?? self.project)", category: "azdo")
        let response: WorkItemCommentsResponse = try await request(
            "GET",
            path: "/_apis/wit/workitems/\(workItemId)/comments?$expand=all&api-version=7.1-preview.3",
            forProject: project
        )
        return response.comments ?? []
    }

    /// Add a comment to a work item using the Comments API.
    /// Pass the work item's `teamProject` to ensure correct project-scoped URL.
    @discardableResult
    public func addComment(workItemId: Int, text: String, project: String? = nil) async throws -> WorkItemComment {
        dbg.info("AzDO addComment(\(workItemId))", category: "azdo")
        let body = try JSONEncoder().encode(["text": text])
        let comment: WorkItemComment = try await request(
            "POST",
            path: "/_apis/wit/workitems/\(workItemId)/comments?api-version=7.1-preview.3",
            body: body,
            forProject: project
        )
        return comment
    }

    /// Update an existing comment on a work item.
    @discardableResult
    public func updateComment(workItemId: Int, commentId: Int, text: String, project: String? = nil) async throws -> WorkItemComment {
        dbg.info("AzDO updateComment(\(workItemId), comment=\(commentId))", category: "azdo")
        let body = try JSONEncoder().encode(["text": text])
        let comment: WorkItemComment = try await request(
            "PATCH",
            path: "/_apis/wit/workitems/\(workItemId)/comments/\(commentId)?api-version=7.1-preview.3",
            body: body,
            forProject: project
        )
        return comment
    }

    /// Delete a comment from a work item.
    public func deleteComment(workItemId: Int, commentId: Int, project: String? = nil) async throws {
        dbg.info("AzDO deleteComment(\(workItemId), comment=\(commentId))", category: "azdo")
        let (_, resp) = try await requestRaw(
            "DELETE",
            path: "/_apis/wit/workitems/\(workItemId)/comments/\(commentId)?api-version=7.1-preview.3",
            forProject: project
        )
        guard (200...299).contains(resp.statusCode) else {
            throw AzDevOpsError.httpError(code: resp.statusCode, message: "Delete comment failed")
        }
    }

    /// Toggle a reaction on a work item comment.
    /// Uses PUT to add and DELETE to remove.
    @discardableResult
    public func toggleCommentReaction(workItemId: Int, commentId: Int, reactionType: String, add: Bool, project: String? = nil) async throws -> Bool {
        dbg.info("AzDO \(add ? "add" : "remove") reaction '\(reactionType)' on comment \(commentId)", category: "azdo")
        let method = add ? "PUT" : "DELETE"
        let (_, resp) = try await requestRaw(
            method,
            path: "/_apis/wit/workitems/\(workItemId)/comments/\(commentId)/reactions/\(reactionType)?api-version=7.1-preview.1",
            forProject: project
        )
        return (200...299).contains(resp.statusCode)
    }

    // MARK: - Classification Nodes (Area Paths & Iteration Paths)

    /// Fetch all area paths for a project, flattened into path strings.
    public func getAreaPaths(project: String? = nil) async throws -> [String] {
        let node: ClassificationNode = try await request(
            "GET",
            path: "/_apis/wit/classificationnodes/areas?$depth=10&api-version=7.0",
            forProject: project
        )
        return flattenClassificationNode(node)
    }

    /// Fetch all iteration paths for a project, flattened into path strings.
    public func getIterationPaths(project: String? = nil) async throws -> [String] {
        let node: ClassificationNode = try await request(
            "GET",
            path: "/_apis/wit/classificationnodes/iterations?$depth=10&api-version=7.0",
            forProject: project
        )
        return flattenClassificationNode(node)
    }

    /// Recursively flatten a classification node tree into path strings.
    private func flattenClassificationNode(_ node: ClassificationNode, prefix: String = "") -> [String] {
        let currentPath = prefix.isEmpty ? (node.name ?? "") : "\(prefix)\\\(node.name ?? "")"
        var paths = [currentPath]
        if let children = node.children {
            for child in children {
                paths.append(contentsOf: flattenClassificationNode(child, prefix: currentPath))
            }
        }
        return paths
    }

    // MARK: - Team Members

    /// Fetch team members for the default team of a project.
    public func getTeamMembers(project: String? = nil) async throws -> [IdentityRef] {
        let proj = project ?? self.project
        let team = try await getDefaultTeam()
        let encodedTeam = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team
        let encodedProj = proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj

        struct TeamMembersResponse: Decodable {
            let value: [TeamMemberEntry]?
            let count: Int?
        }
        struct TeamMemberEntry: Decodable {
            let identity: IdentityRef?
        }

        let response: TeamMembersResponse = try await request(
            "GET",
            path: "/_apis/projects/\(encodedProj)/teams/\(encodedTeam)/members?api-version=7.0",
            orgLevel: true
        )
        return (response.value ?? []).compactMap { $0.identity }
    }

    /// Every human member across all of the project's teams, deduped by
    /// uniqueName and sorted by display name. Groups (isContainer) and
    /// non-person identities (build service, service principals, managed
    /// identities — anything without a person-shaped UPN) are filtered out:
    /// the assignee picker should offer people only.
    public func getProjectMembers(project: String? = nil) async throws -> [IdentityRef] {
        let proj = project ?? self.project
        let encodedProj = proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj

        struct TeamsResponse: Decodable { let value: [TeamEntry]? }
        struct TeamEntry: Decodable { let name: String? }
        struct MembersResponse: Decodable { let value: [MemberEntry]? }
        struct MemberEntry: Decodable { let identity: MemberIdentity? }
        struct MemberIdentity: Decodable {
            let displayName: String?
            let uniqueName: String?
            let id: String?
            let isContainer: Bool?
        }

        let teams: TeamsResponse = try await request(
            "GET",
            path: "/_apis/projects/\(encodedProj)/teams?api-version=7.0",
            orgLevel: true
        )

        var byUnique: [String: IdentityRef] = [:]
        for team in teams.value ?? [] {
            guard let teamName = team.name else { continue }
            let encodedTeam = teamName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? teamName
            do {
                let response: MembersResponse = try await request(
                    "GET",
                    path: "/_apis/projects/\(encodedProj)/teams/\(encodedTeam)/members?api-version=7.0",
                    orgLevel: true
                )
                for entry in response.value ?? [] {
                    guard let identity = entry.identity, identity.isContainer != true else { continue }
                    guard let unique = identity.uniqueName, unique.contains("@") else { continue }
                    let lowered = unique.lowercased()
                    if lowered.hasPrefix("vstfs:") { continue }
                    if (identity.displayName ?? "").localizedCaseInsensitiveContains("build service") { continue }
                    byUnique[lowered] = IdentityRef(
                        displayName: identity.displayName,
                        uniqueName: unique,
                        id: identity.id
                    )
                }
            } catch {
                // A team without boards (TF400499 and friends) shouldn't sink
                // the whole roster.
                continue
            }
        }
        return byUnique.values.sorted {
            ($0.displayName ?? $0.uniqueName ?? "")
                .localizedCaseInsensitiveCompare($1.displayName ?? $1.uniqueName ?? "") == .orderedAscending
        }
    }

    // MARK: - Git Repositories

    /// List all Git repositories in a project.
    public func getRepositories(project: String? = nil) async throws -> [GitRepository] {
        dbg.info("AzDO getRepositories", category: "azdo")
        let response: GitRepositoriesResponse = try await request(
            "GET",
            path: "/_apis/git/repositories?api-version=7.0",
            forProject: project
        )
        return response.value ?? []
    }

    /// List branches (refs/heads) for a repository.
    public func getBranches(repositoryId: String, project: String? = nil) async throws -> [GitRef] {
        dbg.info("AzDO getBranches(\(repositoryId))", category: "azdo")
        let encodedRepoId = repositoryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryId
        let response: GitRefsResponse = try await request(
            "GET",
            path: "/_apis/git/repositories/\(encodedRepoId)/refs?filter=heads/&api-version=7.0",
            forProject: project
        )
        return response.value ?? []
    }

    /// Create a new branch in a repository from a source branch's latest commit.
    /// - Parameters:
    ///   - repositoryId: The Git repository ID.
    ///   - branchName: Short name for the new branch (without refs/heads/ prefix).
    ///   - sourceObjectId: The commit SHA to branch from.
    ///   - project: Optional project override.
    /// - Returns: The created GitRef, or nil if creation failed.
    public func createBranch(repositoryId: String, branchName: String, sourceObjectId: String, project: String? = nil) async throws -> GitRef? {
        dbg.info("AzDO createBranch(\(branchName)) in \(repositoryId)", category: "azdo")
        let encodedRepoId = repositoryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryId
        let zeroId = String(repeating: "0", count: 40)
        let refUpdates: [[String: String]] = [
            [
                "name": "refs/heads/\(branchName)",
                "oldObjectId": zeroId,
                "newObjectId": sourceObjectId
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: refUpdates)
        let response: GitRefsResponse = try await request(
            "POST",
            path: "/_apis/git/repositories/\(encodedRepoId)/refs?api-version=7.0",
            body: body,
            forProject: project
        )
        return response.value?.first
    }

    /// Fetch a single commit by SHA from a repository.
    public func getCommit(repositoryId: String, commitId: String, project: String? = nil) async throws -> GitCommitRef {
        let encodedRepoId = repositoryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryId
        let encodedCommit = commitId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? commitId
        return try await request(
            "GET",
            path: "/_apis/git/repositories/\(encodedRepoId)/commits/\(encodedCommit)?api-version=7.0",
            forProject: project
        )
    }

    /// Fetch a single pull request by ID.
    public func getPullRequest(repositoryId: String, pullRequestId: Int, project: String? = nil) async throws -> GitPullRequest {
        let encodedRepoId = repositoryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryId
        return try await request(
            "GET",
            path: "/_apis/git/repositories/\(encodedRepoId)/pullrequests/\(pullRequestId)?api-version=7.0",
            forProject: project
        )
    }

    /// Fetch a single pull request by ID (project-scoped, no repo ID needed).
    public func getPullRequestById(_ pullRequestId: Int, project: String? = nil) async throws -> GitPullRequest {
        return try await request(
            "GET",
            path: "/_apis/git/pullrequests/\(pullRequestId)?api-version=7.0",
            forProject: project
        )
    }

    // MARK: - PR detail (in-app viewer)

    /// Everything the in-app viewer needs: description, commits, comment
    /// threads and per-file red/green diffs. Azure DevOps has no unified-diff
    /// endpoint, so file diffs are computed client-side from the blob contents
    /// at the PR's last merged source/target commits.
    public func getPullRequestDetail(
        repository: String,
        pullRequestId: Int,
        project: String? = nil
    ) async throws -> PullRequestDetail {
        let repo = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository
        let prBase = "/_apis/git/repositories/\(repo)/pullRequests/\(pullRequestId)"

        let head: AzdoPrHead = try await request("GET", path: "\(prBase)?api-version=7.0", forProject: project)
        let commits: AzdoPrCommitsResponse = try await request("GET", path: "\(prBase)/commits?api-version=7.0", forProject: project)
        let threads: AzdoPrThreadsFull = try await request("GET", path: "\(prBase)/threads?api-version=7.0", forProject: project)

        var files: [DiffFile] = []
        var truncated = false
        if let source = head.lastMergeSourceCommit?.commitId,
           let target = head.lastMergeTargetCommit?.commitId {
            let iterations: AzdoPrIterationsResponse = try await request(
                "GET", path: "\(prBase)/iterations?api-version=7.0", forProject: project
            )
            if let latest = iterations.value.map(\.id).max() {
                let changes: AzdoPrChangesResponse = try await request(
                    "GET",
                    path: "\(prBase)/iterations/\(latest)/changes?api-version=7.0&$compareTo=0",
                    forProject: project
                )
                let fileCap = 40
                let entries = changes.changeEntries ?? []
                truncated = entries.count > fileCap
                for entry in entries.prefix(fileCap) {
                    guard let path = entry.item?.path, entry.item?.isFolder != true else { continue }
                    let changeType = (entry.changeType ?? "").lowercased()
                    let old = changeType.contains("add")
                        ? "" : await itemContent(repo: repo, path: path, commit: target, project: project)
                    let new = changeType.contains("delete")
                        ? "" : await itemContent(repo: repo, path: path, commit: source, project: project)
                    guard old != nil || new != nil else { continue }
                    var file = DiffBuilder.build(
                        fileName: path.hasPrefix("/") ? String(path.dropFirst()) : path,
                        old: old ?? "",
                        new: new ?? ""
                    )
                    if changeType.contains("delete") { file.newPath = "/dev/null" }
                    files.append(file)
                }
            }
        }

        let comments: [PullRequestComment] = threads.value
            .filter { $0.isDeleted != true }
            .flatMap { thread in
                (thread.comments ?? [])
                    .filter { !($0.content ?? "").isEmpty }
                    .map { comment in
                        PullRequestComment(
                            id: "\(thread.id)-\(comment.id ?? 0)",
                            authorName: comment.author?.displayName ?? "unknown",
                            body: comment.content ?? "",
                            date: PullRequestDateParser.parse(comment.publishedDate),
                            isSystem: comment.commentType == "system"
                        )
                    }
            }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        return PullRequestDetail(
            body: head.description,
            commits: commits.value.map {
                PullRequestCommit(
                    id: $0.commitId,
                    message: $0.comment ?? "",
                    authorName: $0.author?.name,
                    date: PullRequestDateParser.parse($0.author?.date)
                )
            },
            comments: comments,
            files: files,
            truncated: truncated
        )
    }

    /// Text content of one file at one commit, or nil for binary/oversized/
    /// missing. Failures degrade to nil — a single unreadable file shouldn't
    /// sink the whole diff.
    private func itemContent(repo: String, path: String, commit: String, project: String?) async -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/._-")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        do {
            let item: AzdoItemContent = try await request(
                "GET",
                path: "/_apis/git/repositories/\(repo)/items?path=\(encodedPath)&versionDescriptor.versionType=commit&versionDescriptor.version=\(commit)&includeContent=true&$format=json&api-version=7.0",
                forProject: project
            )
            guard let content = item.content, content.count < 400_000 else { return nil }
            return content
        } catch {
            return nil
        }
    }

    private struct AzdoPrHead: Decodable {
        let description: String?
        let lastMergeSourceCommit: AzdoCommitPointer?
        let lastMergeTargetCommit: AzdoCommitPointer?
    }

    private struct AzdoCommitPointer: Decodable {
        let commitId: String?
    }

    private struct AzdoPrCommitsResponse: Decodable {
        let value: [AzdoPrCommit]
    }

    private struct AzdoPrCommit: Decodable {
        let commitId: String
        let comment: String?
        let author: AzdoSignature?
    }

    private struct AzdoSignature: Decodable {
        let name: String?
        let date: String?
    }

    private struct AzdoPrIterationsResponse: Decodable {
        let value: [AzdoPrIteration]
    }

    private struct AzdoPrIteration: Decodable {
        let id: Int
    }

    private struct AzdoPrChangesResponse: Decodable {
        let changeEntries: [AzdoPrChangeEntry]?
    }

    private struct AzdoPrChangeEntry: Decodable {
        let changeType: String?
        let item: AzdoChangeItem?
    }

    private struct AzdoChangeItem: Decodable {
        let path: String?
        let isFolder: Bool?
    }

    private struct AzdoItemContent: Decodable {
        let content: String?
    }

    private struct AzdoPrThreadsFull: Decodable {
        let value: [AzdoPrThread]
    }

    private struct AzdoPrThread: Decodable {
        let id: Int
        let isDeleted: Bool?
        let comments: [AzdoPrThreadComment]?
    }

    private struct AzdoPrThreadComment: Decodable {
        let id: Int?
        let content: String?
        let commentType: String?
        let publishedDate: String?
        let author: AzdoCommentAuthor?
    }

    private struct AzdoCommentAuthor: Decodable {
        let displayName: String?
    }

    /// Abandon a pull request.
    ///
    /// Reversible in Azure DevOps — an abandoned PR can be reactivated — but it
    /// notifies reviewers, so the UI confirms first.
    @discardableResult
    public func abandonPullRequest(
        repository: String,
        pullRequestId: Int,
        project: String? = nil
    ) async throws -> GitPullRequest {
        dbg.info("AzDO abandonPullRequest(\(repository)#\(pullRequestId))", category: "azdo")
        let encodedRepo = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository
        let body = try JSONSerialization.data(withJSONObject: ["status": "abandoned"])
        return try await request(
            "PATCH",
            path: "/_apis/git/repositories/\(encodedRepo)/pullrequests/\(pullRequestId)?api-version=7.0",
            body: body,
            forProject: project
        )
    }

    /// Complete (merge) a pull request.
    ///
    /// Two calls: Azure DevOps requires `lastMergeSourceCommit` to be echoed back
    /// on completion, and rejects the request if the source branch has moved
    /// since — so the current value has to be read immediately beforehand.
    ///
    /// `completionOptions` is deliberately omitted. The PR already carries the
    /// merge strategy and delete-source-branch settings chosen when it was
    /// opened, and sending our own would silently override branch policy.
    @discardableResult
    public func completePullRequest(
        repository: String,
        pullRequestId: Int,
        project: String? = nil
    ) async throws -> GitPullRequest {
        dbg.info("AzDO completePullRequest(\(repository)#\(pullRequestId))", category: "azdo")
        let encodedRepo = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository
        let path = "/_apis/git/repositories/\(encodedRepo)/pullrequests/\(pullRequestId)?api-version=7.0"

        let current: GitPullRequest = try await request("GET", path: path, forProject: project)
        guard let commitId = current.lastMergeSourceCommit?.commitId else {
            throw AzDevOpsError.httpError(
                code: 409,
                message: "Azure DevOps has not produced a merge commit for this pull request yet. "
                    + "This usually means it still has conflicts or the merge is still being evaluated."
            )
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "lastMergeSourceCommit": ["commitId": commitId]
        ])
        return try await request("PATCH", path: path, body: body, forProject: project)
    }

    /// List recent commits for a repository (optionally filtered by branch).
    public func getCommits(repositoryId: String, branch: String? = nil, top: Int = 20, project: String? = nil) async throws -> [GitCommitRef] {
        dbg.info("AzDO getCommits(\(repositoryId))", category: "azdo")
        let encodedRepoId = repositoryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryId
        var path = "/_apis/git/repositories/\(encodedRepoId)/commits?$top=\(top)&api-version=7.0"
        if let branch = branch {
            let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
            path += "&searchCriteria.itemVersion.version=\(encodedBranch)"
        }
        let response: GitCommitsResponse = try await request(
            "GET",
            path: path,
            forProject: project
        )
        return response.value ?? []
    }

    /// List pull requests for a repository.
    public func getPullRequests(repositoryId: String, status: String = "all", top: Int = 20, project: String? = nil) async throws -> [GitPullRequest] {
        dbg.info("AzDO getPullRequests(\(repositoryId))", category: "azdo")
        let encodedRepoId = repositoryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryId
        let response: GitPullRequestsResponse = try await request(
            "GET",
            path: "/_apis/git/repositories/\(encodedRepoId)/pullrequests?searchCriteria.status=\(status)&$top=\(top)&api-version=7.0",
            forProject: project
        )
        return response.value ?? []
    }

    // MARK: - My Pull Requests (organization-wide)

    /// Resolve the signed-in user's Azure DevOps identity. Azure DevOps pull
    /// request search criteria key off the identity GUID, not the UPN.
    public func getConnectionData() async throws -> DevOpsConnectionData {
        try await request("GET", path: "/_apis/connectionData?api-version=7.1-preview", orgLevel: true)
    }

    /// Cached identity of the signed-in user. Returns nils if it cannot be resolved,
    /// which pushes `getMyPullRequests` onto its client-side matching fallback.
    public func currentIdentity() async -> DevOpsIdentitySummary {
        if let cached = identityCache { return cached }
        do {
            let data = try await getConnectionData()
            let identity = data.authorizedUser ?? data.authenticatedUser
            let summary = DevOpsIdentitySummary(
                id: identity?.id,
                displayName: identity?.displayName,
                account: identity?.accountName
            )
            dbg.info("AzDO identity: id=\(summary.id ?? "nil") account=\(summary.account ?? "nil")", category: "azdo")
            identityCache = summary
            return summary
        } catch {
            dbg.error("AzDO connectionData failed: \(error)", category: "azdo")
            return DevOpsIdentitySummary(id: nil, displayName: nil, account: nil)
        }
    }

    /// The signed-in user's pull requests across **every project** in the
    /// organization, split into "Created by me" and "Assigned to me" the same way
    /// the Azure DevOps web queue does.
    ///
    /// - Parameters:
    ///   - status: `active`, `completed`, `abandoned`, or `all`.
    ///   - topPerQuery: Page size per project query.
    ///   - includeCommentCounts: Fetch each PR's comment threads. One extra
    ///     request per PR, issued concurrently; skip it for a faster first paint.
    public func getMyPullRequests(
        status: String = "active",
        topPerQuery: Int = 100,
        includeCommentCounts: Bool = true
    ) async throws -> PullRequestQueue {
        let identity = await currentIdentity()
        let projects = try await listProjects()
        dbg.info("AzDO getMyPullRequests across \(projects.count) projects (identity=\(identity.id ?? "unresolved"))", category: "azdo")

        var queue = PullRequestQueue()

        // Fan out per project — each project is an independent REST call.
        let perProject = await withTaskGroup(of: [UnifiedPullRequest].self) { group in
            for project in projects {
                group.addTask {
                    await self.pullRequestsForProject(project.name, identity: identity, status: status, top: topPerQuery)
                }
            }
            var all: [UnifiedPullRequest] = []
            for await result in group { all.append(contentsOf: result) }
            return all
        }

        for pr in perProject { queue.insert(pr) }

        if includeCommentCounts, !queue.pullRequests.isEmpty {
            queue.pullRequests = await withThreadActivity(queue.pullRequests)
        }

        dbg.info("AzDO getMyPullRequests → \(queue.pullRequests.count) PRs", category: "azdo")
        return queue
    }

    /// Fetch one project's slice of the queue. Never throws — a project the user
    /// cannot read should not sink the whole queue.
    private func pullRequestsForProject(
        _ projectName: String,
        identity: DevOpsIdentitySummary,
        status: String,
        top: Int
    ) async -> [UnifiedPullRequest] {
        var byId: [Int: UnifiedPullRequest] = [:]

        func absorb(_ prs: [GitPullRequest], relation: PullRequestRelation) {
            for pr in prs {
                guard let unified = mapPullRequest(pr, project: projectName, relation: relation) else { continue }
                if var existing = byId[pr.pullRequestId] {
                    existing.relations.insert(relation)
                    byId[pr.pullRequestId] = existing
                } else {
                    byId[pr.pullRequestId] = unified
                }
            }
        }

        if let identityId = identity.id, !identityId.isEmpty {
            let encodedId = identityId.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? identityId
            async let created = fetchProjectPullRequests(projectName, criteria: "&searchCriteria.creatorId=\(encodedId)", status: status, top: top)
            async let reviewing = fetchProjectPullRequests(projectName, criteria: "&searchCriteria.reviewerId=\(encodedId)", status: status, top: top)
            absorb(await created, relation: .createdByMe)
            absorb(await reviewing, relation: .assignedToMe)
        } else {
            // Identity GUID unavailable — pull the project's PRs and match on the
            // account name we do know.
            let all = await fetchProjectPullRequests(projectName, criteria: "", status: status, top: top)
            let mine = all.filter { matchesMe($0.createdBy, identity: identity) }
            let reviewing = all.filter { pr in
                (pr.reviewers ?? []).contains { reviewer in
                    reviewer.isContainer != true && matchesReviewer(reviewer, identity: identity)
                }
            }
            absorb(mine, relation: .createdByMe)
            absorb(reviewing, relation: .assignedToMe)
        }

        return Array(byId.values)
    }

    /// One PR search against one project. Swallows failures — a project the user
    /// cannot read should not sink the whole queue.
    private func fetchProjectPullRequests(
        _ projectName: String,
        criteria: String,
        status: String,
        top: Int
    ) async -> [GitPullRequest] {
        let encodedProject = projectName.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? projectName
        do {
            let response: GitPullRequestsResponse = try await request(
                "GET",
                path: "/_apis/git/pullrequests?searchCriteria.status=\(status)\(criteria)&$top=\(top)&api-version=7.0",
                forProject: encodedProject
            )
            return response.value ?? []
        } catch {
            dbg.debug("AzDO PR query failed for \(projectName): \(error)", category: "azdo")
            return []
        }
    }

    private func matchesMe(_ ref: IdentityRef?, identity: DevOpsIdentitySummary) -> Bool {
        guard let ref else { return false }
        if let id = identity.id, let refId = ref.id, id.caseInsensitiveCompare(refId) == .orderedSame { return true }
        if let account = identity.account, let unique = ref.uniqueName,
           account.caseInsensitiveCompare(unique) == .orderedSame { return true }
        if let name = identity.displayName, let display = ref.displayName,
           name.caseInsensitiveCompare(display) == .orderedSame { return true }
        return false
    }

    private func matchesReviewer(_ reviewer: GitPullRequestReviewer, identity: DevOpsIdentitySummary) -> Bool {
        matchesMe(IdentityRef(displayName: reviewer.displayName, uniqueName: reviewer.uniqueName, id: reviewer.id), identity: identity)
    }

    /// Convert an Azure DevOps PR into the unified shape. Returns nil if the
    /// payload is missing the repository context needed to build a web URL.
    private func mapPullRequest(_ pr: GitPullRequest, project: String, relation: PullRequestRelation) -> UnifiedPullRequest? {
        guard let repo = pr.repository?.name else { return nil }
        let projectName = pr.repository?.project?.name ?? project

        let state: PullRequestState
        if pr.isDraft == true {
            state = .draft
        } else {
            switch pr.status?.lowercased() {
            case "completed":  state = .merged
            case "abandoned":  state = .closed
            default:           state = .open
            }
        }

        let reviewers: [PullRequestReviewer] = (pr.reviewers ?? [])
            .filter { $0.isContainer != true }
            .map {
                PullRequestReviewer(
                    id: $0.id ?? $0.displayName ?? UUID().uuidString,
                    displayName: $0.displayName ?? $0.uniqueName ?? "Unknown",
                    vote: .fromAzureDevOps($0.vote),
                    isRequired: $0.isRequired ?? false
                )
            }

        return UnifiedPullRequest(
            source: .azureDevOps,
            number: pr.pullRequestId,
            title: pr.title ?? "(untitled)",
            authorName: pr.createdBy?.displayName ?? pr.createdBy?.uniqueName ?? "Unknown",
            container: projectName,
            repository: repo,
            sourceBranch: pr.sourceBranch ?? "",
            targetBranch: pr.targetBranch ?? "",
            createdAt: PullRequestDateParser.parse(pr.creationDate),
            updatedAt: PullRequestDateParser.parse(pr.closedDate), // refined by thread enrichment
            state: state,
            hasConflicts: pr.hasConflicts,
            reviewers: reviewers,
            webUrl: Self.pullRequestWebUrl(orgUrl: orgUrl, project: projectName, repository: repo, pullRequestId: pr.pullRequestId),
            relations: [relation]
        )
    }

    /// Comment threads carry both the count the queue displays and the only
    /// "last touched" signal the PR list endpoint omits. One concurrent request
    /// per PR fills in both.
    private func withThreadActivity(_ prs: [UnifiedPullRequest]) async -> [UnifiedPullRequest] {
        let summaries = await withTaskGroup(of: (String, ThreadActivity)?.self) { group in
            for pr in prs where pr.source == .azureDevOps {
                group.addTask {
                    guard let activity = await self.threadActivity(pr) else { return nil }
                    return (pr.id, activity)
                }
            }
            var collected: [String: ThreadActivity] = [:]
            for await result in group {
                if let (id, activity) = result { collected[id] = activity }
            }
            return collected
        }

        return prs.map { pr in
            guard let activity = summaries[pr.id] else { return pr }
            var enriched = pr
            enriched.commentCount = activity.commentThreadCount
            enriched.updatedAt = activity.lastActivity
            return enriched
        }
    }

    private struct ThreadActivity {
        let commentThreadCount: Int
        let lastActivity: Date?
    }

    /// Human comment threads on a PR and when they were last touched. System
    /// threads (the "added reviewer", "updated branch" noise) are excluded, which
    /// is what makes the count match the one Azure DevOps shows in its queue.
    private func threadActivity(_ pr: UnifiedPullRequest) async -> ThreadActivity? {
        let encodedProject = pr.container.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? pr.container
        let encodedRepo = pr.repository.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? pr.repository
        do {
            let response: GitPullRequestThreadsResponse = try await request(
                "GET",
                path: "/_apis/git/repositories/\(encodedRepo)/pullRequests/\(pr.number)/threads?api-version=7.0",
                forProject: encodedProject
            )
            let threads = (response.value ?? []).filter { $0.isDeleted != true }

            let commentThreads = threads.filter { thread in
                (thread.comments ?? []).contains {
                    $0.isDeleted != true && ($0.commentType ?? "text").lowercased() != "system"
                }
            }

            // Every thread counts toward "last touched", including system ones —
            // a pushed commit or a reviewer change is real activity.
            let lastActivity = threads
                .compactMap { PullRequestDateParser.parse($0.lastUpdatedDate ?? $0.publishedDate) }
                .max()

            return ThreadActivity(commentThreadCount: commentThreads.count, lastActivity: lastActivity)
        } catch {
            return nil
        }
    }

    /// Web URL for a pull request, e.g.
    /// `https://azure-devops.example.com/org/Devices/_git/ReportMate/pullrequest/10716`.
    public static func pullRequestWebUrl(orgUrl: String, project: String, repository: String, pullRequestId: Int) -> String {
        let encodedProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        let encodedRepo = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository
        return "\(orgUrl)/\(encodedProject)/_git/\(encodedRepo)/pullrequest/\(pullRequestId)"
    }

    /// Add an artifact link (commit, branch, PR, etc.) to a work item using JSON Patch.
    /// - Parameters:
    ///   - workItemId: The work item ID.
    ///   - artifactUri: The `vstfs:///` URI for the artifact.
    ///   - linkName: Display name for the link (e.g., "Fixed in Commit").
    ///   - comment: Optional comment for the link.
    public func addWorkItemArtifactLink(workItemId: Int, artifactUri: String, linkName: String, comment: String? = nil) async throws -> WorkItem? {
        dbg.info("AzDO addWorkItemArtifactLink(\(workItemId)) → \(artifactUri)", category: "azdo")

        var attributes: [String: Any] = ["name": linkName]
        if let comment = comment {
            attributes["comment"] = comment
        }

        let ops: [[String: Any]] = [
            [
                "op": "add",
                "path": "/relations/-",
                "value": [
                    "rel": "ArtifactLink",
                    "url": artifactUri,
                    "attributes": attributes
                ] as [String: Any]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: ops)
        let item: WorkItem = try await request(
            "PATCH",
            path: "/_apis/wit/workitems/\(workItemId)?api-version=7.0",
            body: body,
            contentType: "application/json-patch+json",
            orgLevel: true
        )
        return item
    }

    /// Build an AzDO artifact URI for a Git commit.
    public static func commitArtifactUri(projectId: String, repositoryId: String, commitId: String) -> String {
        "vstfs:///Git/Commit/\(projectId)%2F\(repositoryId)%2F\(commitId)"
    }

    /// Build an AzDO artifact URI for a Git branch (ref).
    public static func branchArtifactUri(projectId: String, repositoryId: String, branchName: String) -> String {
        let encodedBranch = "GB\(branchName)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "GB\(branchName)"
        return "vstfs:///Git/Ref/\(projectId)%2F\(repositoryId)%2F\(encodedBranch)"
    }

    /// Build an AzDO artifact URI for a Pull Request.
    public static func pullRequestArtifactUri(projectId: String, repositoryId: String, pullRequestId: Int) -> String {
        "vstfs:///Git/PullRequestId/\(projectId)%2F\(repositoryId)%2F\(pullRequestId)"
    }
}

// MARK: - Error

public enum AzDevOpsError: Error, LocalizedError {
    case notLoggedIn
    case forbidden(message: String)
    case httpError(code: Int, message: String)
    case invalidUrl(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .forbidden:
            return "Azure DevOps denied access to this item. Your sign-in is valid but lacks permission for it."
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
