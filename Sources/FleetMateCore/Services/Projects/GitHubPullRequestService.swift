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
      comments { totalCount }
      reviewThreads { totalCount }
      reviewRequests(first: 10) {
        nodes {
          requestedReviewer {
            ... on User { login name }
            ... on Team { name }
          }
        }
      }
      latestReviews(first: 10) {
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

    /// Whether a usable GitHub token is reachable, without surfacing a login UI.
    public func isAuthenticated() async -> Bool {
        (try? await client.authenticate()) ?? false
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
            relations: [relation]
        )
    }
}
