import Foundation

/// Builds the signed-in user's GitHub pull request queue across **every**
/// repository the token can see — not just the configured org/repo.
///
/// Auth reuses `GitHubTokenSource` (config token → `gh` CLI → env → Keychain →
/// Device Flow), so an SSO-authorized `gh` login is all that is needed.
public actor GitHubPullRequestService {
    private let client: GitHubGraphQLClient

    public init(config: GitHubProviderConfig, deviceFlowPrompt: ((String, URL) async -> Void)? = nil) {
        self.client = GitHubGraphQLClient(config: config, deviceFlowPrompt: deviceFlowPrompt)
    }

    /// The three `search` queries the queue is built from. `@me` resolves
    /// server-side to the token's owner, so no viewer lookup is needed.
    private static func searchQueries(includeDrafts: Bool) -> (created: String, assigned: String, review: String) {
        let base = "is:pr is:open archived:false"
        let draftFilter = includeDrafts ? "" : " -is:draft"
        return (
            created: "\(base)\(draftFilter) author:@me sort:updated-desc",
            assigned: "\(base) assignee:@me sort:updated-desc",
            review: "\(base) review-requested:@me sort:updated-desc"
        )
    }

    private static let pullRequestFragment = """
    fragment PullRequestFields on PullRequest {
      number
      title
      url
      isDraft
      state
      createdAt
      updatedAt
      mergeable
      baseRefName
      headRefName
      author { login }
      repository { name owner { login } }
      comments(last: 3) {
        totalCount
        nodes { databaseId author { login } body createdAt url }
      }
      reviews(last: 3) {
        nodes { databaseId author { login } body state submittedAt url }
      }
      reviewThreads(last: 3) {
        totalCount
        nodes {
          comments(last: 1) { nodes { databaseId author { login } body createdAt url path } }
        }
      }
      reviewRequests(first: 5) {
        nodes {
          requestedReviewer {
            ... on User { login name }
            ... on Team { name }
          }
        }
      }
      latestReviews(first: 5) {
        nodes { state author { login } }
      }
    }
    """

    /// Fetch the queue. Never partially throws — a failure in any single search
    /// surfaces as a `PullRequestQueueError` alongside whatever else succeeded.
    ///
    /// - Parameters:
    ///   - limit: Max results per search query. GitHub's search API caps a single
    ///     page at 100; beyond that the queue would need cursor paging.
    ///   - includeDrafts: Draft PRs you authored are usually noise in a review
    ///     queue; PRs assigned to you are included regardless.
    public func getMyPullRequests(limit: Int = 100, includeDrafts: Bool = true) async -> PullRequestQueue {
        let queries = Self.searchQueries(includeDrafts: includeDrafts)

        let query = """
        \(Self.pullRequestFragment)
        query($created: String!, $assigned: String!, $review: String!, $first: Int!) {
          created: search(query: $created, type: ISSUE, first: $first) {
            nodes { ...PullRequestFields }
          }
          assigned: search(query: $assigned, type: ISSUE, first: $first) {
            nodes { ...PullRequestFields }
          }
          review: search(query: $review, type: ISSUE, first: $first) {
            nodes { ...PullRequestFields }
          }
        }
        """

        do {
            let data = try await client.executeRaw(query: query, variables: [
                "created": queries.created,
                "assigned": queries.assigned,
                "review": queries.review,
                "first": limit
            ])

            var queue = PullRequestQueue()
            absorb(data, key: "created", relation: .createdByMe, into: &queue)
            absorb(data, key: "assigned", relation: .assignedToMe, into: &queue)
            absorb(data, key: "review", relation: .assignedToMe, into: &queue)

            dbg.info("GitHub getMyPullRequests → \(queue.pullRequests.count) PRs", category: "github")
            return queue
        } catch {
            dbg.error("GitHub getMyPullRequests failed: \(error)", category: "github")
            return PullRequestQueue(errors: [
                PullRequestQueueError(source: .gitHub, message: error.localizedDescription)
            ])
        }
    }

    /// The wider queue the Code section shows: everything `getMyPullRequests`
    /// returns, plus PRs the user is merely involved in and every open PR in
    /// the given owners' repositories (`user:<owner>` matches orgs and users).
    ///
    /// Owners are deduplicated case-insensitively. Each extra owner costs one
    /// search point, so a handful is fine and dozens is not.
    public func getOpenPullRequests(owners: [String], limit: Int = 100) async -> PullRequestQueue {
        var queue = await getMyPullRequests(limit: limit)

        var seen: Set<String> = []
        let ownerList = owners
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }

        var searches: [Search] = [
            Search(query: "is:pr is:open archived:false involves:@me sort:updated-desc", relation: .involved)
        ]
        searches += ownerList.map {
            Search(query: "is:pr is:open archived:false user:\($0) sort:updated-desc", relation: .organization)
        }

        let outcome = await runSearches(searches, limit: limit)
        for pr in outcome.pullRequests { queue.insert(pr) }
        if let message = outcome.error {
            queue.errors.append(PullRequestQueueError(source: .gitHub, message: message))
        }
        dbg.info("GitHub getOpenPullRequests(owners: \(ownerList.count)) → \(queue.pullRequests.count) PRs", category: "github")
        return queue
    }

    private struct Search {
        let query: String
        let relation: PullRequestRelation
    }

    private struct SearchOutcome {
        var pullRequests: [UnifiedPullRequest] = []
        var error: String?
    }

    /// GitHub caps a single GraphQL request by the nodes it *could* return,
    /// and a dozen aliased searches at 100 rows each with nested comments
    /// blows past it ("Resource limits for this query exceeded"). Searches
    /// therefore run in small batches; when a batch trips the limit it is
    /// split in half and retried, down to one search at half the rows, so
    /// the queue degrades instead of failing.
    private func runSearches(_ searches: [Search], limit: Int, batchSize: Int = 3) async -> SearchOutcome {
        var outcome = SearchOutcome()
        var index = 0
        while index < searches.count {
            let batch = Array(searches[index..<min(index + batchSize, searches.count)])
            do {
                outcome.pullRequests += try await execute(batch: batch, limit: limit)
                index += batch.count
            } catch {
                let message = error.localizedDescription
                let overLimit = message.localizedCaseInsensitiveContains("resource limits")
                if overLimit, batch.count > 1 {
                    // Re-run this window with a smaller batch.
                    let smaller = await runSearches(batch, limit: limit, batchSize: max(1, batch.count / 2))
                    outcome.pullRequests += smaller.pullRequests
                    if let inner = smaller.error { outcome.error = inner }
                    index += batch.count
                } else if overLimit, limit > 25 {
                    let smaller = await runSearches(batch, limit: limit / 2, batchSize: 1)
                    outcome.pullRequests += smaller.pullRequests
                    if let inner = smaller.error { outcome.error = inner }
                    index += batch.count
                } else {
                    dbg.error("GitHub search batch failed: \(message)", category: "github")
                    outcome.error = message
                    // A rate limit or auth failure will hit every batch; stop.
                    if message.localizedCaseInsensitiveContains("rate limit")
                        || message.contains("No GitHub authentication token") {
                        break
                    }
                    index += batch.count
                }
            }
        }
        return outcome
    }

    private func execute(batch: [Search], limit: Int) async throws -> [UnifiedPullRequest] {
        var aliases: [String] = []
        var declarations: [String] = ["$first: Int!"]
        var variables: [String: Any] = ["first": limit]
        for (index, search) in batch.enumerated() {
            aliases.append("s\(index): search(query: $q\(index), type: ISSUE, first: $first) { nodes { ...PullRequestFields } }")
            declarations.append("$q\(index): String!")
            variables["q\(index)"] = search.query
        }
        let query = """
        \(Self.pullRequestFragment)
        query(\(declarations.joined(separator: ", "))) {
          \(aliases.joined(separator: "\n  "))
        }
        """
        let data = try await client.executeRaw(query: query, variables: variables)
        var out: [UnifiedPullRequest] = []
        for (index, search) in batch.enumerated() {
            let nodes = (data["s\(index)"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            out += nodes.compactMap { Self.map($0, relation: search.relation) }
        }
        return out
    }

    /// Owners the signed-in user belongs to: their own login plus every
    /// organization membership the token can see. Feeds `getOpenPullRequests`.
    public func getViewerOwners() async throws -> [String] {
        let data = try await client.executeRaw(query: """
        query { viewer { login organizations(first: 50) { nodes { login } } } }
        """)
        guard let viewer = data["viewer"] as? [String: Any] else { return [] }
        var owners: [String] = []
        if let login = viewer["login"] as? String { owners.append(login) }
        let orgs = (viewer["organizations"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        owners.append(contentsOf: orgs.compactMap { $0["login"] as? String })
        return owners
    }

    /// One pull request by coordinates, in the queue's unified shape — used to
    /// open a PR the inbox points at that the queue has not loaded.
    public func getPullRequest(owner: String, repo: String, number: Int) async throws -> UnifiedPullRequest? {
        let query = """
        \(Self.pullRequestFragment)
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) { ...PullRequestFields }
          }
        }
        """
        let data = try await client.executeRaw(query: query, variables: [
            "owner": owner, "repo": repo, "number": number
        ])
        guard let node = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else { return nil }
        return Self.map(node, relation: .involved)
    }

    /// Whether a usable GitHub token is reachable, without surfacing a login UI.
    public func isAuthenticated() async -> Bool {
        (try? await client.authenticate()) ?? false
    }

    // MARK: - PR detail (REST)

    /// Everything the in-app viewer needs for one PR: body, commits, comments
    /// and per-file diffs. REST rather than GraphQL because `/pulls/{n}/files`
    /// hands back ready-made unified-diff `patch` hunks per file.
    public func getPullRequestDetail(owner: String, repo: String, number: Int) async throws -> PullRequestDetail {
        let base = "/repos/\(owner)/\(repo)"
        let decoder = JSONDecoder()

        async let prData = client.executeREST(path: "\(base)/pulls/\(number)")
        async let commitsData = client.executeREST(path: "\(base)/pulls/\(number)/commits?per_page=100")
        async let commentsData = client.executeREST(path: "\(base)/issues/\(number)/comments?per_page=100")
        async let filesData = client.executeREST(path: "\(base)/pulls/\(number)/files?per_page=100")

        let pr = try decoder.decode(RestPullRequest.self, from: try await prData)
        let commits = try decoder.decode([RestCommit].self, from: try await commitsData)
        let comments = try decoder.decode([RestComment].self, from: try await commentsData)
        let files = try decoder.decode([RestFile].self, from: try await filesData)

        let diffFiles: [DiffFile] = files.map { file in
            if let patch = file.patch {
                return DiffParser.parseBareHunks(patch, fileName: file.filename)
            }
            // Binary or too-large — GitHub omits the patch.
            return DiffFile(headerLines: [], oldPath: file.filename, newPath: file.filename)
        }

        return PullRequestDetail(
            body: pr.body,
            commits: commits.map {
                PullRequestCommit(
                    id: $0.sha,
                    message: $0.commit.message,
                    authorName: $0.commit.author?.name ?? $0.author?.login,
                    date: PullRequestDateParser.parse($0.commit.author?.date)
                )
            },
            comments: comments.map {
                PullRequestComment(
                    id: String($0.id),
                    authorName: $0.user?.login ?? "unknown",
                    body: $0.body ?? "",
                    date: PullRequestDateParser.parse($0.createdAt),
                    isSystem: false
                )
            },
            files: diffFiles,
            truncated: files.count >= 100
        )
    }

    private struct RestPullRequest: Decodable {
        let body: String?
    }

    private struct RestCommit: Decodable {
        let sha: String
        let commit: Inner
        let author: RestUser?
        struct Inner: Decodable {
            let message: String
            let author: Signature?
        }
        struct Signature: Decodable {
            let name: String?
            let date: String?
        }
    }

    private struct RestUser: Decodable {
        let login: String?
    }

    private struct RestComment: Decodable {
        let id: Int
        let user: RestUser?
        let body: String?
        let createdAt: String?
        enum CodingKeys: String, CodingKey {
            case id, user, body
            case createdAt = "created_at"
        }
    }

    private struct RestFile: Decodable {
        let filename: String
        let patch: String?
    }

    // MARK: - Issues

    /// Open issues involving the signed-in account (author, assignee or
    /// mention), newest activity first. Throws so the caller can distinguish a
    /// rate limit from "no issues".
    public func getMyIssues(limit: Int = 50) async throws -> [GitHubIssueSummary] {
        let query = """
        query($q: String!, $first: Int!) {
          search(query: $q, type: ISSUE, first: $first) {
            nodes {
              ... on Issue {
                number
                title
                url
                state
                updatedAt
                author { login }
                repository { nameWithOwner }
              }
            }
          }
        }
        """
        let data = try await client.executeRaw(query: query, variables: [
            "q": "is:issue is:open archived:false involves:@me sort:updated-desc",
            "first": limit
        ])

        let nodes = (data["search"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let issues: [GitHubIssueSummary] = nodes.compactMap { node in
            guard
                let number = node["number"] as? Int,
                let url = node["url"] as? String,
                let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
            else { return nil }
            return GitHubIssueSummary(
                number: number,
                title: node["title"] as? String ?? "(untitled)",
                repository: repo,
                state: (node["state"] as? String)?.capitalized ?? "Open",
                authorLogin: (node["author"] as? [String: Any])?["login"] as? String,
                updatedAt: PullRequestDateParser.parse(node["updatedAt"] as? String),
                webUrl: url
            )
        }
        dbg.info("GitHub getMyIssues → \(issues.count) issues", category: "github")
        return issues
    }

    // MARK: - Mapping

    private func absorb(
        _ data: [String: Any],
        key: String,
        relation: PullRequestRelation,
        into queue: inout PullRequestQueue
    ) {
        let nodes = (data[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for node in nodes {
            // `search(type: ISSUE)` also returns issues; those decode without a
            // `number`/`repository` pair we can use, so skip anything incomplete.
            guard let pr = Self.map(node, relation: relation) else { continue }
            queue.insert(pr)
        }
    }

    private static func map(_ node: [String: Any], relation: PullRequestRelation) -> UnifiedPullRequest? {
        guard
            let number = node["number"] as? Int,
            let url = node["url"] as? String,
            let repository = node["repository"] as? [String: Any],
            let repoName = repository["name"] as? String,
            let owner = (repository["owner"] as? [String: Any])?["login"] as? String
        else { return nil }

        let isDraft = node["isDraft"] as? Bool ?? false
        let rawState = (node["state"] as? String)?.uppercased()
        let state: PullRequestState
        switch rawState {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default:       state = isDraft ? .draft : .open
        }

        // Reviewers = everyone a review is requested from, overlaid with whoever
        // has already left one, so the vote pips reflect current standing.
        var reviewersByName: [String: PullRequestReviewer] = [:]

        let requested = (node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for entry in requested {
            guard let reviewer = entry["requestedReviewer"] as? [String: Any] else { continue }
            let name = (reviewer["name"] as? String) ?? (reviewer["login"] as? String)
            guard let name, !name.isEmpty else { continue }
            reviewersByName[name.lowercased()] = PullRequestReviewer(
                id: name,
                displayName: name,
                vote: .noVote,
                isRequired: true
            )
        }

        let reviews = (node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for review in reviews {
            guard let login = (review["author"] as? [String: Any])?["login"] as? String else { continue }
            reviewersByName[login.lowercased()] = PullRequestReviewer(
                id: login,
                displayName: login,
                vote: .fromGitHub(review["state"] as? String),
                isRequired: reviewersByName[login.lowercased()]?.isRequired ?? false
            )
        }

        let commentCount = ((node["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0)
            + ((node["reviewThreads"] as? [String: Any])?["totalCount"] as? Int ?? 0)
        let recentComments = Self.recentComments(node)

        return UnifiedPullRequest(
            source: .gitHub,
            number: number,
            title: node["title"] as? String ?? "(untitled)",
            authorName: (node["author"] as? [String: Any])?["login"] as? String ?? "Unknown",
            container: owner,
            repository: repoName,
            sourceBranch: node["headRefName"] as? String ?? "",
            targetBranch: node["baseRefName"] as? String ?? "",
            createdAt: PullRequestDateParser.parse(node["createdAt"] as? String),
            updatedAt: PullRequestDateParser.parse(node["updatedAt"] as? String),
            state: state,
            hasConflicts: (node["mergeable"] as? String)?.uppercased() == "CONFLICTING",
            commentCount: commentCount,
            reviewers: Array(reviewersByName.values).sorted { $0.displayName < $1.displayName },
            webUrl: url,
            relations: [relation],
            recentComments: recentComments
        )
    }

    /// Conversation comments, review summaries and inline review comments,
    /// merged newest-first. Reviews with no body (a bare approve) are dropped:
    /// the vote pips already carry them.
    private static func recentComments(_ node: [String: Any]) -> [PullRequestComment] {
        var out: [PullRequestComment] = []

        func comment(_ entry: [String: Any], dateKey: String, prefix: String? = nil) -> PullRequestComment? {
            let body = (entry["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, let id = entry["databaseId"] as? Int else { return nil }
            let path = entry["path"] as? String
            let text = path.map { "`\($0)` — \(body)" } ?? body
            return PullRequestComment(
                id: "\(prefix ?? "c")\(id)",
                authorName: (entry["author"] as? [String: Any])?["login"] as? String ?? "unknown",
                body: text,
                date: PullRequestDateParser.parse(entry[dateKey] as? String),
                isSystem: false,
                url: entry["url"] as? String
            )
        }

        let comments = (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        out += comments.compactMap { comment($0, dateKey: "createdAt") }

        let reviews = (node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        out += reviews.compactMap { comment($0, dateKey: "submittedAt", prefix: "r") }

        let threads = (node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for thread in threads {
            let inline = (thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            out += inline.compactMap { comment($0, dateKey: "createdAt", prefix: "t") }
        }

        return out
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }
}
