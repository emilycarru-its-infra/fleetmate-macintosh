import SwiftUI
import AppKit
import FleetMateCore

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

/// The Review panel: the pipeline's instructions, an optional comment, and
/// Approve or Reject. Rejecting asks first, because it fails the run.
struct ApprovalReviewSheet: View {
    let run: PipelineRun
    @ObservedObject var model: DevelopmentModel

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var working: Bool?
    @State private var error: String?
    @State private var confirmReject = false

    private var approval: PipelineApproval? { model.approvals(for: run).first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Review \(run.pipelineName) \(run.runNumber)").appFont(.title3, weight: .semibold).lineLimit(1)
            }
            if let approval {
                HStack(spacing: 6) {
                    if let created = approval.createdOn {
                        Text("Waiting since \(created.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if !approval.approvers.isEmpty {
                        Text("·")
                        Text("Approvers: \(approval.approvers.joined(separator: ", "))").lineLimit(1)
                    }
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)

                ScrollView {
                    Text(approval.instructions.isEmpty ? "No instructions given." : approval.instructions)
                        .appFont(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 120, maxHeight: 320)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

                TextField("Comment (optional)", text: $comment, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .appFont(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    if model.approvals(for: run).count > 1 {
                        Text("\(model.approvals(for: run).count - 1) more after this one")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        confirmReject = true
                    } label: {
                        if working == false { ProgressView().controlSize(.small) } else { Text("Reject") }
                    }
                    .tint(.orange)
                    Button {
                        respond(approval, approve: true)
                    } label: {
                        if working == true { ProgressView().controlSize(.small) } else { Text("Approve") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Approve (⌘↩)")
                }
                .disabled(working != nil)
                .confirmationDialog("Reject \(run.pipelineName) \(run.runNumber)?", isPresented: $confirmReject) {
                    Button("Reject") { respond(approval, approve: false) }
                    Button("Keep waiting", role: .cancel) {}
                } message: {
                    Text("The run stops at this step.")
                }
            } else {
                Text("Nothing is waiting for approval on this run.").appFont(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func respond(_ approval: PipelineApproval, approve: Bool) {
        working = approve
        error = nil
        Task {
            defer { working = nil }
            do {
                try await model.respond(to: approval, approve: approve, comment: comment, appState: appState)
                comment = ""
                if model.approvals(for: run).isEmpty { dismiss() }
            } catch {
                self.error = "Could not \(approve ? "approve" : "reject"): \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Run detail

/// One run: header with the verbs, then the log split into the provider's
/// sections, each collapsible, failed ones open by default.
struct PipelineRunDetailView: View {
    let run: PipelineRun
    @ObservedObject var model: DevelopmentModel
    /// Called after Rerun or Cancel so the list refreshes.
    var onChanged: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @State private var log: PipelineRunLog?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var runningVerb: String?
    @State private var actionError: String?
    @State private var pendingCancel = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !approvals.isEmpty {
                approvalBanner
                Divider()
            }
            content
        }
        .task(id: run.id) { await load() }
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

    private var approvalBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(approvals.count == 1
                 ? "1 approval needs your review before this run can continue"
                 : "\(approvals.count) approvals need your review before this run can continue")
                .appFont(.callout)
            Spacer()
            Button("Review…") { model.reviewingApprovalRunID = run.id }
                .buttonStyle(.borderedProminent)
                .help("Read the instructions, then approve or reject")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
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
                        Text(Self.format(duration)).appFont(.caption).monospacedDigit().foregroundStyle(.secondary)
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
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Reload the log")
            AgentContextButton(.pipelineRun(run))
            Button {
                if let url = URL(string: run.webUrl) { NSWorkspace.shared.openInBrowser(url) }
            } label: {
                Image(systemName: "globe")
            }
            .help("Open in browser")
        }
        .padding(14)
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

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView("Couldn't load the log", systemImage: "exclamationmark.triangle", description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let log {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if log.truncated {
                        Text("Long log — each section shows its tail.")
                            .appFont(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if log.sections.isEmpty {
                        Text("No log output yet.").appFont(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(log.sections) { section in
                        logSection(section)
                    }
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading log…").appFont(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func logSection(_ section: PipelineRunLog.Section) -> some View {
        let isOpen = expanded.contains(section.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(section.id) } else { expanded.insert(section.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appFont(fixed: 9, weight: .bold)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Image(systemName: section.status.symbolName)
                        .appFont(fixed: 11)
                        .foregroundStyle(section.status.tint)
                    Text(section.name).appFont(.callout, weight: .medium).lineLimit(1)
                    Spacer()
                    Text("\(section.text.split(separator: "\n").count) lines")
                        .appFont(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Divider()
                ScrollView(.horizontal) {
                    Text(section.text)
                        .appFont(fixed: 11, design: .monospaced)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 520)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.15)))
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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: PipelineRunLog
            switch run.source {
            case .gitHub:
                loaded = try await actions().getRunLog(owner: run.container, repo: run.repository ?? "", runId: run.runId)
            case .azureDevOps:
                loaded = try await appState.devOpsService.getPipelineRunLog(project: run.container, buildId: run.runId)
            }
            log = loaded
            loadError = nil
            // Failed steps open; on a green run open the last one, which is
            // where the interesting output usually is.
            let failed = loaded.sections.filter { $0.status == .failed }.map(\.id)
            expanded = failed.isEmpty ? Set(loaded.sections.suffix(1).map(\.id)) : Set(failed)
        } catch {
            loadError = error.localizedDescription
        }
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
