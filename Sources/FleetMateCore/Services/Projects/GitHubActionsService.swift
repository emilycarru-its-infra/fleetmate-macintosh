import Foundation

/// GitHub Actions runs and logs across the repositories the user works in,
/// through the REST API on the same token chain as everything else.
public actor GitHubActionsService {
    private let client: GitHubGraphQLClient

    public init(config: GitHubProviderConfig) {
        self.client = GitHubGraphQLClient(config: config)
    }

    /// Recent workflow runs in the given repositories, one request per
    /// repository run concurrently, newest first.
    public func getRecentRuns(repositories: [(owner: String, name: String)], since: Date, perRepo: Int = 15) async -> (runs: [PipelineRun], error: String?) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let sinceDay = String(formatter.string(from: since).prefix(10))
        let decoder = JSONDecoder()

        var firstError: String?
        let runs: [PipelineRun] = await withTaskGroup(of: Result<[PipelineRun], Error>.self) { group in
            for repo in repositories {
                group.addTask {
                    do {
                        let path = "/repos/\(repo.owner)/\(repo.name)/actions/runs?per_page=\(perRepo)&created=%3E%3D\(sinceDay)"
                        let data = try await self.client.executeREST(path: path)
                        let page = try decoder.decode(RestRunsPage.self, from: data)
                        return .success(page.workflowRuns.map { Self.map($0, owner: repo.owner, repo: repo.name) })
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var all: [PipelineRun] = []
            for await result in group {
                switch result {
                case .success(let runs): all.append(contentsOf: runs)
                case .failure(let error): if firstError == nil { firstError = error.localizedDescription }
                }
            }
            return all
        }
        dbg.info("GitHub getRecentRuns(\(repositories.count) repos) → \(runs.count) runs", category: "github")
        return (runs.sorted { $0.sortDate > $1.sortDate }, firstError)
    }

    /// Logs for a run, one section per job. Job logs redirect to a signed
    /// blob URL, which the client follows without the API token.
    public func getRunLog(owner: String, repo: String, runId: Int, maxBytesPerJob: Int = 400_000) async throws -> PipelineRunLog {
        let jobsData = try await client.executeREST(path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs?per_page=50")
        let jobs = try JSONDecoder().decode(RestJobsPage.self, from: jobsData).jobs
        var truncated = false
        var sections: [PipelineRunLog.Section] = []
        for job in jobs {
            var text: String
            do {
                text = try await client.executeRESTText(path: "/repos/\(owner)/\(repo)/actions/jobs/\(job.id)/logs")
            } catch {
                text = "(log unavailable: \(error.localizedDescription))"
            }
            if text.utf8.count > maxBytesPerJob {
                text = String(decoding: text.utf8.suffix(maxBytesPerJob), as: UTF8.self)
                truncated = true
            }
            sections.append(PipelineRunLog.Section(
                id: String(job.id),
                name: job.name,
                status: Self.status(status: job.status, conclusion: job.conclusion),
                text: text
            ))
        }
        return PipelineRunLog(runId: runId, sections: sections, truncated: truncated)
    }

    public func rerun(owner: String, repo: String, runId: Int) async throws {
        _ = try await client.executeREST(method: "POST", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/rerun")
    }

    public func cancel(owner: String, repo: String, runId: Int) async throws {
        _ = try await client.executeREST(method: "POST", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/cancel")
    }

    // MARK: - Mapping

    private static func status(status: String?, conclusion: String?) -> PipelineRunStatus {
        switch status?.lowercased() {
        case "queued", "waiting", "requested", "pending": return .queued
        case "in_progress": return .running
        case "completed":
            switch conclusion?.lowercased() {
            case "success": return .succeeded
            case "failure", "timed_out", "action_required", "startup_failure": return .failed
            case "cancelled": return .cancelled
            case "skipped": return .skipped
            case "neutral": return .partial
            default: return .unknown
            }
        default: return .unknown
        }
    }

    private static func map(_ run: RestRun, owner: String, repo: String) -> PipelineRun {
        PipelineRun(
            source: .gitHub,
            container: owner,
            repository: repo,
            pipelineName: run.name ?? run.displayTitle ?? "workflow",
            pipelineId: run.workflowId,
            runId: run.id,
            runNumber: "#\(run.runNumber ?? 0)",
            status: status(status: run.status, conclusion: run.conclusion),
            branch: run.headBranch,
            commitSha: run.headSha,
            triggeredBy: run.actor?.login,
            startedAt: PullRequestDateParser.parse(run.runStartedAt ?? run.createdAt),
            finishedAt: status(status: run.status, conclusion: run.conclusion).isActive ? nil : PullRequestDateParser.parse(run.updatedAt),
            webUrl: run.htmlUrl
        )
    }

    private struct RestRunsPage: Decodable {
        let workflowRuns: [RestRun]
        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }

    private struct RestRun: Decodable {
        let id: Int
        let name: String?
        let displayTitle: String?
        let workflowId: Int?
        let runNumber: Int?
        let status: String?
        let conclusion: String?
        let headBranch: String?
        let headSha: String?
        let actor: Actor?
        let createdAt: String?
        let runStartedAt: String?
        let updatedAt: String?
        let htmlUrl: String
        struct Actor: Decodable { let login: String? }
        enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion, actor
            case displayTitle = "display_title"
            case workflowId = "workflow_id"
            case runNumber = "run_number"
            case headBranch = "head_branch"
            case headSha = "head_sha"
            case createdAt = "created_at"
            case runStartedAt = "run_started_at"
            case updatedAt = "updated_at"
            case htmlUrl = "html_url"
        }
    }

    private struct RestJobsPage: Decodable {
        let jobs: [RestJob]
    }

    private struct RestJob: Decodable {
        let id: Int
        let name: String
        let status: String?
        let conclusion: String?
    }
}
