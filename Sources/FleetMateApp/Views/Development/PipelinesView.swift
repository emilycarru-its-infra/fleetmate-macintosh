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
                    Spacer()
                    if let at = model.pipelinesLoadedAt {
                        Text("Checked \(DevelopmentView.relative(at))")
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
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
                            PipelineRunRow(run: run, isSelected: model.selectedRun?.id == run.id) {
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
                    .frame(width: 18)
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
                            Image(systemName: "arrow.triangle.branch").appFont(fixed: 8).foregroundStyle(.tertiary)
                            Text(branch)
                                .appFont(.caption2, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let who = run.triggeredBy {
                            Text("·").foregroundStyle(.tertiary)
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
                            .foregroundStyle(.tertiary)
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
        .contextMenu {
            Button("Open in Browser") {
                if let url = URL(string: run.webUrl) { NSWorkspace.shared.open(url) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.webUrl, forType: .string)
            }
        }
    }
}

// MARK: - Run detail

/// One run: header with the verbs, then the log split into the provider's
/// sections, each collapsible, failed ones open by default.
struct PipelineRunDetailView: View {
    let run: PipelineRun
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
            content
        }
        .task { await load() }
        .alert("Action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("Cancel \(run.pipelineName) \(run.runNumber)?", isPresented: $pendingCancel) {
            Button("Cancel run", role: .destructive) { perform("Cancel") }
            Button("Keep running", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.status.symbolName)
                .appFont(.title3)
                .foregroundStyle(run.status.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.pipelineName).appFont(.title3, weight: .semibold).lineLimit(1)
                    Text(run.runNumber).appFont(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Text(run.status.displayName)
                        .appFont(fixed: 9, weight: .medium)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(run.status.tint.opacity(0.15))
                        .foregroundStyle(run.status.tint)
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
                        Text(String(sha.prefix(8))).appFont(.caption, design: .monospaced).foregroundStyle(.tertiary)
                    }
                    if let who = run.triggeredBy {
                        Text("·").foregroundStyle(.tertiary)
                        Text(who).appFont(.caption).foregroundStyle(.secondary)
                    }
                    if let started = run.startedAt {
                        Text("·").foregroundStyle(.tertiary)
                        Text(started.formatted(date: .abbreviated, time: .shortened)).appFont(.caption).foregroundStyle(.tertiary)
                    }
                    if let duration = run.duration {
                        Text(Self.format(duration)).appFont(.caption).monospacedDigit().foregroundStyle(.tertiary)
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
            Button {
                if let url = URL(string: run.webUrl) { NSWorkspace.shared.open(url) }
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
                        .appFont(.caption2).monospacedDigit().foregroundStyle(.tertiary)
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
