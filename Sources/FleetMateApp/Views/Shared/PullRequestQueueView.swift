import SwiftUI
import AppKit
import FleetMateCore

// MARK: - View Model

/// Loads the signed-in user's pull requests from every configured provider and
/// keeps them in the shape the dashboard queue renders.
@MainActor
final class PullRequestQueueModel: ObservableObject {
    @Published private(set) var queue = PullRequestQueue()
    @Published private(set) var isLoading = false
    @Published private(set) var lastLoaded: Date?

    /// Providers the user has turned off in the section's filter.
    @Published var hiddenSources: Set<PullRequestSource> = []

    private var loadTask: Task<Void, Never>?

    var visiblePullRequests: [UnifiedPullRequest] {
        queue.pullRequests.filter { !hiddenSources.contains($0.source) }
    }

    func section(_ relation: PullRequestRelation) -> [UnifiedPullRequest] {
        visiblePullRequests
            .filter { $0.relations.contains(relation) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var errors: [PullRequestQueueError] {
        queue.errors.filter { !hiddenSources.contains($0.source) }
    }

    /// Which providers we actually attempted, so the section can hide filter
    /// chips for systems that aren't wired up at all.
    @Published private(set) var availableSources: Set<PullRequestSource> = []

    func load(appState: AppState, force: Bool = false) {
        if isLoading && !force { return }
        loadTask?.cancel()
        loadTask = Task { await self.performLoad(appState: appState) }
    }

    private func performLoad(appState: AppState) async {
        isLoading = true
        defer { isLoading = false }

        let devOpsReady = appState.config.isDevOpsConfigured && appState.devOpsService.hasValidToken
        let gitHubConfig = appState.config.tasks?.providers.github ?? GitHubProviderConfig()

        var sources: Set<PullRequestSource> = []
        if devOpsReady { sources.insert(.azureDevOps) }
        sources.insert(.gitHub)
        availableSources = sources

        var merged = PullRequestQueue()

        // Azure DevOps runs on the shared, token-injected service (main-actor
        // bound); GitHub is an actor and can run concurrently with it.
        let gitHubTask = Task.detached(priority: .userInitiated) {
            await GitHubPullRequestService(config: gitHubConfig).getMyPullRequests()
        }

        if devOpsReady {
            do {
                merged.merge(try await appState.devOpsService.getMyPullRequests())
            } catch {
                merged.errors.append(
                    PullRequestQueueError(source: .azureDevOps, message: error.localizedDescription)
                )
            }
        }

        merged.merge(await gitHubTask.value)

        guard !Task.isCancelled else { return }
        queue = merged
        lastLoaded = Date()
    }

    func toggle(_ source: PullRequestSource) {
        if hiddenSources.contains(source) {
            hiddenSources.remove(source)
        } else {
            hiddenSources.insert(source)
        }
    }
}

// MARK: - Section

/// The dashboard's "My pull requests" queue — one list per relation, mirroring
/// the Azure DevOps web queue but spanning every DevOps project and every GitHub
/// repository the user can see.
struct PullRequestQueueSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var model: PullRequestQueueModel

    @AppStorage("dashboard.prQueue.collapsed.createdByMe") private var createdCollapsed = false
    @AppStorage("dashboard.prQueue.collapsed.assignedToMe") private var assignedCollapsed = false
    @State private var expandedSections: Set<PullRequestRelation> = []

    private let collapsedRowLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ForEach(model.errors) { error in
                Label("\(error.source.displayName): \(error.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            group(.createdByMe, isCollapsed: $createdCollapsed)
            group(.assignedToMe, isCollapsed: $assignedCollapsed)

            if !model.isLoading && model.visiblePullRequests.isEmpty {
                emptyState
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("My pull requests").font(.headline)

            if model.isLoading {
                ProgressView().controlSize(.mini)
            }

            Spacer()

            ForEach(PullRequestSource.allCases, id: \.self) { source in
                if model.availableSources.contains(source) {
                    sourceChip(source)
                }
            }

            Button(action: { model.load(appState: appState, force: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh pull requests")
            .disabled(model.isLoading)
        }
    }

    private func sourceChip(_ source: PullRequestSource) -> some View {
        let isOn = !model.hiddenSources.contains(source)
        let count = model.queue.pullRequests.filter { $0.source == source }.count
        return Button(action: { model.toggle(source) }) {
            HStack(spacing: 4) {
                Image(systemName: source.symbolName).font(.system(size: 9))
                Text("\(count)").font(.caption2.monospacedDigit())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? source.tint.opacity(0.15) : Color.secondary.opacity(0.1))
            .foregroundStyle(isOn ? source.tint : Color.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide \(source.displayName)" : "Show \(source.displayName)")
    }

    // MARK: Groups

    @ViewBuilder
    private func group(_ relation: PullRequestRelation, isCollapsed: Binding<Bool>) -> some View {
        let items = model.section(relation)
        if !items.isEmpty {
            let isExpanded = expandedSections.contains(relation)
            let visible = isExpanded ? items : Array(items.prefix(collapsedRowLimit))

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: { isCollapsed.wrappedValue.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isCollapsed.wrappedValue ? -90 : 0))
                            Text(relation.sectionTitle).font(.subheadline.weight(.semibold))
                            Text("\(items.count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isCollapsed.wrappedValue {
                        Divider()
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, pr in
                            PullRequestRow(pullRequest: pr)
                            if index < visible.count - 1 { Divider() }
                        }

                        if items.count > collapsedRowLimit {
                            Divider()
                            Button(action: {
                                if isExpanded { expandedSections.remove(relation) }
                                else { expandedSections.insert(relation) }
                            }) {
                                Text(isExpanded ? "Show less" : "Show \(items.count - collapsedRowLimit) more")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        GroupBox {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("No open pull requests")
                    .font(.callout)
                Text("Nothing waiting on you across Azure DevOps or GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Row

struct PullRequestRow: View {
    let pullRequest: UnifiedPullRequest
    @State private var isHovering = false

    private let maxReviewerBubbles = 4

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(pullRequest.source.tint)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                Image(systemName: pullRequest.source.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(pullRequest.source.tint)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pullRequest.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        statusPills
                    }
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                reviewerBubbles

                HStack(spacing: 3) {
                    Image(systemName: "bubble.left").font(.system(size: 9))
                    Text("\(pullRequest.commentCount)").font(.caption2.monospacedDigit())
                }
                .foregroundStyle(pullRequest.commentCount > 0 ? .secondary : .tertiary)
                .frame(width: 34, alignment: .trailing)

                Text(timestampLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 116, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 4)
            .background(isHovering ? Color.secondary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(pullRequest.webUrl)
        .contextMenu {
            Button("Open in Browser") { open() }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.webUrl, forType: .string)
            }
        }
    }

    // MARK: Row parts

    @ViewBuilder
    private var statusPills: some View {
        if pullRequest.state == .draft { pill("Draft", color: .secondary) }
        if pullRequest.hasConflicts { pill("Conflicts", color: .red) }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            Text("\(pullRequest.authorName) request \(pullRequest.reference) into")
                .lineLimit(1)
            Image(systemName: "shippingbox").font(.system(size: 9))
            Text("\(pullRequest.container)/\(pullRequest.repository)")
                .lineLimit(1)
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
            Text(pullRequest.targetBranch)
                .lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var reviewerBubbles: some View {
        let shown = Array(pullRequest.reviewers.prefix(maxReviewerBubbles))
        let overflow = pullRequest.reviewers.count - shown.count
        if !shown.isEmpty {
            HStack(spacing: -4) {
                ForEach(shown) { reviewer in
                    Text(reviewer.initials)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(reviewer.vote.tint))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .help("\(reviewer.displayName) — \(reviewer.vote.label)")
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.secondary.opacity(0.2)))
                }
            }
            .padding(.top, 1)
        }
    }

    /// "Updated 10h ago" once there has been activity, "Created 9h ago" before —
    /// the same wording the Azure DevOps queue uses.
    private var timestampLabel: String {
        if pullRequest.wasUpdatedAfterCreation, let updated = pullRequest.updatedAt {
            return "Updated \(Self.relative(updated))"
        }
        if let created = pullRequest.createdAt {
            return "Created \(Self.relative(created))"
        }
        return ""
    }

    private func open() {
        guard let url = URL(string: pullRequest.webUrl) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func relative(_ date: Date) -> String {
        let span = Date().timeIntervalSince(date)
        if span < 120 { return "just now" }
        if span < 3600 { return "\(Int(span / 60))m ago" }
        if span < 86400 { return "\(Int(span / 3600))h ago" }
        if span < 604800 { return "\(Int(span / 86400))d ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}

// MARK: - Presentation helpers

extension PullRequestSource {
    var tint: Color {
        switch self {
        case .azureDevOps: return Color(red: 0.0, green: 0.47, blue: 0.83)
        case .gitHub:      return Color(red: 0.45, green: 0.36, blue: 0.78)
        }
    }
}

extension PullRequestReviewVote {
    var tint: Color {
        switch self {
        case .approved, .approvedWithSuggestions: return .green
        case .rejected:                            return .red
        case .waitingForAuthor:                    return .orange
        case .noVote:                              return .gray
        }
    }

    var label: String {
        switch self {
        case .approved:                return "Approved"
        case .approvedWithSuggestions: return "Approved with suggestions"
        case .waitingForAuthor:        return "Waiting for author"
        case .rejected:                return "Rejected"
        case .noVote:                  return "No vote"
        }
    }
}
