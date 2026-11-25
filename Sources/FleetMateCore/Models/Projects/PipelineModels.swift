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
        /// Azure DevOps timeline `identifier`; a waiting approval's id.
        public let identifier: String?
        public init(id: String, name: String, status: PipelineRunStatus, text: String, identifier: String? = nil) {
            self.id = id
            self.name = name
            self.status = status
            self.text = text
            self.identifier = identifier
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

// MARK: - Approvals

/// What Azure Pipelines does when a ManualValidation step is not answered in time.
public enum ApprovalTimeoutAction: String, Sendable, Hashable {
    case resume, reject

    public var outcome: String { self == .resume ? "the run resumes" : "the run is rejected" }
}

/// The parts of a ManualValidation step that only the pipeline definition
/// knows: how long it waits and what it does at the end.
public struct ManualValidationSettings: Sendable, Hashable {
    public let instructions: String?
    public let timeoutMinutes: Int?
    public let onTimeout: ApprovalTimeoutAction

    public init(instructions: String?, timeoutMinutes: Int?, onTimeout: ApprovalTimeoutAction) {
        self.instructions = instructions
        self.timeoutMinutes = timeoutMinutes
        self.onTimeout = onTimeout
    }
}

/// Where a pending approval sits in its run's timeline.
public struct ApprovalTimelinePlace: Sendable, Hashable {
    public let recordId: String?
    public let stepName: String?
    public let stageName: String?
    public let startedAt: Date?

    public init(recordId: String?, stepName: String?, stageName: String?, startedAt: Date?) {
        self.recordId = recordId
        self.stepName = stepName
        self.stageName = stageName
        self.startedAt = startedAt
    }
}

/// A pending approval that holds an Azure Pipelines run: a ManualValidation
/// task or an environment approval check. Both use the same Approvals API.
public struct PipelineApproval: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case manualValidation, environment
    }

    /// The approval id; also the `identifier` of the run's timeline record.
    public let id: String
    /// Azure DevOps project name.
    public let project: String
    /// The build the approval holds, when the API says so. ManualValidation
    /// approvals leave it out, so it is matched through the build's timeline.
    public let buildId: Int?
    public let instructions: String
    public let createdOn: Date?
    /// Display names of the people or groups asked to approve.
    public let approvers: [String]
    /// A ManualValidation approval names no build; an environment one does.
    public let kind: Kind
    public let minRequiredApprovers: Int?
    public var stageName: String?
    public var stepName: String?
    /// When the step began waiting, from the timeline; falls back to `createdOn`.
    public var startedAt: Date?
    public var settings: ManualValidationSettings?

    public init(
        id: String, project: String, buildId: Int?, instructions: String, createdOn: Date?, approvers: [String],
        kind: Kind? = nil, minRequiredApprovers: Int? = nil, stageName: String? = nil, stepName: String? = nil,
        startedAt: Date? = nil, settings: ManualValidationSettings? = nil
    ) {
        self.id = id
        self.project = project
        self.buildId = buildId
        self.instructions = instructions
        self.createdOn = createdOn
        self.approvers = approvers
        self.kind = kind ?? (buildId == nil ? .manualValidation : .environment)
        self.minRequiredApprovers = minRequiredApprovers
        self.stageName = stageName
        self.stepName = stepName
        self.startedAt = startedAt
        self.settings = settings
    }

    public func assigned(to buildId: Int) -> PipelineApproval {
        let copy = PipelineApproval(
            id: id, project: project, buildId: buildId, instructions: instructions, createdOn: createdOn,
            approvers: approvers, kind: kind, minRequiredApprovers: minRequiredApprovers, stageName: stageName,
            stepName: stepName, startedAt: startedAt, settings: settings
        )
        return copy
    }

    public func placed(at place: ApprovalTimelinePlace) -> PipelineApproval {
        var copy = self
        copy.stageName = place.stageName ?? stageName
        copy.stepName = place.stepName ?? stepName
        copy.startedAt = place.startedAt ?? startedAt
        return copy
    }

    // MARK: Wording

    /// ManualValidation steps are resumed; environment checks are approved.
    public var approveVerb: String { kind == .manualValidation ? "Resume" : "Approve" }
    public var rejectVerb: String { "Reject" }

    public var kindTitle: String { kind == .manualValidation ? "Manual validation" : "Environment approval" }

    /// What the confirmation dialog names: the step, its stage, and the run.
    public func target(runName: String) -> String {
        var parts: [String] = []
        if let stepName, !stepName.isEmpty { parts.append("\u{201C}\(stepName)\u{201D}") }
        if let stageName, !stageName.isEmpty { parts.append("in stage \(stageName)") }
        parts.append(parts.isEmpty ? runName : "of \(runName)")
        return parts.joined(separator: " ")
    }

    public func confirmationTitle(approve: Bool, runName: String) -> String {
        "\(approve ? approveVerb : rejectVerb) \(target(runName: runName))?"
    }

    public func confirmationMessage(approve: Bool) -> String {
        if approve {
            return kind == .manualValidation
                ? "The run continues past this step. This is recorded under your name."
                : "The run is allowed to deploy. This is recorded under your name."
        }
        return "The run stops at this step and is marked failed. This is recorded under your name."
    }

    // MARK: Timing

    public var waitingSince: Date? { startedAt ?? createdOn }

    public func waitingDuration(now: Date = Date()) -> TimeInterval? {
        guard let waitingSince else { return nil }
        return max(0, now.timeIntervalSince(waitingSince))
    }

    public var deadline: Date? {
        guard let minutes = settings?.timeoutMinutes, let waitingSince else { return nil }
        return waitingSince.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// "Times out in 3d 4h; the run then resumes."
    public func timeoutSummary(now: Date = Date()) -> String? {
        guard let deadline, let action = settings?.onTimeout else { return nil }
        let left = deadline.timeIntervalSince(now)
        if left <= 0 { return "Timed out; \(action.outcome)." }
        return "Times out in \(Self.format(left)); then \(action.outcome)."
    }

    public static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "under a minute" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
