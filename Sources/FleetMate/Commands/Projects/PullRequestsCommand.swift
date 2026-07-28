import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// `fleetmate prs` — the CLI counterpart of the dashboard's "My pull requests"
/// queue: every open PR you opened or were asked to review, across every Azure
/// DevOps project and every GitHub repository you can see.
struct PullRequestsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prs",
        abstract: "List your open pull requests across Azure DevOps and GitHub"
    )

    @Option(name: .long, help: "Limit to one source: azdo or github")
    var source: String?

    @Option(name: .long, help: "PR status for Azure DevOps: active, completed, abandoned, all")
    var status: String = "active"

    @Flag(name: .long, help: "Skip Azure DevOps comment-thread lookups (faster, no comment counts)")
    var noComments: Bool = false

    @Flag(name: .long, help: "Output JSON")
    var json: Bool = false

    private var wantsAzureDevOps: Bool { source == nil || source?.lowercased() == "azdo" }
    private var wantsGitHub: Bool { source == nil || source?.lowercased() == "github" }

    func run() async throws {
        let config = try FleetMateConfig.load()
        var queue = PullRequestQueue()

        if wantsAzureDevOps {
            await appendAzureDevOps(config: config, into: &queue)
        }

        if wantsGitHub {
            let ghConfig = config.tasks?.providers.github ?? GitHubProviderConfig()
            let service = GitHubPullRequestService(config: ghConfig)
            queue.merge(await service.getMyPullRequests())
        }

        if json {
            printJson(queue)
        } else {
            printTable(queue)
        }
    }

    // MARK: - Azure DevOps

    private func appendAzureDevOps(config: FleetMateConfig, into queue: inout PullRequestQueue) async {
        let org = config.tasks?.providers.azdevops?.organization ?? config.devopsOrganization ?? ""
        guard !org.isEmpty else {
            queue.errors.append(PullRequestQueueError(
                source: .azureDevOps,
                message: "No organization configured (set devops_organization or tasks.providers.azdevops.organization)"
            ))
            return
        }

        let sso = DevOpsSsoService(tenantId: config.devopsTenantId ?? config.graphTenantId)
        do {
            let result = try await sso.refreshAccessToken()
            guard result.success, let token = result.accessToken else {
                queue.errors.append(PullRequestQueueError(
                    source: .azureDevOps,
                    message: result.error ?? "token acquisition failed — run 'az login'"
                ))
                return
            }

            let service = AzureDevOpsService(config: config)
            service.setBearerToken(token, expiry: Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600)))
            queue.merge(try await service.getMyPullRequests(
                status: status,
                includeCommentCounts: !noComments
            ))
        } catch {
            queue.errors.append(PullRequestQueueError(source: .azureDevOps, message: error.localizedDescription))
        }
    }

    // MARK: - Output

    private func printTable(_ queue: PullRequestQueue) {
        for error in queue.errors {
            print("! \(error.source.displayName): \(error.message)".yellow)
        }

        for relation in PullRequestRelation.allCases {
            let items = queue.section(relation)
            guard !items.isEmpty else { continue }

            print("\n\(relation.sectionTitle) (\(items.count))".cyan.bold)
            for pr in items {
                let badge = pr.source == .azureDevOps ? "azdo".blue : "gh".magenta
                var flags: [String] = []
                if pr.state == .draft { flags.append("draft".yellow) }
                if pr.hasConflicts { flags.append("conflicts".red) }
                let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: " "))]"

                print("  \(badge) \(pr.reference.bold) \(pr.title)\(suffix)")
                print("      \(pr.container)/\(pr.repository) → \(pr.targetBranch)  ·  \(pr.authorName)  ·  \(timestamp(pr))  ·  \(pr.commentCount) comment(s)".dim)
                print("      \(pr.webUrl)".dim)
            }
        }

        if queue.isEmpty && queue.errors.isEmpty {
            print("No open pull requests.".green)
        }
    }

    private func timestamp(_ pr: UnifiedPullRequest) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if pr.wasUpdatedAfterCreation, let updated = pr.updatedAt {
            return "updated \(formatter.string(from: updated))"
        }
        if let created = pr.createdAt {
            return "created \(formatter.string(from: created))"
        }
        return "—"
    }

    private func printJson(_ queue: PullRequestQueue) {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "errors": queue.errors.map { ["source": $0.source.rawValue, "message": $0.message] },
            "pullRequests": queue.pullRequests
                .sorted { $0.lastActivity > $1.lastActivity }
                .map { pr in
                    [
                        "source": pr.source.rawValue,
                        "number": pr.number,
                        "title": pr.title,
                        "author": pr.authorName,
                        "container": pr.container,
                        "repository": pr.repository,
                        "sourceBranch": pr.sourceBranch,
                        "targetBranch": pr.targetBranch,
                        "state": pr.state.rawValue,
                        "hasConflicts": pr.hasConflicts,
                        "commentCount": pr.commentCount,
                        "createdAt": pr.createdAt.map { iso.string(from: $0) } as Any,
                        "updatedAt": pr.updatedAt.map { iso.string(from: $0) } as Any,
                        "reviewers": pr.reviewers.map { ["name": $0.displayName, "vote": $0.vote.rawValue] },
                        "relations": pr.relations.map(\.rawValue).sorted(),
                        "url": pr.webUrl
                    ] as [String: Any]
                }
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print("{}")
            return
        }
        print(text)
    }
}
