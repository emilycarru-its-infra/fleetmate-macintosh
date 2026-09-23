import Foundation

// MARK: - Pipeline runs (Development › Pipelines)

/// Lifecycle of a run, normalized across Azure Pipelines and GitHub Actions.
public enum PipelineRunStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, succeeded, failed, cancelled, partial, skipped, unknown

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .partial: return "Partially succeeded"
        case .skipped: return "Skipped"
        case .unknown: return "Unknown"
        }
    }

    public var isActive: Bool { self == .queued || self == .running }
}

/// One pipeline run from either provider. There is no cross-project run
/// list in Azure DevOps and no cross-repository one in GitHub; this is it.
public struct PipelineRun: Identifiable, Sendable, Hashable {
    public let source: PullRequestSource
    /// AzDO: project name. GitHub: owner login.
    public let container: String
    /// AzDO: repository name. GitHub: repository name.
    public let repository: String?
    /// AzDO: build definition name. GitHub: workflow name.
    public let pipelineName: String
    /// AzDO: definition id. GitHub: workflow id. Needed to queue a rerun.
    public let pipelineId: Int?
    public let runId: Int
    /// AzDO buildNumber (e.g. "20260922.3"), GitHub run_number as text.
    public let runNumber: String
    public let status: PipelineRunStatus
    public let branch: String?
    public let commitSha: String?
    public let triggeredBy: String?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let webUrl: String

    public var id: String { "\(source.rawValue):\(container)/\(pipelineName)#\(runId)" }

    /// Wall-clock length once finished, or so far while running.
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var sortDate: Date { startedAt ?? finishedAt ?? .distantPast }

    public init(
        source: PullRequestSource,
        container: String,
        repository: String?,
        pipelineName: String,
        pipelineId: Int?,
        runId: Int,
        runNumber: String,
        status: PipelineRunStatus,
        branch: String?,
        commitSha: String?,
        triggeredBy: String?,
        startedAt: Date?,
        finishedAt: Date?,
        webUrl: String
    ) {
        self.source = source
        self.container = container
        self.repository = repository
        self.pipelineName = pipelineName
        self.pipelineId = pipelineId
        self.runId = runId
        self.runNumber = runNumber
        self.status = status
        self.branch = branch
        self.commitSha = commitSha
        self.triggeredBy = triggeredBy
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.webUrl = webUrl
    }

    public static func == (lhs: PipelineRun, rhs: PipelineRun) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.finishedAt == rhs.finishedAt
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The log of one run, split into the provider's natural sections: jobs on
/// GitHub, timeline records (stages, jobs, tasks) on Azure DevOps.
public struct PipelineRunLog: Sendable {
    public struct Section: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let status: PipelineRunStatus
        public let text: String
        public init(id: String, name: String, status: PipelineRunStatus, text: String) {
            self.id = id
            self.name = name
            self.status = status
            self.text = text
        }
    }

    public let runId: Int
    public let sections: [Section]
    /// True when a section's text was cut to keep the view responsive.
    public let truncated: Bool

    public init(runId: Int, sections: [Section], truncated: Bool = false) {
        self.runId = runId
        self.sections = sections
        self.truncated = truncated
    }

    public var text: String {
        sections.map { "── \($0.name) ──\n\($0.text)" }.joined(separator: "\n\n")
    }
}
