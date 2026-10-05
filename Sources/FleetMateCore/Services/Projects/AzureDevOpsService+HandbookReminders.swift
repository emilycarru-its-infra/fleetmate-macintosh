import Foundation

/// Finished work that may still owe the knowledge base a page.
///
/// A gentle reminder, not a gate, and only for whole pieces of work —
/// deliverables, features, stories and bugs — not every task under them. A
/// recently finished item is covered when it, or any of its child items,
/// links a pull request or commit in the knowledge-base repository,
/// carries a "handbook-na" (or "no-handbook") tag, or has a comment that
/// starts a line with "Handbook:" — an update or a reason none is needed.
extension AzureDevOpsService {
    /// Tags that mark a work item as needing no knowledge-base change.
    public static let handbookNotNeededTags = ["handbook-na", "no-handbook"]

    /// The signed-in user's work items finished in the last `days` that are
    /// not covered, newest first. `handbookRepoUrl` is the knowledge-base
    /// repository's clone URL, which names its project and repository.
    /// The work item types a reminder is about: whole pieces of work.
    public static let handbookReminderTypes = ["Deliverable", "Feature", "Epic", "User Story", "Product Backlog Item", "Bug"]

    public func getFinishedWorkMissingHandbook(handbookRepoUrl: String, days: Int = 14,
                                               commentChecks: Int = 25) async throws -> [WorkItem] {
        guard let (project, repo) = Self.projectAndRepo(fromCloneURL: handbookRepoUrl) else { return [] }
        let finished = ["Done", "Closed", "Resolved", "Completed"].map { "'\($0)'" }.joined(separator: ", ")
        let types = Self.handbookReminderTypes.map { "'\($0)'" }.joined(separator: ", ")
        // StateChangeDate, not ChangedDate: when it was finished, not when it
        // was last touched — bulk edits to old items must not resurface them.
        let wiql = """
        SELECT [System.Id] FROM WorkItems \
        WHERE [System.AssignedTo] = @Me \
        AND [System.State] IN (\(finished)) \
        AND [System.WorkItemType] IN (\(types)) \
        AND [Microsoft.VSTS.Common.StateChangeDate] >= @Today - \(days) \
        ORDER BY [Microsoft.VSTS.Common.StateChangeDate] DESC
        """
        let items = try await queryWorkItems(wiql, orgLevel: true, top: 200)
        guard !items.isEmpty else { return [] }

        struct Repo: Decodable { let id: String }
        let encProject = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
        let encRepo = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        let handbookRepo: Repo = try await request("GET", path: "/_apis/git/repositories/\(encRepo)?api-version=7.0",
                                                    forProject: encProject)
        let repoId = handbookRepo.id.lowercased()

        var uncovered: [WorkItem] = []
        var commentBudget = commentChecks
        // Child tasks often carry the pull requests; count theirs too.
        let childIds = items.flatMap { item in
            (item.relations ?? []).filter { $0.rel == "System.LinkTypes.Hierarchy-Forward" }
                .compactMap { $0.url?.split(separator: "/").last.flatMap { Int($0) } }
        }
        let children = (try? await getWorkItemsByIds(Array(Set(childIds)))) ?? []
        let childById = Dictionary(children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for item in items {
            if Self.linksRepository(item, repositoryId: repoId) { continue }
            let kids = (item.relations ?? []).filter { $0.rel == "System.LinkTypes.Hierarchy-Forward" }
                .compactMap { $0.url?.split(separator: "/").last.flatMap { Int($0) } }
                .compactMap { childById[$0] }
            if kids.contains(where: { Self.linksRepository($0, repositoryId: repoId) }) { continue }
            let tags = (item.fields?.tags ?? "").lowercased()
                .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if tags.contains(where: { Self.handbookNotNeededTags.contains($0) }) { continue }
            if commentBudget > 0 {
                commentBudget -= 1
                let comments = (try? await getComments(workItemId: item.id, project: item.fields?.teamProject)) ?? []
                if comments.contains(where: { Self.isHandbookNote($0.text ?? "") }) { continue }
            }
            uncovered.append(item)
        }
        return uncovered.sorted { ($0.fields?.changedDate ?? "") > ($1.fields?.changedDate ?? "") }
    }

    /// Mark a finished work item as needing no knowledge-base change, with the
    /// reason recorded where the next reader will see it.
    public func markHandbookNotNeeded(_ item: WorkItem, reason: String) async throws {
        var tags = (item.fields?.tags ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !tags.contains(where: { $0.caseInsensitiveCompare("handbook-na") == .orderedSame }) { tags.append("handbook-na") }
        _ = try await updateWorkItem(id: item.id, request: UpdateWorkItemRequest(
            tags: tags.joined(separator: "; ")))
        _ = try await addComment(workItemId: item.id, text: "Handbook: not needed — \(reason)",
                                 project: item.fields?.teamProject)
    }

    /// `…/<org>/<project>/_git/<repo>` → (project, repo).
    static func projectAndRepo(fromCloneURL url: String) -> (String, String)? {
        guard let parts = URL(string: url)?.path.split(separator: "/").map(String.init),
              let git = parts.firstIndex(of: "_git"), git >= 1, parts.count > git + 1 else { return nil }
        let decode = { (s: String) in s.removingPercentEncoding ?? s }
        return (decode(parts[git - 1]), decode(parts[git + 1]))
    }

    /// A pull-request or commit artifact link into the given repository.
    /// Artifact URLs look like vstfs:///Git/PullRequestId/<project>%2F<repo>%2F<id>.
    static func linksRepository(_ item: WorkItem, repositoryId: String) -> Bool {
        (item.relations ?? []).contains { relation in
            guard let url = relation.url?.lowercased(), url.hasPrefix("vstfs:///git/") else { return false }
            let decoded = url.removingPercentEncoding ?? url
            return decoded.contains("/\(repositoryId)/")
        }
    }

    /// A comment line that starts with "Handbook:" — the updated page, or why none was needed.
    static func isHandbookNote(_ html: String) -> Bool {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        return text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("handbook:")
        }
    }
}
