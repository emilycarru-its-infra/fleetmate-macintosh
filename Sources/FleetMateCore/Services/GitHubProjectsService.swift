import Foundation
import Alamofire

/// Service for interacting with GitHub Projects v2 via the GraphQL API.
/// Supports organization, user, and repository-level projects.
public actor GitHubProjectsService {
    private let client: GitHubGraphQLClient
    private let config: GitHubProviderConfig

    public init(config: GitHubProviderConfig) {
        self.config = config
        self.client = GitHubGraphQLClient(config: config)
    }

    public func authenticate() async throws -> Bool {
        try await client.authenticate()
    }

    // MARK: - Projects

    /// Lists projects v2 for the configured scope (org, user, or repo).
    public func listProjects(
        scope: ProjectScope, owner: String, repo: String? = nil,
        includeClosed: Bool = false, limit: Int = 20
    ) async throws -> [GitHubProject] {
        let query: String
        var vars: [String: Any]

        switch scope {
        case .organization:
            query = """
                query($login: String!, $first: Int!, $after: String) {
                    organization(login: $login) {
                        projectsV2(first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
                            nodes {
                                id number title shortDescription url closed public
                                createdAt updatedAt closedAt
                            }
                            pageInfo { hasNextPage endCursor }
                        }
                    }
                }
                """
            vars = ["login": owner, "first": limit]
        case .user:
            query = """
                query($login: String!, $first: Int!, $after: String) {
                    user(login: $login) {
                        projectsV2(first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
                            nodes {
                                id number title shortDescription url closed public
                                createdAt updatedAt closedAt
                            }
                            pageInfo { hasNextPage endCursor }
                        }
                    }
                }
                """
            vars = ["login": owner, "first": limit]
        case .repository:
            guard let repo = repo else {
                throw GitHubGraphQLError.graphQLError("Repository name required for repository scope")
            }
            query = """
                query($owner: String!, $name: String!, $first: Int!, $after: String) {
                    repository(owner: $owner, name: $name) {
                        projectsV2(first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
                            nodes {
                                id number title shortDescription url closed public
                                createdAt updatedAt closedAt
                            }
                            pageInfo { hasNextPage endCursor }
                        }
                    }
                }
                """
            vars = ["owner": owner, "name": repo, "first": limit]
        }

        let data = try await client.executeRaw(query: query, variables: vars)

        let rootKey: String
        switch scope {
        case .organization: rootKey = "organization"
        case .user: rootKey = "user"
        case .repository: rootKey = "repository"
        }

        guard let root = data[rootKey] as? [String: Any],
              let projectsV2 = root["projectsV2"] as? [String: Any] else {
            return []
        }

        var projects = Self.parseProjects(projectsV2)
        if !includeClosed {
            projects = projects.filter { !$0.closed }
        }
        return projects
    }

    /// Gets a single project by number.
    public func getProject(
        scope: ProjectScope, owner: String, projectNumber: Int, repo: String? = nil
    ) async throws -> GitHubProject? {
        let query: String
        var vars: [String: Any] = ["number": projectNumber]

        switch scope {
        case .organization:
            query = """
                query($login: String!, $number: Int!) {
                    organization(login: $login) {
                        projectV2(number: $number) {
                            id number title shortDescription url closed public
                            createdAt updatedAt closedAt
                        }
                    }
                }
                """
            vars["login"] = owner
        case .user:
            query = """
                query($login: String!, $number: Int!) {
                    user(login: $login) {
                        projectV2(number: $number) {
                            id number title shortDescription url closed public
                            createdAt updatedAt closedAt
                        }
                    }
                }
                """
            vars["login"] = owner
        case .repository:
            guard let repo = repo else {
                throw GitHubGraphQLError.graphQLError("Repository name required for repository scope")
            }
            query = """
                query($owner: String!, $name: String!, $number: Int!) {
                    repository(owner: $owner, name: $name) {
                        projectV2(number: $number) {
                            id number title shortDescription url closed public
                            createdAt updatedAt closedAt
                        }
                    }
                }
                """
            vars["owner"] = owner
            vars["name"] = repo
        }

        let data = try await client.executeRaw(query: query, variables: vars)

        let rootKey: String
        switch scope {
        case .organization: rootKey = "organization"
        case .user: rootKey = "user"
        case .repository: rootKey = "repository"
        }

        guard let root = data[rootKey] as? [String: Any],
              let projectEl = root["projectV2"] as? [String: Any] else {
            return nil
        }

        return Self.parseProject(projectEl)
    }

    // MARK: - Items

    /// Lists items in a project. Uses the project node ID.
    public func listProjectItems(
        projectId: String, limit: Int = 100, includeArchived: Bool = false
    ) async throws -> [GitHubProjectItem] {
        let query = """
            query($projectId: ID!, $first: Int!, $after: String) {
                node(id: $projectId) {
                    ... on ProjectV2 {
                        items(first: $first, after: $after) {
                            nodes {
                                id type createdAt updatedAt isArchived
                                content {
                                    ... on Issue {
                                        id number title body state url
                                        createdAt updatedAt closedAt
                                        assignees(first: 10) { nodes { login } }
                                        labels(first: 20) { nodes { name } }
                                        repository { nameWithOwner }
                                    }
                                    ... on PullRequest {
                                        id number title body state url
                                        createdAt updatedAt closedAt
                                        assignees(first: 10) { nodes { login } }
                                        labels(first: 20) { nodes { name } }
                                        repository { nameWithOwner }
                                    }
                                    ... on DraftIssue {
                                        title body
                                    }
                                }
                                fieldValues(first: 20) {
                                    nodes {
                                        ... on ProjectV2ItemFieldTextValue {
                                            text
                                            field { ... on ProjectV2Field { id name } }
                                        }
                                        ... on ProjectV2ItemFieldNumberValue {
                                            number
                                            field { ... on ProjectV2Field { id name } }
                                        }
                                        ... on ProjectV2ItemFieldDateValue {
                                            date
                                            field { ... on ProjectV2Field { id name } }
                                        }
                                        ... on ProjectV2ItemFieldSingleSelectValue {
                                            name optionId
                                            field { ... on ProjectV2SingleSelectField { id name } }
                                        }
                                        ... on ProjectV2ItemFieldIterationValue {
                                            title iterationId
                                            field { ... on ProjectV2IterationField { id name } }
                                        }
                                    }
                                }
                            }
                            pageInfo { hasNextPage endCursor }
                        }
                    }
                }
            }
            """

        var allItems: [GitHubProjectItem] = []
        var cursor: String? = nil

        while true {
            var vars: [String: Any] = [
                "projectId": projectId,
                "first": min(limit - allItems.count, 100)
            ]
            if let cursor = cursor { vars["after"] = cursor }

            let data = try await client.executeRaw(query: query, variables: vars)

            guard let node = data["node"] as? [String: Any],
                  let items = node["items"] as? [String: Any],
                  let nodes = items["nodes"] as? [[String: Any]] else {
                break
            }

            for itemNode in nodes {
                let item = Self.parseProjectItem(itemNode)
                if !includeArchived && item.isArchived { continue }
                allItems.append(item)
            }

            guard let pageInfo = items["pageInfo"] as? [String: Any],
                  let hasNext = pageInfo["hasNextPage"] as? Bool,
                  hasNext, allItems.count < limit else { break }

            cursor = pageInfo["endCursor"] as? String
        }

        return allItems
    }

    // MARK: - Fields

    /// Lists fields for a project.
    public func listProjectFields(projectId: String) async throws -> [GitHubProjectField] {
        let query = """
            query($projectId: ID!) {
                node(id: $projectId) {
                    ... on ProjectV2 {
                        fields(first: 50) {
                            nodes {
                                ... on ProjectV2Field {
                                    id name dataType
                                }
                                ... on ProjectV2SingleSelectField {
                                    id name dataType
                                    options { id name color description }
                                }
                                ... on ProjectV2IterationField {
                                    id name dataType
                                    configuration {
                                        iterations { id title startDate duration }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            """

        let vars: [String: Any] = ["projectId": projectId]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let node = data["node"] as? [String: Any],
              let fields = node["fields"] as? [String: Any],
              let nodes = fields["nodes"] as? [[String: Any]] else {
            return []
        }

        var result: [GitHubProjectField] = []
        for fieldNode in nodes {
            guard let id = fieldNode["id"] as? String,
                  let name = fieldNode["name"] as? String else { continue }

            let dataType = fieldNode["dataType"] as? String ?? "TEXT"
            var options: [GitHubProjectSelectOption] = []
            var iterations: [GitHubProjectIteration] = []

            if let opts = fieldNode["options"] as? [[String: Any]] {
                for opt in opts {
                    options.append(GitHubProjectSelectOption(
                        id: opt["id"] as? String ?? "",
                        name: opt["name"] as? String ?? "",
                        color: opt["color"] as? String,
                        description: opt["description"] as? String
                    ))
                }
            }

            if let config = fieldNode["configuration"] as? [String: Any],
               let iters = config["iterations"] as? [[String: Any]] {
                for iter in iters {
                    iterations.append(GitHubProjectIteration(
                        id: iter["id"] as? String ?? "",
                        title: iter["title"] as? String ?? "",
                        startDate: iter["startDate"] as? String,
                        duration: iter["duration"] as? Int
                    ))
                }
            }

            result.append(GitHubProjectField(
                id: id, name: name, dataType: dataType,
                options: options, iterations: iterations
            ))
        }

        return result
    }

    /// Gets the Status field (single-select) for a project.
    public func getStatusField(projectId: String) async throws -> GitHubProjectField? {
        let fields = try await listProjectFields(projectId: projectId)
        return fields.first { $0.name.lowercased() == "status" && $0.dataType == "SINGLE_SELECT" }
    }

    // MARK: - Views

    /// Lists views (Board, Table, Roadmap) for a project.
    public func listProjectViews(projectId: String) async throws -> [GitHubProjectView] {
        let query = """
            query($projectId: ID!) {
                node(id: $projectId) {
                    ... on ProjectV2 {
                        views(first: 20) {
                            nodes { id number name layout }
                        }
                    }
                }
            }
            """

        let vars: [String: Any] = ["projectId": projectId]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let node = data["node"] as? [String: Any],
              let views = node["views"] as? [String: Any],
              let nodes = views["nodes"] as? [[String: Any]] else {
            return []
        }

        return nodes.compactMap { v in
            guard let id = v["id"] as? String,
                  let number = v["number"] as? Int,
                  let name = v["name"] as? String,
                  let layout = v["layout"] as? String else { return nil }
            return GitHubProjectView(id: id, number: number, name: name, layout: layout)
        }
    }

    // MARK: - Mutations

    /// Adds an existing issue or PR to a project.
    public func addItemToProject(projectId: String, contentId: String) async throws -> String {
        let mutation = """
            mutation($projectId: ID!, $contentId: ID!) {
                addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
                    item { id }
                }
            }
            """

        let vars: [String: Any] = ["projectId": projectId, "contentId": contentId]
        let data = try await client.executeRaw(query: mutation, variables: vars)

        guard let add = data["addProjectV2ItemById"] as? [String: Any],
              let item = add["item"] as? [String: Any],
              let id = item["id"] as? String else {
            throw GitHubGraphQLError.noData
        }
        return id
    }

    /// Adds a draft issue to a project.
    public func addDraftItem(projectId: String, title: String, body: String? = nil) async throws -> String {
        let mutation = """
            mutation($projectId: ID!, $title: String!, $body: String) {
                addProjectV2DraftIssue(input: { projectId: $projectId, title: $title, body: $body }) {
                    projectItem { id }
                }
            }
            """

        var vars: [String: Any] = ["projectId": projectId, "title": title]
        if let body = body { vars["body"] = body }

        let data = try await client.executeRaw(query: mutation, variables: vars)

        guard let add = data["addProjectV2DraftIssue"] as? [String: Any],
              let item = add["projectItem"] as? [String: Any],
              let id = item["id"] as? String else {
            throw GitHubGraphQLError.noData
        }
        return id
    }

    /// Updates a field value on a project item.
    public func updateItemFieldValue(
        projectId: String, itemId: String, fieldId: String, value: [String: Any]
    ) async throws {
        let mutation = """
            mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
                updateProjectV2ItemFieldValue(input: {
                    projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value
                }) {
                    projectV2Item { id }
                }
            }
            """

        let vars: [String: Any] = [
            "projectId": projectId, "itemId": itemId,
            "fieldId": fieldId, "value": value
        ]
        _ = try await client.executeRaw(query: mutation, variables: vars)
    }

    /// Moves an item to a specific status by setting the status field's single-select value.
    public func moveItemToStatus(
        projectId: String, itemId: String, statusFieldId: String, optionId: String
    ) async throws {
        try await updateItemFieldValue(
            projectId: projectId, itemId: itemId, fieldId: statusFieldId,
            value: ["singleSelectOptionId": optionId]
        )
    }

    /// Removes an item from the project.
    public func deleteItem(projectId: String, itemId: String) async throws {
        let mutation = """
            mutation($projectId: ID!, $itemId: ID!) {
                deleteProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
                    deletedItemId
                }
            }
            """
        let vars: [String: Any] = ["projectId": projectId, "itemId": itemId]
        _ = try await client.executeRaw(query: mutation, variables: vars)
    }

    // MARK: - Issue Creation

    /// Creates a GitHub Issue in a repository via GraphQL.
    /// Returns the issue node ID and number.
    public func createIssue(
        repositoryId: String, title: String, body: String? = nil,
        assigneeIds: [String]? = nil, labelIds: [String]? = nil,
        milestoneId: String? = nil
    ) async throws -> (id: String, number: Int, url: String?) {
        let mutation = """
            mutation($repositoryId: ID!, $title: String!, $body: String, $assigneeIds: [ID!], $labelIds: [ID!], $milestoneId: ID) {
                createIssue(input: {
                    repositoryId: $repositoryId, title: $title, body: $body,
                    assigneeIds: $assigneeIds, labelIds: $labelIds, milestoneId: $milestoneId
                }) {
                    issue { id number url }
                }
            }
            """

        var vars: [String: Any] = ["repositoryId": repositoryId, "title": title]
        if let body = body { vars["body"] = body }
        if let ids = assigneeIds, !ids.isEmpty { vars["assigneeIds"] = ids }
        if let ids = labelIds, !ids.isEmpty { vars["labelIds"] = ids }
        if let mid = milestoneId { vars["milestoneId"] = mid }

        let data = try await client.executeRaw(query: mutation, variables: vars)

        guard let create = data["createIssue"] as? [String: Any],
              let issue = create["issue"] as? [String: Any],
              let id = issue["id"] as? String,
              let number = issue["number"] as? Int else {
            throw GitHubGraphQLError.noData
        }
        return (id, number, issue["url"] as? String)
    }

    /// Creates a new GitHub Projects v2 project.
    public func createProject(ownerId: String, title: String) async throws -> GitHubProject {
        let mutation = """
            mutation($ownerId: ID!, $title: String!) {
                createProjectV2(input: { ownerId: $ownerId, title: $title }) {
                    projectV2 {
                        id number title shortDescription url closed public
                        createdAt updatedAt closedAt
                    }
                }
            }
            """

        let vars: [String: Any] = ["ownerId": ownerId, "title": title]
        let data = try await client.executeRaw(query: mutation, variables: vars)

        guard let create = data["createProjectV2"] as? [String: Any],
              let proj = create["projectV2"] as? [String: Any],
              let project = Self.parseProject(proj) else {
            throw GitHubGraphQLError.noData
        }
        return project
    }

    // MARK: - Repository Queries

    /// Gets the node ID for a repository.
    public func getRepositoryId(owner: String, name: String) async throws -> String {
        let query = """
            query($owner: String!, $name: String!) {
                repository(owner: $owner, name: $name) { id }
            }
            """
        let vars: [String: Any] = ["owner": owner, "name": name]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let repo = data["repository"] as? [String: Any],
              let id = repo["id"] as? String else {
            throw GitHubGraphQLError.graphQLError("Repository not found: \(owner)/\(name)")
        }
        return id
    }

    /// Gets the node ID for an organization.
    public func getOrganizationId(login: String) async throws -> String {
        let query = """
            query($login: String!) {
                organization(login: $login) { id }
            }
            """
        let vars: [String: Any] = ["login": login]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let org = data["organization"] as? [String: Any],
              let id = org["id"] as? String else {
            throw GitHubGraphQLError.graphQLError("Organization not found: \(login)")
        }
        return id
    }

    /// Gets the node ID for a user.
    public func getUserId(login: String) async throws -> String {
        let query = """
            query($login: String!) {
                user(login: $login) { id }
            }
            """
        let vars: [String: Any] = ["login": login]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let user = data["user"] as? [String: Any],
              let id = user["id"] as? String else {
            throw GitHubGraphQLError.graphQLError("User not found: \(login)")
        }
        return id
    }

    /// Gets the node ID for an owner, trying organization first then user.
    public func getOwnerId(login: String, scope: ProjectScope) async throws -> String {
        switch scope {
        case .user:
            return try await getUserId(login: login)
        case .organization:
            return try await getOrganizationId(login: login)
        default:
            // Try org first, fall back to user
            do {
                return try await getOrganizationId(login: login)
            } catch {
                return try await getUserId(login: login)
            }
        }
    }

    /// Lists labels for a repository.
    public func listRepositoryLabels(owner: String, name: String) async throws -> [(id: String, name: String, color: String?)] {
        let query = """
            query($owner: String!, $name: String!) {
                repository(owner: $owner, name: $name) {
                    labels(first: 100, orderBy: {field: NAME, direction: ASC}) {
                        nodes { id name color }
                    }
                }
            }
            """
        let vars: [String: Any] = ["owner": owner, "name": name]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let repo = data["repository"] as? [String: Any],
              let labels = repo["labels"] as? [String: Any],
              let nodes = labels["nodes"] as? [[String: Any]] else { return [] }

        return nodes.compactMap { node in
            guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
            return (id, name, node["color"] as? String)
        }
    }

    /// Lists open milestones for a repository.
    public func listRepositoryMilestones(owner: String, name: String) async throws -> [(id: String, number: Int, title: String)] {
        let query = """
            query($owner: String!, $name: String!) {
                repository(owner: $owner, name: $name) {
                    milestones(first: 20, states: OPEN, orderBy: {field: DUE_DATE, direction: ASC}) {
                        nodes { id number title }
                    }
                }
            }
            """
        let vars: [String: Any] = ["owner": owner, "name": name]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let repo = data["repository"] as? [String: Any],
              let milestones = repo["milestones"] as? [String: Any],
              let nodes = milestones["nodes"] as? [[String: Any]] else { return [] }

        return nodes.compactMap { node in
            guard let id = node["id"] as? String,
                  let number = node["number"] as? Int,
                  let title = node["title"] as? String else { return nil }
            return (id, number, title)
        }
    }

    /// Lists users who can be assigned to issues in a repository.
    public func listAssignableUsers(owner: String, name: String) async throws -> [(id: String, login: String)] {
        let query = """
            query($owner: String!, $name: String!) {
                repository(owner: $owner, name: $name) {
                    assignableUsers(first: 50) {
                        nodes { id login }
                    }
                }
            }
            """
        let vars: [String: Any] = ["owner": owner, "name": name]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let repo = data["repository"] as? [String: Any],
              let assignable = repo["assignableUsers"] as? [String: Any],
              let nodes = assignable["nodes"] as? [[String: Any]] else { return [] }

        return nodes.compactMap { node in
            guard let id = node["id"] as? String, let login = node["login"] as? String else { return nil }
            return (id, login)
        }
    }

    /// Lists repositories for an organization (for issue creation target picker).
    public func listOrganizationRepos(login: String, limit: Int = 30) async throws -> [(owner: String, name: String)] {
        let query = """
            query($login: String!, $first: Int!) {
                organization(login: $login) {
                    repositories(first: $first, orderBy: {field: UPDATED_AT, direction: DESC}) {
                        nodes { nameWithOwner }
                    }
                }
            }
            """
        let vars: [String: Any] = ["login": login, "first": limit]
        let data = try await client.executeRaw(query: query, variables: vars)

        guard let org = data["organization"] as? [String: Any],
              let repos = org["repositories"] as? [String: Any],
              let nodes = repos["nodes"] as? [[String: Any]] else { return [] }

        return nodes.compactMap { node in
            guard let nwo = node["nameWithOwner"] as? String else { return nil }
            let parts = nwo.split(separator: "/")
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// Archives or unarchives a project item.
    public func archiveItem(projectId: String, itemId: String, archive: Bool = true) async throws {
        let mutation = archive ? """
            mutation($projectId: ID!, $itemId: ID!) {
                archiveProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
                    item { id }
                }
            }
            """ : """
            mutation($projectId: ID!, $itemId: ID!) {
                unarchiveProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
                    item { id }
                }
            }
            """

        let vars: [String: Any] = ["projectId": projectId, "itemId": itemId]
        _ = try await client.executeRaw(query: mutation, variables: vars)
    }

    // MARK: - Issue REST API (v3)

    private func restDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Fetches full issue detail from the GitHub REST v3 API.
    public func getIssueDetail(owner: String, repo: String, number: Int) async throws -> GitHubIssueDetail {
        let data = try await client.executeREST(path: "/repos/\(owner)/\(repo)/issues/\(number)")
        return try restDecoder().decode(GitHubIssueDetail.self, from: data)
    }

    /// Lists comments on an issue (up to 100).
    public func listIssueComments(owner: String, repo: String, number: Int) async throws -> [GitHubComment] {
        let data = try await client.executeREST(path: "/repos/\(owner)/\(repo)/issues/\(number)/comments?per_page=100")
        return try restDecoder().decode([GitHubComment].self, from: data)
    }

    /// Creates a comment on an issue.
    public func createIssueComment(owner: String, repo: String, number: Int, body: String) async throws -> GitHubComment {
        let data = try await client.executeREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/comments",
            body: ["body": body]
        )
        return try restDecoder().decode(GitHubComment.self, from: data)
    }

    /// Updates an issue's title, body, state, labels, assignees, or milestone.
    public func updateIssue(
        owner: String, repo: String, number: Int,
        title: String? = nil, body: String? = nil, state: String? = nil,
        labels: [String]? = nil, assignees: [String]? = nil, milestoneNumber: Int? = nil
    ) async throws -> GitHubIssueDetail {
        var updates: [String: Any] = [:]
        if let title { updates["title"] = title }
        if let body  { updates["body"]  = body  }
        if let state { updates["state"] = state }
        if let labels     { updates["labels"]     = labels     }
        if let assignees  { updates["assignees"]  = assignees  }
        if let milestoneNumber { updates["milestone"] = milestoneNumber }
        let data = try await client.executeREST(
            method: "PATCH",
            path: "/repos/\(owner)/\(repo)/issues/\(number)",
            body: updates
        )
        return try restDecoder().decode(GitHubIssueDetail.self, from: data)
    }

    /// Locks an issue.
    public func lockIssue(owner: String, repo: String, number: Int, lockReason: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let reason = lockReason { body["lock_reason"] = reason }
        _ = try await client.executeREST(
            method: "PUT",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/lock",
            body: body.isEmpty ? nil : body
        )
    }

    /// Unlocks an issue.
    public func unlockIssue(owner: String, repo: String, number: Int) async throws {
        _ = try await client.executeREST(
            method: "DELETE",
            path: "/repos/\(owner)/\(repo)/issues/\(number)/lock"
        )
    }

    /// Deletes an issue via GraphQL (REST API does not support deletion).
    public func deleteIssue(nodeId: String) async throws {
        let mutation = """
            mutation($id: ID!) {
                deleteIssue(input: { issueId: $id }) {
                    repository { id }
                }
            }
            """
        _ = try await client.executeRaw(query: mutation, variables: ["id": nodeId])
    }

    /// Pins an issue to its repository.
    public func pinIssue(nodeId: String, repositoryId: String) async throws {
        let mutation = """
            mutation($issueId: ID!, $repoId: ID!) {
                pinIssue(input: { issueId: $issueId, repositoryId: $repoId }) {
                    issue { id }
                }
            }
            """
        _ = try await client.executeRaw(query: mutation, variables: ["issueId": nodeId, "repoId": repositoryId])
    }

    /// Unpins an issue from its repository.
    public func unpinIssue(nodeId: String) async throws {
        let mutation = """
            mutation($issueId: ID!) {
                unpinIssue(input: { issueId: $issueId }) {
                    issue { id }
                }
            }
            """
        _ = try await client.executeRaw(query: mutation, variables: ["issueId": nodeId])
    }

    /// Transfers an issue to a different repository.
    /// - Returns: The new issue's node ID.
    public func transferIssue(nodeId: String, targetRepositoryId: String) async throws -> String {
        let mutation = """
            mutation($issueId: ID!, $repoId: ID!) {
                transferIssue(input: { issueId: $issueId, repositoryId: $repoId }) {
                    issue { id number url }
                }
            }
            """
        let data = try await client.executeRaw(query: mutation, variables: ["issueId": nodeId, "repoId": targetRepositoryId])
        if let transfer = data["transferIssue"] as? [String: Any],
           let issue = transfer["issue"] as? [String: Any],
           let id = issue["id"] as? String {
            return id
        }
        throw GitHubGraphQLError.noData
    }

    /// Lists branch names for a repository (up to 100).
    public func listRepositoryBranches(owner: String, repo: String) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        let data = try await client.executeREST(path: "/repos/\(owner)/\(repo)/branches?per_page=100")
        let branches = try JSONDecoder().decode([Branch].self, from: data)
        return branches.map { $0.name }
    }

    // MARK: - Parsing Helpers

    private static func parseProjects(_ projectsV2: [String: Any]) -> [GitHubProject] {
        guard let nodes = projectsV2["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parseProject($0) }
    }

    private static func parseProject(_ dict: [String: Any]) -> GitHubProject? {
        guard let id = dict["id"] as? String,
              let number = dict["number"] as? Int,
              let title = dict["title"] as? String else { return nil }

        return GitHubProject(
            id: id, number: number, title: title,
            shortDescription: dict["shortDescription"] as? String,
            url: dict["url"] as? String,
            closed: dict["closed"] as? Bool ?? false,
            isPublic: dict["public"] as? Bool ?? false,
            createdAt: parseDate(dict["createdAt"]) ?? Date(),
            updatedAt: parseDate(dict["updatedAt"]) ?? Date(),
            closedAt: parseDate(dict["closedAt"])
        )
    }

    private static func parseProjectItem(_ dict: [String: Any]) -> GitHubProjectItem {
        let id = dict["id"] as? String ?? ""
        let type = dict["type"] as? String ?? "DRAFT_ISSUE"

        var content: GitHubProjectItemContent? = nil
        var draftContent: GitHubProjectDraftContent? = nil

        if let contentDict = dict["content"] as? [String: Any] {
            if let _ = contentDict["number"] as? Int {
                // Issue or Pull Request
                content = GitHubProjectItemContent(
                    id: contentDict["id"] as? String ?? "",
                    number: contentDict["number"] as? Int ?? 0,
                    title: contentDict["title"] as? String ?? "",
                    body: contentDict["body"] as? String,
                    state: contentDict["state"] as? String,
                    url: contentDict["url"] as? String,
                    createdAt: parseDate(contentDict["createdAt"]) ?? Date(),
                    updatedAt: parseDate(contentDict["updatedAt"]) ?? Date(),
                    closedAt: parseDate(contentDict["closedAt"]),
                    assignees: parseLogins(contentDict["assignees"]),
                    labels: parseNames(contentDict["labels"]),
                    isPullRequest: type == "PULL_REQUEST",
                    repository: (contentDict["repository"] as? [String: Any])?["nameWithOwner"] as? String
                )
            } else if let title = contentDict["title"] as? String {
                draftContent = GitHubProjectDraftContent(
                    title: title,
                    body: contentDict["body"] as? String
                )
            }
        }

        var fieldValues: [GitHubProjectFieldValue] = []
        if let fvDict = dict["fieldValues"] as? [String: Any],
           let fvNodes = fvDict["nodes"] as? [[String: Any]] {
            for fv in fvNodes {
                if let parsed = parseFieldValue(fv) {
                    fieldValues.append(parsed)
                }
            }
        }

        return GitHubProjectItem(
            id: id, type: type,
            createdAt: parseDate(dict["createdAt"]) ?? Date(),
            updatedAt: parseDate(dict["updatedAt"]) ?? Date(),
            isArchived: dict["isArchived"] as? Bool ?? false,
            content: content, draftContent: draftContent,
            fieldValues: fieldValues
        )
    }

    private static func parseFieldValue(_ dict: [String: Any]) -> GitHubProjectFieldValue? {
        guard let field = dict["field"] as? [String: Any],
              let fieldId = field["id"] as? String,
              let fieldName = field["name"] as? String else { return nil }

        if let text = dict["text"] as? String {
            return GitHubProjectFieldValue(
                fieldId: fieldId, fieldName: fieldName, dataType: "TEXT",
                textValue: text
            )
        } else if let number = dict["number"] as? Double {
            return GitHubProjectFieldValue(
                fieldId: fieldId, fieldName: fieldName, dataType: "NUMBER",
                numberValue: number
            )
        } else if let date = dict["date"] as? String {
            return GitHubProjectFieldValue(
                fieldId: fieldId, fieldName: fieldName, dataType: "DATE",
                dateValue: ISO8601DateFormatter().date(from: date)
            )
        } else if let name = dict["name"] as? String {
            return GitHubProjectFieldValue(
                fieldId: fieldId, fieldName: fieldName, dataType: "SINGLE_SELECT",
                singleSelectValue: name,
                singleSelectOptionId: dict["optionId"] as? String
            )
        } else if let title = dict["title"] as? String {
            return GitHubProjectFieldValue(
                fieldId: fieldId, fieldName: fieldName, dataType: "ITERATION",
                iterationValue: title,
                iterationId: dict["iterationId"] as? String
            )
        }

        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    private static func parseLogins(_ value: Any?) -> [String] {
        guard let dict = value as? [String: Any],
              let nodes = dict["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { $0["login"] as? String }
    }

    private static func parseNames(_ value: Any?) -> [String] {
        guard let dict = value as? [String: Any],
              let nodes = dict["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { $0["name"] as? String }
    }
}
