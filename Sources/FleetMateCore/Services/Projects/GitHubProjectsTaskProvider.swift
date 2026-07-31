import Foundation

/// Task provider backed by GitHub Projects v2.
/// Replaces the old GitHubTaskProvider (Issues-only REST) with full Projects v2 GraphQL support.
/// Maps project items (Issues, PRs, Draft Issues) to UnifiedTask using the project's Status field
/// for state mapping, and status columns as TaskBuckets.
public actor GitHubProjectsTaskProvider: TaskProvider {
    public let providerId = "github"
    public let providerName = "GitHub Projects"
    public var isEnabled: Bool { config.enabled }

    private let config: GitHubProviderConfig
    private let service: GitHubProjectsService
    /// For the issues fallback when no Projects v2 board is configured.
    private let searchClient: GitHubGraphQLClient
    private var projectId: String?
    private var statusField: GitHubProjectField?
    private var fields: [GitHubProjectField]?

    public init(config: GitHubProviderConfig) {
        self.config = config
        self.service = GitHubProjectsService(config: config)
        self.searchClient = GitHubGraphQLClient(config: config)
    }

    public func authenticate() async throws -> Bool {
        dbg.info("GitHub TaskProvider authenticate() (enabled=\(isEnabled), org=\(config.organization ?? "nil"), owner=\(config.owner ?? "nil"), repo=\(config.repo ?? "nil"))", category: "github-provider")
        guard try await service.authenticate() else {
            dbg.warn("GitHub TaskProvider: service.authenticate() failed", category: "github-provider")
            return false
        }
        try? await resolveProject()
        dbg.info("GitHub TaskProvider: projectId=\(projectId ?? "nil") (nil → issues fallback)", category: "github-provider")
        return true
    }

    public func listTasks(filter: TaskFilter?) async throws -> [UnifiedTask] {
        dbg.info("GitHub TaskProvider listTasks", category: "github-provider")
        // No Projects v2 board configured? Fall back to the account's issues —
        // an empty board when your issues are one search away helps nobody.
        if (try? await ensureProject()) == nil || projectId == nil {
            var tasks = try await searchMyIssues(
                limit: filter?.limit ?? 100,
                includeClosed: filter?.includeClosed ?? false
            )
            if let search = filter?.searchText, !search.isEmpty {
                let q = search.lowercased()
                tasks = tasks.filter {
                    $0.title.lowercased().contains(q) ||
                    ($0.description?.lowercased().contains(q) ?? false)
                }
            }
            dbg.info("GitHub TaskProvider: \(tasks.count) issues via fallback search", category: "github-provider")
            return tasks
        }

        let limit = filter?.limit ?? 100
        let items = try await service.listProjectItems(projectId: projectId!, limit: limit)
        dbg.info("GitHub TaskProvider: \(items.count) project items fetched", category: "github-provider")

        var tasks = items.compactMap { itemToUnifiedTask($0) }

        if let filter = filter {
            if let states = filter.states, !states.isEmpty {
                tasks = tasks.filter { states.contains($0.state) }
            }
            if !filter.includeClosed {
                tasks = tasks.filter { $0.state != .closed }
            }
            if let assignees = filter.assignees, !assignees.isEmpty {
                tasks = tasks.filter { t in
                    t.assignees.contains { a in assignees.contains(where: { $0.lowercased() == a.lowercased() }) }
                }
            }
            if let labels = filter.labels, !labels.isEmpty {
                tasks = tasks.filter { t in
                    t.labels.contains { l in labels.contains(where: { $0.lowercased() == l.lowercased() }) }
                }
            }
            if let bucket = filter.bucket, !bucket.isEmpty {
                tasks = tasks.filter { $0.bucket?.lowercased() == bucket.lowercased() }
            }
            if let search = filter.searchText, !search.isEmpty {
                let q = search.lowercased()
                tasks = tasks.filter {
                    $0.title.lowercased().contains(q) ||
                    ($0.description?.lowercased().contains(q) ?? false)
                }
            }
        }

        return tasks
    }

    public func getTask(taskId: String) async throws -> UnifiedTask? {
        let items = try await listTasks(filter: TaskFilter(limit: 200, includeClosed: true))
        return items.first { $0.id == taskId }
    }

    public func createTask(request: CreateTaskRequest) async throws -> UnifiedTask {
        try await ensureProject()

        let itemId = try await service.addDraftItem(
            projectId: projectId!, title: request.title, body: request.description)

        // Move to requested status
        if let bucket = request.bucket, let sf = statusField {
            if let opt = sf.options.first(where: { $0.name.lowercased() == bucket.lowercased() }) {
                try await service.moveItemToStatus(
                    projectId: projectId!, itemId: itemId,
                    statusFieldId: sf.id, optionId: opt.id)
            }
        }

        return UnifiedTask(
            id: itemId, provider: providerId, title: request.title,
            description: request.description,
            state: mapBucketToState(request.bucket),
            assignees: request.assignees ?? [],
            labels: request.labels ?? [],
            bucket: request.bucket,
            priority: request.priority
        )
    }

    public func updateTask(taskId: String, request: UpdateTaskRequest) async throws -> UnifiedTask {
        try await ensureProject()

        // Move to new status if bucket changed
        if let bucket = request.bucket, let sf = statusField {
            if let opt = sf.options.first(where: { $0.name.lowercased() == bucket.lowercased() }) {
                try await service.moveItemToStatus(
                    projectId: projectId!, itemId: taskId,
                    statusFieldId: sf.id, optionId: opt.id)
            }
        }

        // Update title field
        if let title = request.title, let allFields = fields {
            if let titleField = allFields.first(where: { $0.name == "Title" && $0.dataType == "TEXT" }) {
                try await service.updateItemFieldValue(
                    projectId: projectId!, itemId: taskId,
                    fieldId: titleField.id, value: ["text": title])
            }
        }

        return try await getTask(taskId: taskId) ?? UnifiedTask(
            id: taskId, provider: providerId,
            title: request.title ?? "",
            state: request.state ?? .open
        )
    }

    public func deleteTask(taskId: String) async throws -> Bool {
        try await ensureProject()
        do {
            try await service.deleteItem(projectId: projectId!, itemId: taskId)
            return true
        } catch {
            print("GitHub Projects: Failed to delete item \(taskId): \(error)")
            return false
        }
    }

    public func listBuckets() async throws -> [TaskBucket] {
        guard (try? await ensureProject()) != nil, projectId != nil else {
            return [TaskBucket(id: "open", name: "Open", order: 0),
                    TaskBucket(id: "closed", name: "Closed", order: 1)]
        }
        guard let sf = statusField else { return [] }

        return sf.options.enumerated().map { i, opt in
            TaskBucket(id: opt.id, name: opt.name, order: i)
        }
    }

    public func listLabels() async throws -> [TaskLabel] {
        guard (try? await ensureProject()) != nil, projectId != nil else { return [] }
        let items = try await service.listProjectItems(projectId: projectId!, limit: 200)

        let labelNames = Set(items.compactMap(\.content).flatMap(\.labels))
        return labelNames.sorted().map { TaskLabel(name: $0) }
    }

    // MARK: - Project Resolution

    private func ensureProject() async throws {
        if projectId != nil { return }
        try await resolveProject()
        guard projectId != nil else {
            throw TaskProviderError.notConfigured
        }
    }

    private func resolveProject() async throws {
        let scope = parseScope(config.projectScope)
        let owner = config.organization ?? config.owner ?? ""

        if let num = config.projectNumber {
            let project = try await service.getProject(
                scope: scope, owner: owner, projectNumber: num, repo: config.repo)
            if let project = project {
                projectId = project.id
                print("GitHub Projects: Resolved project #\(project.number) '\(project.title)'")
            }
        } else {
            let projects = try await service.listProjects(
                scope: scope, owner: owner, repo: config.repo, limit: 1)
            if let first = projects.first {
                projectId = first.id
                print("GitHub Projects: Using first project #\(first.number) '\(first.title)'")
            }
        }

        if let pid = projectId {
            fields = try await service.listProjectFields(projectId: pid)
            statusField = fields?.first {
                $0.name.lowercased() == "status" && $0.dataType == "SINGLE_SELECT"
            }
        }
    }

    // MARK: - Issues fallback (no Projects v2 board)

    /// Open issues involving the signed-in account, shaped as tasks. The full
    /// issue sidebar works off `externalUrl`, so these are first-class rows.
    private func searchMyIssues(limit: Int, includeClosed: Bool) async throws -> [UnifiedTask] {
        let q = "is:issue involves:@me sort:updated-desc" + (includeClosed ? "" : " is:open")
        let query = """
        query($q: String!, $first: Int!) {
          search(query: $q, type: ISSUE, first: $first) {
            nodes {
              ... on Issue {
                id title body url state createdAt updatedAt closedAt
                assignees(first: 10) { nodes { login } }
                labels(first: 20) { nodes { name } }
              }
            }
          }
        }
        """
        let data = try await searchClient.executeRaw(query: query, variables: ["q": q, "first": limit])
        let nodes = (data["search"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        return nodes.compactMap { node -> UnifiedTask? in
            guard let id = node["id"] as? String,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else { return nil }
            let state: TaskState = (node["state"] as? String)?.uppercased() == "CLOSED" ? .closed : .open
            let assignees = ((node["assignees"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { $0["login"] as? String } ?? []
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            func date(_ key: String) -> Date? {
                (node[key] as? String).flatMap { iso.date(from: $0) }
            }
            return UnifiedTask(
                id: id, provider: providerId, title: title,
                description: node["body"] as? String, state: state,
                assignees: assignees, labels: labels,
                bucket: state == .closed ? "Closed" : "Open",
                createdAt: date("createdAt") ?? Date(), updatedAt: date("updatedAt") ?? Date(), closedAt: date("closedAt"),
                externalUrl: url, priority: nil
            )
        }
    }

    // MARK: - Mapping

    private func itemToUnifiedTask(_ item: GitHubProjectItem) -> UnifiedTask? {
        let title: String
        var description: String? = nil
        var externalUrl: String? = nil
        var assignees: [String] = []
        var labels: [String] = []
        var createdAt = item.createdAt
        var updatedAt = item.updatedAt
        var closedAt: Date? = nil

        if let content = item.content {
            title = content.title
            description = content.body
            externalUrl = content.url
            assignees = content.assignees
            labels = content.labels
            createdAt = content.createdAt
            updatedAt = content.updatedAt
            closedAt = content.closedAt
        } else if let draft = item.draftContent {
            title = draft.title
            description = draft.body
        } else if item.type == "REDACTED" {
            return nil
        } else {
            return nil
        }

        let statusFv = item.fieldValues.first {
            $0.fieldName.lowercased() == "status"
        }
        let bucket = statusFv?.singleSelectValue
        let state = Self.mapStatusToState(statusFv?.singleSelectValue, contentState: item.content?.state)

        // Priority mapping
        var priority: Int? = nil
        let priorityFv = item.fieldValues.first {
            $0.fieldName.lowercased() == "priority" || $0.fieldName.lowercased() == "p"
        }
        if let name = priorityFv?.singleSelectValue?.lowercased() {
            switch name {
            case "p0", "urgent", "critical": priority = 1
            case "p1", "high": priority = 2
            case "p2", "medium", "normal": priority = 3
            case "p3", "low": priority = 4
            default: break
            }
        } else if let num = priorityFv?.numberValue {
            priority = Int(num)
        }

        return UnifiedTask(
            id: item.id, provider: providerId, title: title,
            description: description, state: state,
            assignees: assignees, labels: labels, bucket: bucket,
            createdAt: createdAt, updatedAt: updatedAt, closedAt: closedAt,
            externalUrl: externalUrl, priority: priority
        )
    }

    private static func mapStatusToState(_ statusName: String?, contentState: String?) -> TaskState {
        if let name = statusName?.lowercased() {
            if name.contains("done") || name.contains("closed") || name.contains("complete") || name.contains("merged") {
                return .closed
            }
            if name.contains("progress") || name.contains("active") || name.contains("review") || name.contains("doing") {
                return .inProgress
            }
            return .open
        }

        switch contentState?.uppercased() {
        case "CLOSED", "MERGED": return .closed
        default: return .open
        }
    }

    private func mapBucketToState(_ bucket: String?) -> TaskState {
        guard let bucket = bucket else { return .open }
        return Self.mapStatusToState(bucket, contentState: nil)
    }

    private func parseScope(_ scope: String) -> ProjectScope {
        switch scope.lowercased() {
        case "user": return .user
        case "repository", "repo": return .repository
        default: return .organization
        }
    }
}
