import SwiftUI
import AppKit
import FleetMateCore
import DevMateAzure
import DevMateCore
import DevMateGitHub
import DevMateUI

// MARK: - Pipelines list

/// Every recent run across all Azure DevOps projects and the active GitHub
/// repositories, newest first, with status and source filters.
struct PipelinesListView: View {
    @ObservedObject var model: DevelopmentModel
    @EnvironmentObject private var appState: AppState
    let searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoadingPipelines { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if model.availableSources.count > 1 {
                        ForEach(PullRequestSource.allCases, id: \.self) { source in
                            if model.availableSources.contains(source) {
                                chip(title: source.shortName, count: model.pipelineCount(for: source), tint: source.tint,
                                     isSelected: model.selectedSource == source) { model.toggleSource(source) }
                            }
                        }
                    }
                    if model.pipelineRepositoryOptions.count > 1 || model.selectedPipelineRepo != nil {
                        RepoFilterMenu(selection: $model.selectedPipelineRepo, entries: model.pipelineRepositoryOptions)
                    }
                    Spacer()
                    if let at = model.pipelinesLoadedAt {
                        Text("Checked \(DevelopmentView.relative(at))")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    if model.approvalRunCount > 0 || model.approvalFilter {
                        chip(title: "Approval", count: model.approvalRunCount, tint: .orange,
                             isSelected: model.approvalFilter) { model.approvalFilter.toggle() }
                            .help("Runs waiting for an approval")
                    }
                    ForEach([PipelineRunStatus.running, .failed, .succeeded], id: \.self) { status in
                        chip(title: status.displayName, count: model.pipelineCount(for: status), tint: status.tint,
                             isSelected: model.pipelineStatusFilter == status) { model.togglePipelineStatus(status) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            let runs = model.visiblePipelineRuns(matching: searchText)
            if runs.isEmpty {
                VStack(spacing: 8) {
                    if model.isLoadingPipelines {
                        ProgressView()
                        Text("Loading runs…").appFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "play.circle").appFont(.title2).foregroundStyle(.secondary)
                        Text(model.pipelineRuns.isEmpty ? "No runs in the last 7 days." : "Nothing matches.")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(runs) { run in
                            PipelineRunRow(
                                run: run,
                                isSelected: model.selectedRun?.id == run.id,
                                awaitingApproval: model.isAwaitingApproval(run),
                                onReviewApproval: {
                                    model.selectedRun = run
                                    model.reviewingApprovalRunID = run.id
                                }
                            ) {
                                model.selectedRun = run
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            if let error = model.pipelinesError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .appFont(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
    }
}

extension PipelinesListView {
    func chip(title: String, count: Int?, tint: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).appFont(.caption2, weight: .medium)
                if let count {
                    Text("\(count)")
                        .appFont(.caption2).monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? tint : Color.secondary.opacity(0.1))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : tint.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PipelineRunRow: View {
    let run: PipelineRun
    let isSelected: Bool
    var awaitingApproval = false
    var onReviewApproval: (() -> Void)?
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Rectangle()
                    .fill(run.source.tint)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                Image(systemName: run.status.symbolName)
                    .appFont(fixed: 13)
                    .foregroundStyle(run.status.tint)
                    .overlay(alignment: .bottomTrailing) {
                        if awaitingApproval { ApprovalBadge().offset(x: 5, y: 5) }
                    }
                    .frame(width: 18)
                    .help(awaitingApproval ? "Waiting for approval" : run.status.displayName)
                    .accessibilityLabel(awaitingApproval ? "Waiting for approval" : run.status.displayName)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(run.pipelineName)
                            .appFont(fixed: 12, weight: .semibold)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(run.runNumber)
                            .appFont(fixed: 10)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(run.repository.map { "\(run.container)/\($0)" } ?? run.container)
                            .appFont(.caption2, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let branch = run.branch {
                            Image(systemName: "arrow.triangle.branch").appFont(fixed: 8).foregroundStyle(.secondary)
                            Text(branch)
                                .appFont(.caption2, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let who = run.triggeredBy {
                            Text("·").foregroundStyle(.secondary)
                            Text(who).appFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DevelopmentView.relative(run.sortDate))
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let duration = run.duration {
                        Text(PipelineRunDetailView.format(duration))
                            .appFont(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.secondary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .agentContextDrag { .pipelineRun(run) }
        .contextMenu {
            if awaitingApproval, let onReviewApproval {
                Button("Review Approval…", action: onReviewApproval)
                Divider()
            }
            AgentContextMenuItems(.pipelineRun(run))
            Divider()
            Button("Open in Browser") {
                if let url = URL(string: run.webUrl) { NSWorkspace.shared.openInBrowser(url) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.webUrl, forType: .string)
            }
        }
    }
}

// MARK: - Approvals

/// Small hand on a run's status icon while an approval holds it. A symbol,
/// never a count, and never red.
struct ApprovalBadge: View {
    var body: some View {
        Image(systemName: "hand.raised.circle.fill")
            .appFont(fixed: 10)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .orange)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
            .accessibilityHidden(true)
    }
}

/// The Review panel, opened from a run's context menu: the same card the
/// run's log shows, for the first approval waiting on the run.
struct ApprovalReviewSheet: View {
    let run: PipelineRun
    @ObservedObject var model: DevelopmentModel

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review \(run.pipelineName) \(run.runNumber)").appFont(.title3, weight: .semibold).lineLimit(1)
            if let approval = model.approvals(for: run).first {
                RunApprovalCard(approval: RunApproval(approval), runName: "\(run.pipelineName) \(run.runNumber)") { approve, comment in
                    try await model.respond(to: approval, approve: approve, comment: comment, appState: appState)
                    if model.approvals(for: run).isEmpty { dismiss() }
                }
                if model.approvals(for: run).count > 1 {
                    Text("\(model.approvals(for: run).count - 1) more after this one")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            } else {
                Text("Nothing is waiting for approval on this run.").appFont(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

// MARK: - Run detail

/// One run: the header with the verbs, then the run's stages, jobs and steps
/// in a sidebar with the selected one's log beside it. The outline, the log
/// and the approval card are DevMate's; this view supplies the header, the
/// sign-in and the approvals FleetMate already tracks.
struct PipelineRunDetailView: View {
    let run: PipelineRun
    @ObservedObject var model: DevelopmentModel
    /// Called after Rerun or Cancel so the list refreshes.
    var onChanged: (() -> Void)?

    @EnvironmentObject private var appState: AppState

    var body: some View {
        PipelineRunOutline(run: run, model: model, appState: appState, onChanged: onChanged)
            .id(run.id)
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

private struct PipelineRunOutline: View {
    let run: PipelineRun
    @ObservedObject var model: DevelopmentModel
    let appState: AppState
    var onChanged: (() -> Void)?

    @StateObject private var detail: RunDetailModel
    @State private var legacyLog: PipelineRunLog?
    @State private var runningVerb: String?
    @State private var actionError: String?
    @State private var pendingCancel = false
    @StateObject private var anchor = ClipboardAnchor()

    init(run: PipelineRun, model: DevelopmentModel, appState: AppState, onChanged: (() -> Void)?) {
        self.run = run
        self.model = model
        self.appState = appState
        self.onChanged = onChanged
        _detail = StateObject(wrappedValue: RunDetailModel(
            provider: FleetRunDetail.make(run: run, model: model, appState: appState),
            runName: "\(run.pipelineName) \(run.runNumber)",
            pollInterval: .seconds(10)
        ))
    }

    var body: some View {
        RunDetailView(model: detail) { header }
            .task(id: run.id) {
                if run.source == .azureDevOps, run.status.isActive {
                    await model.refreshApprovals(appState: appState, projects: [run.container])
                }
            }
            .sheet(isPresented: reviewBinding) {
                ApprovalReviewSheet(run: run, model: model)
                    .environmentObject(appState)
            }
            .actionErrorBanner($actionError)
            .confirmationDialog("Cancel \(run.pipelineName) \(run.runNumber)?", isPresented: $pendingCancel) {
                Button("Cancel run", role: .destructive) { perform("Cancel") }
                Button("Keep running", role: .cancel) {}
            }
    }

    private var approvals: [PipelineApproval] { model.approvals(for: run) }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { model.reviewingApprovalRunID == run.id && !approvals.isEmpty },
            set: { if !$0 { model.reviewingApprovalRunID = nil } }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.status.symbolName)
                .appFont(.title3)
                .foregroundStyle(run.status.tint)
                .overlay(alignment: .bottomTrailing) {
                    if !approvals.isEmpty { ApprovalBadge().offset(x: 5, y: 5) }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.pipelineName).appFont(.title3, weight: .semibold).lineLimit(1)
                    Text(run.runNumber).appFont(.callout).monospacedDigit().foregroundStyle(.secondary)
                    let statusTint = approvals.isEmpty ? run.status.tint : .orange
                    Text(approvals.isEmpty ? run.status.displayName : "Waiting for approval")
                        .appFont(fixed: 9, weight: .medium)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(statusTint.opacity(0.15))
                        .foregroundStyle(statusTint)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                HStack(spacing: 6) {
                    Text(run.repository.map { "\(run.container)/\($0)" } ?? run.container)
                        .appFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                    if let branch = run.branch {
                        Image(systemName: "arrow.triangle.branch").appFont(.caption2).foregroundStyle(.secondary)
                        Text(branch).appFont(.caption, design: .monospaced).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let sha = run.commitSha {
                        Text(String(sha.prefix(8))).appFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                    }
                    if let who = run.triggeredBy {
                        Text("·").foregroundStyle(.secondary)
                        Text(who).appFont(.caption).foregroundStyle(.secondary)
                    }
                    if let started = run.startedAt {
                        Text("·").foregroundStyle(.secondary)
                        Text(started.formatted(date: .abbreviated, time: .shortened)).appFont(.caption).foregroundStyle(.secondary)
                    }
                    if let duration = run.duration {
                        Text(PipelineRunDetailView.format(duration)).appFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if run.status.isActive {
                verbButton("Cancel", icon: "xmark", tint: .orange) { pendingCancel = true }
            } else {
                verbButton("Rerun", icon: "arrow.clockwise", tint: .green) { perform("Rerun") }
            }
            Button {
                legacyLog = nil
                Task { await detail.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload the run")
            Menu {
                Button("Copy Failed Stages") { copyStages(failedOnly: true) }
                Button("Copy All Stages") { copyStages(failedOnly: false) }
                if !AppEdition.current.isTicketsOnly {
                    Divider()
                    Button("Send Failed Stages to Agent") { send(failedOnly: true) }
                }
            } label: {
                Label("Copy Stages", systemImage: "doc.on.doc")
            } primaryAction: {
                copyStages(failedOnly: nil)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy the failed stages' logs, with the run's details; the menu has more")
            .accessibilityLabel("Copy failed stages")
            AgentContextButton(.pipelineRun(run))
            Button {
                if let url = URL(string: run.webUrl) { NSWorkspace.shared.openInBrowser(url) }
            } label: {
                Image(systemName: "globe")
            }
            .help("Open in browser")
        }
        .padding(14)
        .background(ClipboardAnchorView(anchor: anchor).accessibilityHidden(true))
    }

    /// The run's whole log in the provider's sections, read once for Copy and
    /// Send, which work on stages; the outline itself reads one step at a time.
    private func sections() async -> PipelineRunLog? {
        if let legacyLog { return legacyLog }
        let loaded: PipelineRunLog?
        switch run.source {
        case .gitHub:
            let actions = GitHubActionsService(config: appState.config.tasks?.providers.github ?? GitHubProviderConfig())
            loaded = try? await actions.getRunLog(owner: run.container, repo: run.repository ?? "", runId: run.runId)
        case .azureDevOps:
            loaded = try? await appState.devOpsService.getPipelineRunLog(project: run.container, buildId: run.runId)
        }
        legacyLog = loaded
        return loaded
    }

    /// `failedOnly` nil copies the failed stages, or all of them when none failed.
    private func copyStages(failedOnly: Bool?) {
        Task {
            guard let log = await sections() else {
                actionError = "Could not read the log of \(run.pipelineName) \(run.runNumber)."
                return
            }
            let failed = PipelineStageReport.failed(log.sections)
            let stages = failedOnly == true ? failed : failedOnly == false ? log.sections : (failed.isEmpty ? log.sections : failed)
            guard !stages.isEmpty else { return }
            let text = PipelineStageReport.copy(run, stages: stages)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardPreview.show(text, heading: stages.count == 1 ? "Copied \(stages[0].name)" : "Copied \(stages.count) stages",
                                  anchor: anchor.view)
        }
    }

    /// Hand the stages to the agent in the run's repository: a short prompt,
    /// with the whole text in a private temporary file it can read.
    private func send(failedOnly: Bool) {
        Task {
            guard let log = await sections() else {
                actionError = "Could not read the log of \(run.pipelineName) \(run.runNumber)."
                return
            }
            let failed = PipelineStageReport.failed(log.sections)
            let stages = failedOnly ? failed : log.sections
            let file = Self.writeFullLog(PipelineStageReport.copy(run, stages: stages.isEmpty ? log.sections : stages), run: run)
            appState.sendPipelineReport(PipelineStageReport.prompt(run, stages: stages, fullLog: file), for: run, anchor: anchor.view)
        }
    }

    /// The full text in a file only this user can read, under the temporary
    /// folder, or nil when it could not be written.
    static func writeFullLog(_ text: String, run: PipelineRun) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetmate-pipeline-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("run-\(run.runId)-\(UUID().uuidString.prefix(8)).log")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return file.path
    }

    private func verbButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if runningVerb == title {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).appFont(fixed: 9, weight: .bold)
                }
                Text(title).appFont(fixed: 11, weight: .medium)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(runningVerb != nil)
    }

    private func perform(_ verb: String) {
        runningVerb = verb
        Task {
            defer { runningVerb = nil }
            do {
                switch (run.source, verb) {
                case (.gitHub, "Rerun"):
                    try await actions().rerun(owner: run.container, repo: run.repository ?? "", runId: run.runId)
                case (.gitHub, "Cancel"):
                    try await actions().cancel(owner: run.container, repo: run.repository ?? "", runId: run.runId)
                case (.azureDevOps, "Rerun"):
                    guard let definition = run.pipelineId else { throw AzDevOpsError.invalidUrl("no definition") }
                    _ = try await appState.devOpsService.rerunPipeline(project: run.container, definitionId: definition, branch: run.branch)
                case (.azureDevOps, "Cancel"):
                    try await appState.devOpsService.cancelPipelineRun(project: run.container, buildId: run.runId)
                default:
                    break
                }
                onChanged?()
            } catch {
                actionError = "Could not \(verb.lowercased()) \(run.pipelineName) \(run.runNumber): \(error.localizedDescription)"
            }
        }
    }

    private func actions() -> GitHubActionsService {
        GitHubActionsService(config: appState.config.tasks?.providers.github ?? GitHubProviderConfig())
    }
}

// MARK: - DevMate adapter

extension RunApproval {
    /// FleetMate's pending approval in DevMate's shape.
    init(_ approval: PipelineApproval) {
        self.init(
            id: approval.id,
            kind: approval.kind == .manualValidation ? .manualValidation : .environment,
            instructions: approval.instructions,
            createdAt: approval.createdOn,
            approvers: approval.approvers,
            minRequiredApprovers: approval.minRequiredApprovers,
            stageName: approval.stageName,
            stepName: approval.stepName,
            startedAt: approval.startedAt,
            timeoutMinutes: approval.settings?.timeoutMinutes,
            resumesOnTimeout: approval.settings?.onTimeout == .resume
        )
    }
}

/// Reads a run's stages, jobs, steps and logs through DevMate, signed in with
/// FleetMate's own token, and answers approvals through the tracking and the
/// verbs FleetMate already has.
struct FleetRunDetail: RunDetailProvider {
    let inner: any RunDetailProvider
    let pending: @Sendable () async -> [RunApproval]
    let answer: @Sendable (_ approval: RunApproval, _ approve: Bool, _ comment: String) async throws -> Void

    @MainActor
    static func make(run: PipelineRun, model: DevelopmentModel, appState: AppState) -> FleetRunDetail {
        let inner: any RunDetailProvider
        switch run.source {
        case .azureDevOps:
            let service = appState.devOpsService
            inner = AzureRunDetail(organization: service.baseUrl, project: run.container, buildID: run.runId) {
                guard let token = await service.currentToken(), !token.isEmpty else {
                    throw RunDetailError("Sign in to Azure DevOps to read this run.")
                }
                return token
            }
        case .gitHub:
            let actions = GitHubActionsService(config: appState.config.tasks?.providers.github ?? GitHubProviderConfig())
            inner = GitHubRunDetail(repository: "\(run.container)/\(run.repository ?? "")", runID: run.runId) { path in
                try await actions.readText(path: "/" + path)
            }
        }
        return FleetRunDetail(
            inner: inner,
            pending: { @MainActor in
                if run.source == .azureDevOps, run.status.isActive {
                    await model.refreshApprovals(appState: appState, projects: [run.container])
                }
                return model.approvals(for: run).map(RunApproval.init)
            },
            answer: { @MainActor approval, approve, comment in
                guard let match = model.approvals(for: run).first(where: { $0.id == approval.id }) else {
                    throw RunDetailError("This approval is no longer waiting.")
                }
                try await model.respond(to: match, approve: approve, comment: comment, appState: appState)
            }
        )
    }

    func timeline() async throws -> RunTimeline { try await inner.timeline() }
    func log(job: RunJob, step: RunStep?) async throws -> String { try await inner.log(job: job, step: step) }
    func taskDetails(job: RunJob, step: RunStep) async throws -> [(name: String, value: String)] {
        try await inner.taskDetails(job: job, step: step)
    }
    func approvals() async throws -> [RunApproval] { await pending() }
    func respond(to approval: RunApproval, approve: Bool, comment: String) async throws {
        try await answer(approval, approve, comment)
    }
}

extension PipelineRunStatus {
    var symbolName: String {
        switch self {
        case .queued: return "clock"
        case .running: return "circle.dotted.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .partial: return "exclamationmark.circle"
        case .skipped: return "arrow.right.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Orange for failures — the app has no red badges.
    var tint: Color {
        switch self {
        case .queued: return .secondary
        case .running: return .yellow
        case .succeeded: return .green
        case .failed: return .orange
        case .cancelled, .skipped, .unknown: return .secondary
        case .partial: return .orange
        }
    }
}
