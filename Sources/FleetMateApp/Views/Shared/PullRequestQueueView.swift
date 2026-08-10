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

    /// The provider the queue is filtered to, or nil for all of them. Selecting
    /// the active filter again clears it. DevOps is the working queue here —
    /// it starts active, with GitHub visible one click away.
    @Published var selectedSource: PullRequestSource? = .azureDevOps

    /// Narrow the queue to one repository (secondary pill row); nil = all.
    @Published var selectedRepo: String?

    /// Once the user picks a pill themselves, loads stop re-asserting the
    /// DevOps-first default. Without this, the first load — which runs before
    /// DevOps SSO lands — would clear the default and it would never return.
    private var userTouchedFilter = false

    private var loadTask: Task<Void, Never>?

    /// Last successful GitHub fetch, kept so a rate-limited refresh degrades to
    /// stale rows instead of an empty section.
    private var cachedGitHub: PullRequestQueue?
    /// While set (and in the future), GitHub is not queried at all — GraphQL
    /// rate limits are per-hour, so hammering it just resets nothing.
    private var gitHubBackoffUntil: Date?

    /// Source-filtered but not repo-filtered — what the repo pills count over.
    var sourcePullRequests: [UnifiedPullRequest] {
        guard let selectedSource else { return queue.pullRequests }
        return queue.pullRequests.filter { $0.source == selectedSource }
    }

    var visiblePullRequests: [UnifiedPullRequest] {
        guard let selectedRepo else { return sourcePullRequests }
        return sourcePullRequests.filter { $0.repository == selectedRepo }
    }

    /// Repositories in the current source scope with their PR counts, busiest
    /// first — the secondary filter row. Hidden unless there's a real choice.
    var repoCounts: [(repo: String, count: Int)] {
        var counts: [String: Int] = [:]
        for pr in sourcePullRequests { counts[pr.repository, default: 0] += 1 }
        guard counts.count > 1 else { return [] }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    func toggleRepo(_ repo: String) {
        selectedRepo = (selectedRepo == repo) ? nil : repo
    }

    func section(_ relation: PullRequestRelation) -> [UnifiedPullRequest] {
        visiblePullRequests
            .filter { $0.relations.contains(relation) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var errors: [PullRequestQueueError] {
        guard let selectedSource else { return queue.errors }
        return queue.errors.filter { $0.source == selectedSource }
    }

    /// How many PRs a given provider contributed, before filtering — the pills
    /// show totals so the counts don't change as you click between them.
    func count(for source: PullRequestSource) -> Int {
        queue.pullRequests.filter { $0.source == source }.count
    }

    /// Which providers we actually attempted, so the section can hide filter
    /// chips for systems that aren't wired up at all.
    @Published private(set) var availableSources: Set<PullRequestSource> = []

    /// How long a loaded queue stays fresh. Returning to the Dashboard shouldn't
    /// refetch ~80 pull requests across two providers every time.
    private static let freshness: TimeInterval = 5 * 60

    var isFresh: Bool {
        guard let lastLoaded else { return false }
        return Date().timeIntervalSince(lastLoaded) < Self.freshness
    }

    func load(appState: AppState, force: Bool = false) {
        if force {
            loadTask?.cancel()
            loadTask = Task { await self.performLoad(appState: appState) }
            return
        }
        // Already loading, or loaded recently — leave the existing rows alone.
        guard !isLoading, !isFresh else { return }
        loadTask = Task { await self.performLoad(appState: appState) }
    }

    private func performLoad(appState: AppState) async {
        isLoading = true
        defer { isLoading = false }

        let devOpsReady = appState.config.isDevOpsConfigured && appState.devOpsService.hasValidToken
        let gitHubConfig = appState.config.tasks?.providers.github ?? GitHubProviderConfig()

        // Configuration decides which pills exist — not token state. Gating
        // DevOps on its token made the pill vanish whenever SSO lapsed,
        // silently stranding the queue on GitHub with no way back.
        var sources: Set<PullRequestSource> = []
        if appState.config.isDevOpsConfigured { sources.insert(.azureDevOps) }
        sources.insert(.gitHub)
        availableSources = sources

        // Re-assert the DevOps-first default until the user picks a pill —
        // early loads run before DevOps SSO lands, and must not erase it.
        if !userTouchedFilter {
            selectedSource = devOpsReady ? .azureDevOps : selectedSource
        }

        var merged = PullRequestQueue()

        // Azure DevOps runs on the shared, token-injected service (main-actor
        // bound); GitHub is an actor and can run concurrently with it — unless
        // it rate-limited us recently, in which case its cached rows stand in.
        let gitHubInBackoff = (gitHubBackoffUntil ?? .distantPast) > Date()
        let gitHubTask: Task<PullRequestQueue, Never>? = gitHubInBackoff ? nil
            : Task.detached(priority: .userInitiated) {
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

        if let gitHubTask {
            let gitHub = await gitHubTask.value
            if let rateLimit = gitHub.errors.first(where: {
                $0.source == .gitHub && $0.message.localizedCaseInsensitiveContains("rate limit")
            }) {
                gitHubBackoffUntil = Date().addingTimeInterval(15 * 60)
                dbg.info("GitHub PR queue rate-limited, backing off 15 min: \(rateLimit.message)", category: "dashboard")
                mergeGitHubFallback(into: &merged)
            } else {
                cachedGitHub = PullRequestQueue(
                    pullRequests: gitHub.pullRequests.filter { $0.source == .gitHub }
                )
                merged.merge(gitHub)
            }
        } else {
            mergeGitHubFallback(into: &merged)
        }

        // Not being signed into gh is a normal state, not a fault — the
        // Authentication panel owns reporting it. Real API failures stay.
        merged.errors.removeAll {
            $0.source == .gitHub && $0.message.contains("No GitHub authentication token")
        }

        guard !Task.isCancelled else { return }
        queue = merged
        lastLoaded = Date()
    }

    /// Rate-limited: show the last good GitHub rows with a quiet note instead of
    /// an empty section and a scary banner.
    private func mergeGitHubFallback(into merged: inout PullRequestQueue) {
        let until = gitHubBackoffUntil ?? Date()
        let time = until.formatted(date: .omitted, time: .shortened)
        if let cachedGitHub {
            merged.merge(cachedGitHub)
            merged.errors.append(PullRequestQueueError(
                source: .gitHub, message: "Rate limited — showing earlier results, retrying after \(time)"
            ))
        } else {
            merged.errors.append(PullRequestQueueError(
                source: .gitHub, message: "Rate limited — retrying after \(time)"
            ))
        }
    }

    /// Select a provider to filter by; selecting the active one clears the filter.
    func toggle(_ source: PullRequestSource) {
        userTouchedFilter = true
        selectedSource = (selectedSource == source) ? nil : source
        selectedRepo = nil
    }

    /// A pull request was completed or abandoned from inside the app. Drop the
    /// row immediately — Azure DevOps finishes the merge asynchronously, so an
    /// instant refetch still reports the PR active and would resurrect it —
    /// then reconcile against the server once it has had time to settle.
    func noteActionCompleted(_ pullRequest: UnifiedPullRequest, appState: AppState) {
        queue.pullRequests.removeAll { $0.id == pullRequest.id }
        Task {
            try? await Task.sleep(for: .seconds(5))
            self.load(appState: appState, force: true)
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
    /// The task tables sharing this section's 50/50 split; the source pills in
    /// the header filter both sides at once.
    @ObservedObject var tasksModel: DashboardTasksModel

    @AppStorage("dashboard.prQueue.collapsed.createdByMe") private var createdCollapsed = false
    @AppStorage("dashboard.prQueue.collapsed.assignedToMe") private var assignedCollapsed = false
    @State private var expandedSections: Set<PullRequestRelation> = []

    private let collapsedRowLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            repoFilterRow

            ForEach(model.errors) { error in
                Label("\(error.source.displayName): \(error.message)", systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    group(.createdByMe, isCollapsed: $createdCollapsed)
                    group(.assignedToMe, isCollapsed: $assignedCollapsed)

                    if !model.isLoading && model.visiblePullRequests.isEmpty {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                DashboardTasksPane(
                    model: tasksModel,
                    source: model.selectedSource,
                    repoFilter: model.selectedRepo
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Secondary filter: one pill per repository in the current source scope,
    /// busiest first. Only rendered when there's a real choice to make.
    @ViewBuilder
    private var repoFilterRow: some View {
        let repos = model.repoCounts
        if !repos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(repos.prefix(14), id: \.repo) { entry in
                        repoChip(entry.repo, count: entry.count)
                    }
                }
            }
        }
    }

    private func repoChip(_ repo: String, count: Int) -> some View {
        let isSelected = model.selectedRepo == repo
        return Button(action: {
            withAnimation(.smooth(duration: 0.15)) { model.toggleRepo(repo) }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .appFont(.caption2)
                Text(repo).appFont(.caption2, weight: .medium)
                Text("\(count)")
                    .appFont(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Clear the \(repo) filter" : "Show only \(repo)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("My pull requests").appFont(.headline)

            if model.isLoading {
                ProgressView().controlSize(.mini)
            }

            // Source filters. Only worth showing when more than one provider is
            // in play — a lone "GitHub" pill filters nothing.
            if model.availableSources.count > 1 {
                HStack(spacing: 6) {
                    ForEach(PullRequestSource.allCases, id: \.self) { source in
                        if model.availableSources.contains(source) {
                            sourceChip(source)
                        }
                    }
                }
            }

            Button(action: { model.load(appState: appState, force: true) }) {
                Image(systemName: "arrow.clockwise")
                    .appFont(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh pull requests")
            .disabled(model.isLoading)

            Spacer()
        }
    }

    /// A filter pill: click to show only that provider, click it again to clear.
    /// With no filter set every pill reads as unselected — the queue already
    /// shows everything, so highlighting them all would imply otherwise.
    private func sourceChip(_ source: PullRequestSource) -> some View {
        let isSelected = model.selectedSource == source
        let count = model.count(for: source)
        return Button(action: {
            withAnimation(.smooth(duration: 0.15)) { model.toggle(source) }
        }) {
            HStack(spacing: 4) {
                BrandIcon(mark: source.brandMark, size: 10)
                Text(source.shortName).appFont(.caption2, weight: .medium)
                Text("\(count)")
                    .appFont(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isSelected ? source.tint : Color.secondary.opacity(0.12))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : source.tint.opacity(0.35),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Clear the \(source.displayName) filter" : "Show only \(source.displayName)")
    }

    // MARK: Groups

    @ViewBuilder
    private func group(_ relation: PullRequestRelation, isCollapsed: Binding<Bool>) -> some View {
        let items = model.section(relation)
        if !items.isEmpty {
            let isExpanded = expandedSections.contains(relation)
            let visible = isExpanded ? items : Array(items.prefix(collapsedRowLimit))

            GroupBox {
                // Top-aligned in however much height the box is given, so a
                // short queue keeps regular rows with empty space below.
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: { isCollapsed.wrappedValue.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .appFont(.caption2)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isCollapsed.wrappedValue ? -90 : 0))
                            Text(relation.sectionTitle).appFont(.subheadline, weight: .semibold)
                            Text("\(items.count)")
                                .appFont(.caption2).monospacedDigit()
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
                            PullRequestRow(pullRequest: pr) {
                                model.noteActionCompleted(pr, appState: appState)
                            }
                            if index < visible.count - 1 { Divider() }
                        }

                        if items.count > collapsedRowLimit {
                            Divider()
                            Button(action: {
                                if isExpanded { expandedSections.remove(relation) }
                                else { expandedSections.insert(relation) }
                            }) {
                                Text(isExpanded ? "Show less" : "Show \(items.count - collapsedRowLimit) more")
                                    .appFont(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        GroupBox {
            VStack(spacing: 6) {
                if model.selectedSource == .azureDevOps,
                   appState.config.isDevOpsConfigured, !appState.devOpsService.hasValidToken {
                    // Not empty — unauthenticated. "DevOps 0" with no
                    // explanation looked like the queue vanished.
                    Image(systemName: "clock")
                        .appFont(.title2)
                        .foregroundStyle(.secondary)
                    Text("Waiting for Azure DevOps sign-in…")
                        .appFont(.callout)
                    Text("The queue loads automatically once SSO completes.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                } else if let filtered = model.selectedSource {
                    // Empty because of the filter, not because the queue is clear —
                    // saying "nothing waiting on you" here would be a lie.
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .appFont(.title2)
                        .foregroundStyle(.secondary)
                    Text("No \(filtered.displayName) pull requests")
                        .appFont(.callout)
                    Button("Clear filter") { model.toggle(filtered) }
                        .buttonStyle(.plain)
                        .appFont(.caption)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "checkmark.circle")
                        .appFont(.title2)
                        .foregroundStyle(.green)
                    Text("No open pull requests")
                        .appFont(.callout)
                    Text("Nothing waiting on you across Azure DevOps or GitHub.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Row

struct PullRequestRow: View {
    let pullRequest: UnifiedPullRequest
    /// Called after a completed or abandoned PR, so the queue can refresh.
    var onActionCompleted: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @State private var isHovering = false
    @State private var showDetail = false
    @State private var pendingAction: PullRequestAction?
    @State private var runningAction: PullRequestAction?
    @State private var actionError: String?

    private let maxReviewerBubbles = 4

    /// The two write actions the queue offers on an Azure DevOps PR.
    enum PullRequestAction: String, Identifiable {
        case complete, abandon
        var id: String { rawValue }

        var title: String { self == .complete ? "Complete" : "Abandon" }
        var tint: Color { self == .complete ? .green : .orange }
        var icon: String { self == .complete ? "checkmark" : "xmark" }
    }

    /// Complete and Abandon are Azure DevOps writes, and only mean anything
    /// while the PR is still active.
    private var showsActions: Bool {
        guard pullRequest.source == .azureDevOps else { return false }
        return pullRequest.state == .open || pullRequest.state == .draft
    }

    var body: some View {
        // The row's body and its action buttons are siblings rather than nested:
        // a Button inside a Button doesn't reliably receive clicks on macOS.
        HStack(spacing: 6) {
            rowButton
            if showsActions {
                actionButtons
            }
        }
        // A row is a row: without this, a tall proposal (short queue beside a
        // tall task table) stretches the indicator bar and floats the buttons
        // mid-air instead of leaving the box's extra space empty.
        .fixedSize(horizontal: false, vertical: true)
        .background(isHovering ? Color.secondary.opacity(0.08) : Color.clear)
        .onHover { isHovering = $0 }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            presenting: pendingAction
        ) { action in
            Button(action.title, role: action == .abandon ? .destructive : nil) {
                perform(action)
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(confirmationMessage(for: action))
        }
        .alert(
            "Action failed",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var rowButton: some View {
        // Click opens the in-app viewer; the browser stays one right-click away.
        Button(action: { showDetail = true }) {
            // Center alignment so rows with reviewer bubbles line up the same
            // as rows without them — top alignment made the trailing cluster
            // sit visibly higher whenever bubbles grew the row.
            HStack(alignment: .center, spacing: 10) {
                Rectangle()
                    .fill(pullRequest.source.tint)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                BrandIcon(mark: pullRequest.source.brandMark, size: 12)
                    .foregroundStyle(pullRequest.source.tint)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pullRequest.title)
                            .appFont(fixed: 12, weight: .semibold)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        statusPills
                    }
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                reviewerBubbles

                HStack(spacing: 3) {
                    Image(systemName: "bubble.left").appFont(fixed: 9)
                    Text("\(pullRequest.commentCount)").appFont(.caption2).monospacedDigit()
                }
                .foregroundStyle(pullRequest.commentCount > 0 ? .secondary : .tertiary)
                .frame(width: 34, alignment: .trailing)

                Text(timestampLabel)
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 116, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pullRequest.title)
        .sheet(isPresented: $showDetail) {
            PullRequestDetailView(pullRequest: pullRequest, onActionCompleted: onActionCompleted)
                .environmentObject(appState)
        }
        .contextMenu {
            Button("Open in Browser") { open() }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.webUrl, forType: .string)
            }
        }
    }

    // MARK: Actions

    private var actionButtons: some View {
        HStack(spacing: 4) {
            actionButton(.complete)
            actionButton(.abandon)
        }
        .padding(.trailing, 6)
    }

    private func actionButton(_ action: PullRequestAction) -> some View {
        Button {
            pendingAction = action
        } label: {
            HStack(spacing: 3) {
                if runningAction == action {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: action.icon).appFont(fixed: 9, weight: .bold)
                }
                Text(action.title).appFont(fixed: 10, weight: .medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(action.tint.opacity(0.15))
            .foregroundStyle(action.tint)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(action.tint.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(runningAction != nil)
        .help(action == .complete
              ? "Complete this pull request, merging it into \(pullRequest.targetBranch)"
              : "Abandon this pull request")
    }

    private var confirmationTitle: String {
        guard let action = pendingAction else { return "" }
        return "\(action.title) !\(pullRequest.number)?"
    }

    private func confirmationMessage(for action: PullRequestAction) -> String {
        switch action {
        case .complete:
            return "\(pullRequest.title)\n\nThis merges \(pullRequest.sourceBranch) into "
                + "\(pullRequest.targetBranch) in \(pullRequest.repository), using the merge "
                + "options already set on the pull request."
        case .abandon:
            return "\(pullRequest.title)\n\nThe pull request stays in \(pullRequest.repository) "
                + "and can be reactivated in Azure DevOps, but reviewers are notified."
        }
    }

    private func perform(_ action: PullRequestAction) {
        pendingAction = nil
        runningAction = action
        Task {
            defer { runningAction = nil }
            do {
                switch action {
                case .complete:
                    try await appState.devOpsService.completePullRequest(
                        repository: pullRequest.repository,
                        pullRequestId: pullRequest.number,
                        project: pullRequest.container
                    )
                case .abandon:
                    try await appState.devOpsService.abandonPullRequest(
                        repository: pullRequest.repository,
                        pullRequestId: pullRequest.number,
                        project: pullRequest.container
                    )
                }
                onActionCompleted?()
            } catch {
                actionError = "Could not \(action.title.lowercased()) !\(pullRequest.number): "
                    + error.localizedDescription
                // The most common failure is stale queue state (for example,
                // the PR was already abandoned in Azure DevOps). Reconcile
                // immediately so that row cannot invite the same action again.
                appState.pullRequestQueue.load(appState: appState, force: true)
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
            .appFont(fixed: 9, weight: .medium)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            Text("\(pullRequest.authorName) request \(pullRequest.reference) into")
                .lineLimit(1)
            Image(systemName: "shippingbox").appFont(fixed: 9)
            Text("\(pullRequest.container)/\(pullRequest.repository)")
                .lineLimit(1)
            Image(systemName: "arrow.triangle.branch").appFont(fixed: 9)
            Text(pullRequest.targetBranch)
                .lineLimit(1)
        }
        .appFont(fixed: 10)
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
                        .appFont(fixed: 8, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(reviewer.vote.tint))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .help("\(reviewer.displayName) — \(reviewer.vote.label)")
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .appFont(fixed: 8, weight: .semibold)
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
    /// The provider's actual logo. SF Symbols has none for either, and the
    /// generic stand-ins conveyed nothing: `infinity` is a maths symbol, not the
    /// Azure DevOps mark.
    var brandMark: BrandShape {
        switch self {
        case .azureDevOps: return BrandMark.azureDevOps
        case .gitHub:      return BrandMark.gitHub
        }
    }

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
