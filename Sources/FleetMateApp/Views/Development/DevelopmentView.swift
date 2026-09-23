import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Model

/// The Development tab: every open pull request the user can act on, the
/// GitHub notification inbox, and the comment activity across all of them.
/// Owned by AppState so switching tabs keeps the loaded rows and selection.
@MainActor
final class DevelopmentModel: ObservableObject {
    enum Segment: String, CaseIterable, Hashable {
        case pullRequests = "Pulls"
        case inbox = "Inbox"
        case commits = "Commits"
        case pipelines = "Pipelines"
    }

    @Published var segment: Segment = .pullRequests

    // Pull requests
    @Published private(set) var queue = PullRequestQueue()
    @Published private(set) var isLoadingPullRequests = false
    @Published private(set) var pullRequestsLoadedAt: Date?
    @Published var selectedSource: PullRequestSource?
    @Published var selectedRepo: String?
    @Published var onlyMine = false
    @Published var selectedPullRequest: UnifiedPullRequest?
    @Published private(set) var availableSources: Set<PullRequestSource> = []

    // Inbox
    @Published private(set) var notifications: [GitHubNotification] = []
    @Published private(set) var isLoadingInbox = false
    @Published private(set) var inboxError: String?
    @Published private(set) var inboxLoadedAt: Date?
    @Published var showReadNotifications = false
    @Published private(set) var busyThreadIds: Set<String> = []
    @Published var actionError: String?

    // Commits
    @Published private(set) var repositoryCommits: [RepositoryCommits] = []
    @Published private(set) var isLoadingCommits = false
    @Published private(set) var commitsLoadedAt: Date?
    @Published private(set) var commitsError: String?
    @Published var selectedCommit: SelectedCommit?
    /// Repositories expanded past their first few commits.
    @Published var expandedCommitRepos: Set<String> = []
    /// How far back the Commits segment looks.
    static let commitsWindow: TimeInterval = 14 * 24 * 3600

    struct SelectedCommit: Identifiable, Equatable {
        let repository: RepositoryCommits
        let commit: PullRequestCommit
        var id: String { "\(repository.id)@\(commit.id)" }
        static func == (lhs: SelectedCommit, rhs: SelectedCommit) -> Bool { lhs.id == rhs.id }
    }

    private var commitsTask: Task<Void, Never>?

    /// Repositories with activity, source- and search-filtered, most
    /// recent activity first.
    func visibleRepositoryCommits(matching search: String) -> [RepositoryCommits] {
        var rows = repositoryCommits
        if let selectedSource { rows = rows.filter { $0.source == selectedSource } }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            rows = rows.compactMap { repo in
                if repo.displayName.lowercased().contains(needle) { return repo }
                let hits = repo.commits.filter {
                    $0.subject.lowercased().contains(needle)
                        || ($0.authorName ?? "").lowercased().contains(needle)
                        || $0.id.hasPrefix(needle)
                }
                guard !hits.isEmpty else { return nil }
                return RepositoryCommits(
                    source: repo.source, container: repo.container, repository: repo.repository,
                    repositoryId: repo.repositoryId, webUrl: repo.webUrl,
                    defaultBranch: repo.defaultBranch, commits: hits
                )
            }
        }
        return rows.sorted { $0.latestDate > $1.latestDate }
    }

    func commitCount(for source: PullRequestSource) -> Int {
        repositoryCommits.filter { $0.source == source }.reduce(0) { $0 + $1.commits.count }
    }

    func loadCommits(appState: AppState, force: Bool = false) {
        if !force {
            if isLoadingCommits { return }
            if let at = commitsLoadedAt, Date().timeIntervalSince(at) < Self.freshness { return }
        }
        commitsTask?.cancel()
        commitsTask = Task { await performCommitsLoad(appState: appState) }
    }

    private func performCommitsLoad(appState: AppState) async {
        isLoadingCommits = true
        defer { isLoadingCommits = false }
        let since = Date().addingTimeInterval(-Self.commitsWindow)
        let config = gitHubConfig(appState)
        let configuredOwners = [config.owner, config.organization].compactMap { $0 }
        let cachedOwners = viewerOwners

        let gitHubTask = Task.detached(priority: .userInitiated) { () -> (Result<[RepositoryCommits], Error>, [String]?) in
            let service = GitHubPullRequestService(config: config)
            var owners = cachedOwners
            if owners == nil { owners = (try? await service.getViewerOwners()) ?? [] }
            do {
                let repos = try await service.getRecentCommits(owners: configuredOwners + (owners ?? []), since: since)
                return (.success(repos), owners)
            } catch {
                return (.failure(error), owners)
            }
        }

        var merged: [RepositoryCommits] = []
        var errors: [String] = []
        if appState.config.isDevOpsConfigured, await appState.devOpsService.ensureValidToken() {
            do {
                merged += try await appState.devOpsService.getRecentCommits(since: since)
            } catch {
                errors.append("Azure DevOps: \(error.localizedDescription)")
            }
        }

        let (gitHub, owners) = await gitHubTask.value
        if let owners, viewerOwners == nil { viewerOwners = owners }
        switch gitHub {
        case .success(let repos): merged += repos
        case .failure(let error):
            if !error.localizedDescription.contains("No GitHub authentication token") {
                errors.append("GitHub: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled else { return }
        repositoryCommits = merged.sorted { $0.latestDate > $1.latestDate }
        commitsError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        commitsLoadedAt = Date()
    }

    // Pipelines
    @Published private(set) var pipelineRuns: [PipelineRun] = []
    @Published private(set) var isLoadingPipelines = false
    @Published private(set) var pipelinesLoadedAt: Date?
    @Published private(set) var pipelinesError: String?
    @Published var selectedRun: PipelineRun?
    @Published var pipelineStatusFilter: PipelineRunStatus?
    /// How far back the Pipelines segment looks.
    static let pipelinesWindow: TimeInterval = 7 * 24 * 3600

    private var pipelinesTask: Task<Void, Never>?

    func visiblePipelineRuns(matching search: String) -> [PipelineRun] {
        var rows = pipelineRuns
        if let selectedSource { rows = rows.filter { $0.source == selectedSource } }
        if let pipelineStatusFilter {
            rows = rows.filter { matches($0, status: pipelineStatusFilter) }
        }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            rows = rows.filter {
                $0.pipelineName.lowercased().contains(needle)
                    || ($0.repository ?? "").lowercased().contains(needle)
                    || $0.container.lowercased().contains(needle)
                    || ($0.branch ?? "").lowercased().contains(needle)
                    || ($0.triggeredBy ?? "").lowercased().contains(needle)
                    || $0.runNumber.lowercased().contains(needle)
            }
        }
        return rows.sorted { $0.sortDate > $1.sortDate }
    }

    func pipelineCount(for source: PullRequestSource) -> Int {
        pipelineRuns.filter { $0.source == source }.count
    }

    func pipelineCount(for status: PipelineRunStatus) -> Int {
        pipelineRuns.filter { matches($0, status: status) }.count
    }

    /// Running matches any active run. Failed matches only a pipeline whose
    /// latest run failed or partially succeeded: an old red run under a green
    /// one is history, not a failure to act on. Succeeded matches every green
    /// run. The Windows app applies the same rule.
    private func matches(_ run: PipelineRun, status: PipelineRunStatus) -> Bool {
        switch status {
        case .running: return run.status.isActive
        case .failed: return (run.status == .failed || run.status == .partial) && latestRunIDs.contains(run.id)
        default: return run.status == status
        }
    }

    /// The most recent run of every pipeline, by start date.
    private var latestRunIDs: Set<String> {
        var latest: [String: PipelineRun] = [:]
        for run in pipelineRuns {
            let key = "\(run.source.rawValue):\(run.container)/\(run.pipelineId.map(String.init) ?? run.pipelineName)"
            if let current = latest[key], current.sortDate >= run.sortDate { continue }
            latest[key] = run
        }
        return Set(latest.values.map(\.id))
    }

    func togglePipelineStatus(_ status: PipelineRunStatus) {
        pipelineStatusFilter = (pipelineStatusFilter == status) ? nil : status
    }

    func loadPipelines(appState: AppState, force: Bool = false) {
        if !force {
            if isLoadingPipelines { return }
            if let at = pipelinesLoadedAt, Date().timeIntervalSince(at) < Self.freshness { return }
        }
        pipelinesTask?.cancel()
        pipelinesTask = Task { await performPipelinesLoad(appState: appState) }
    }

    private func performPipelinesLoad(appState: AppState) async {
        isLoadingPipelines = true
        defer { isLoadingPipelines = false }
        let since = Date().addingTimeInterval(-Self.pipelinesWindow)
        let config = gitHubConfig(appState)

        // GitHub Actions runs come per repository; the repositories with
        // recent commits are the ones with runs worth showing, so the
        // Commits segment's list is the scope. Load it first if needed.
        if repositoryCommits.isEmpty, commitsLoadedAt == nil {
            await performCommitsLoad(appState: appState)
        }
        let gitHubRepos = repositoryCommits
            .filter { $0.source == .gitHub }
            .map { (owner: $0.container, name: $0.repository) }

        let gitHubTask = Task.detached(priority: .userInitiated) {
            await GitHubActionsService(config: config).getRecentRuns(repositories: gitHubRepos, since: since)
        }

        var merged: [PipelineRun] = []
        var errors: [String] = []
        if appState.config.isDevOpsConfigured, await appState.devOpsService.ensureValidToken() {
            do {
                merged += try await appState.devOpsService.getRecentPipelineRuns(since: since)
            } catch {
                errors.append("Azure DevOps: \(error.localizedDescription)")
            }
        }

        let gitHub = await gitHubTask.value
        merged += gitHub.runs
        if let error = gitHub.error, !error.contains("No GitHub authentication token") {
            errors.append("GitHub: \(error)")
        }

        guard !Task.isCancelled else { return }
        pipelineRuns = merged.sorted { $0.sortDate > $1.sortDate }
        pipelinesError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        pipelinesLoadedAt = Date()
        if let selected = selectedRun {
            selectedRun = merged.first { $0.id == selected.id } ?? selected
        }
    }

    // Activity sidebar
    @Published var showActivity = true
    @Published var hideMyComments = false
    @Published var searchText = ""

    /// One comment in the activity feed, with the PR it belongs to.
    struct ActivityEntry: Identifiable {
        let comment: PullRequestComment
        let pullRequest: UnifiedPullRequest
        var id: String { "\(pullRequest.id):\(comment.id)" }
    }

    /// Every recent comment across the loaded queue, newest first. Follows
    /// the source filter so the feed and the list agree on scope.
    func activity(appState: AppState) -> [ActivityEntry] {
        var mine: Set<String> = []
        if let login = viewerOwners?.first { mine.insert(login.lowercased()) }
        if let name = appState.devOpsSsoUserName { mine.insert(name.lowercased()) }

        var rows = queue.pullRequests
        if let selectedSource { rows = rows.filter { $0.source == selectedSource } }
        return rows
            .flatMap { pr in pr.recentComments.map { ActivityEntry(comment: $0, pullRequest: pr) } }
            .filter { !hideMyComments || !mine.contains($0.comment.authorName.lowercased()) }
            .sorted { ($0.comment.date ?? .distantPast) > ($1.comment.date ?? .distantPast) }
    }

    private var pullRequestTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?
    /// Login + organizations the token belongs to, resolved once per session.
    private var viewerOwners: [String]?

    private static let freshness: TimeInterval = 5 * 60

    // MARK: Derived

    var unreadCount: Int { notifications.filter(\.unread).count }

    private var sourceScoped: [UnifiedPullRequest] {
        var rows = queue.pullRequests
        if let selectedSource { rows = rows.filter { $0.source == selectedSource } }
        if onlyMine {
            rows = rows.filter { !$0.relations.isDisjoint(with: [.createdByMe, .assignedToMe, .involved]) }
        }
        return rows
    }

    func visiblePullRequests(matching search: String) -> [UnifiedPullRequest] {
        var rows = sourceScoped
        if let selectedRepo { rows = rows.filter { $0.repository == selectedRepo } }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            rows = rows.filter {
                $0.title.lowercased().contains(needle)
                    || $0.repository.lowercased().contains(needle)
                    || $0.authorName.lowercased().contains(needle)
                    || $0.sourceBranch.lowercased().contains(needle)
                    || String($0.number) == needle
                    || $0.reference.lowercased() == needle
            }
        }
        return rows.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Rows grouped by "container/repository", busiest activity first.
    func groupedPullRequests(matching search: String) -> [(key: String, rows: [UnifiedPullRequest])] {
        let rows = visiblePullRequests(matching: search)
        var buckets: [String: [UnifiedPullRequest]] = [:]
        for pr in rows { buckets["\(pr.container)/\(pr.repository)", default: []].append(pr) }
        return buckets
            .map { (key: $0.key, rows: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.rows.first?.lastActivity ?? .distantPast
                let r = rhs.rows.first?.lastActivity ?? .distantPast
                return l == r ? lhs.key < rhs.key : l > r
            }
    }

    var repoCounts: [(repo: String, count: Int)] {
        var counts: [String: Int] = [:]
        for pr in sourceScoped { counts[pr.repository, default: 0] += 1 }
        guard counts.count > 1 else { return [] }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    func count(for source: PullRequestSource) -> Int {
        queue.pullRequests.filter { $0.source == source }.count
    }

    var visibleNotifications: [GitHubNotification] {
        let rows = showReadNotifications ? notifications : notifications.filter(\.unread)
        return rows.sorted { lhs, rhs in
            if lhs.unread != rhs.unread { return lhs.unread }
            if lhs.reason.isActionable != rhs.reason.isActionable { return lhs.reason.isActionable }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    func toggleSource(_ source: PullRequestSource) {
        selectedSource = (selectedSource == source) ? nil : source
        selectedRepo = nil
    }

    func toggleRepo(_ repo: String) {
        selectedRepo = (selectedRepo == repo) ? nil : repo
    }

    // MARK: Loading

    private func gitHubConfig(_ appState: AppState) -> GitHubProviderConfig {
        appState.config.tasks?.providers.github ?? GitHubProviderConfig()
    }

    func loadAll(appState: AppState, force: Bool = false) {
        loadPullRequests(appState: appState, force: force)
        loadInbox(appState: appState, force: force)
        loadCommits(appState: appState, force: force)
        loadPipelines(appState: appState, force: force)
    }

    func loadPullRequests(appState: AppState, force: Bool = false) {
        if !force {
            if isLoadingPullRequests { return }
            if let at = pullRequestsLoadedAt, Date().timeIntervalSince(at) < Self.freshness { return }
        }
        pullRequestTask?.cancel()
        pullRequestTask = Task { await performPullRequestLoad(appState: appState) }
    }

    private func performPullRequestLoad(appState: AppState) async {
        isLoadingPullRequests = true
        defer { isLoadingPullRequests = false }

        var devOpsReady = false
        if appState.config.isDevOpsConfigured {
            devOpsReady = await appState.devOpsService.ensureValidToken()
        }
        var sources: Set<PullRequestSource> = [.gitHub]
        if appState.config.isDevOpsConfigured { sources.insert(.azureDevOps) }
        availableSources = sources

        let config = gitHubConfig(appState)
        let configuredOwners = [config.owner, config.organization].compactMap { $0 }
        let cachedOwners = viewerOwners

        let gitHubTask = Task.detached(priority: .userInitiated) { () -> (PullRequestQueue, [String]?) in
            let service = GitHubPullRequestService(config: config)
            var owners = cachedOwners
            if owners == nil {
                owners = (try? await service.getViewerOwners()) ?? []
            }
            let queue = await service.getOpenPullRequests(owners: configuredOwners + (owners ?? []))
            return (queue, owners)
        }

        var merged = PullRequestQueue()
        if devOpsReady {
            do {
                merged.merge(try await appState.devOpsService.getAllActivePullRequests())
            } catch {
                merged.errors.append(PullRequestQueueError(source: .azureDevOps, message: error.localizedDescription))
            }
        }

        let (gitHub, owners) = await gitHubTask.value
        if let owners, viewerOwners == nil { viewerOwners = owners }
        merged.merge(gitHub)
        merged.errors.removeAll {
            $0.source == .gitHub && $0.message.contains("No GitHub authentication token")
        }

        guard !Task.isCancelled else { return }
        queue = merged
        pullRequestsLoadedAt = Date()

        // Keep the selection pointing at the fresh row, or drop it if the PR
        // is gone (merged or closed elsewhere).
        if let selected = selectedPullRequest {
            selectedPullRequest = merged.pullRequests.first { $0.id == selected.id }
        }
    }

    func loadInbox(appState: AppState, force: Bool = false) {
        if !force {
            if isLoadingInbox { return }
            if let at = inboxLoadedAt, Date().timeIntervalSince(at) < Self.freshness { return }
        }
        inboxTask?.cancel()
        inboxTask = Task { await performInboxLoad(appState: appState) }
    }

    private func performInboxLoad(appState: AppState) async {
        isLoadingInbox = true
        defer { isLoadingInbox = false }
        let config = gitHubConfig(appState)
        let includeRead = showReadNotifications
        do {
            let rows = try await GitHubNotificationService(config: config)
                .getNotifications(includeRead: includeRead)
            guard !Task.isCancelled else { return }
            notifications = rows
            inboxError = nil
            inboxLoadedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            inboxError = message.contains("No GitHub authentication token")
                ? "Sign in to GitHub (gh auth login) to see your inbox."
                : message
        }
    }

    /// Re-run the inbox query when the Unread/All switch flips: "all" is a
    /// different server-side list, not a client filter.
    func setShowRead(_ show: Bool, appState: AppState) {
        guard showReadNotifications != show else { return }
        showReadNotifications = show
        loadInbox(appState: appState, force: true)
    }

    // MARK: Pull request actions

    /// A PR was completed or abandoned in-app; drop the row now rather than
    /// waiting for the provider to catch up, then reconcile.
    func noteActionCompleted(_ pullRequest: UnifiedPullRequest, appState: AppState) {
        queue.pullRequests.removeAll { $0.id == pullRequest.id }
        if selectedPullRequest?.id == pullRequest.id { selectedPullRequest = nil }
        pullRequestsLoadedAt = nil
        loadPullRequests(appState: appState, force: true)
        appState.pullRequestQueue.load(appState: appState, force: true)
    }

    // MARK: Inbox actions

    private func withThread(_ id: String, _ work: @escaping () async throws -> Void) {
        busyThreadIds.insert(id)
        Task {
            defer { busyThreadIds.remove(id) }
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }

    private func setUnread(_ id: String, _ unread: Bool) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        notifications[index].unread = unread
        if !showReadNotifications, !unread { notifications.remove(at: index) }
    }

    func markRead(_ notification: GitHubNotification, appState: AppState) {
        let config = gitHubConfig(appState)
        withThread(notification.id) { [weak self] in
            try await GitHubNotificationService(config: config).markRead(threadId: notification.id)
            self?.setUnread(notification.id, false)
        }
    }

    func markDone(_ notification: GitHubNotification, appState: AppState) {
        let config = gitHubConfig(appState)
        withThread(notification.id) { [weak self] in
            try await GitHubNotificationService(config: config).markDone(threadId: notification.id)
            self?.notifications.removeAll { $0.id == notification.id }
        }
    }

    func unsubscribe(_ notification: GitHubNotification, appState: AppState) {
        let config = gitHubConfig(appState)
        withThread(notification.id) { [weak self] in
            let service = GitHubNotificationService(config: config)
            try await service.unsubscribe(threadId: notification.id)
            try await service.markRead(threadId: notification.id)
            self?.setUnread(notification.id, false)
        }
    }

    func markAllRead(appState: AppState) {
        let config = gitHubConfig(appState)
        Task {
            do {
                try await GitHubNotificationService(config: config).markAllRead()
                for index in notifications.indices { notifications[index].unread = false }
                if !showReadNotifications { notifications.removeAll() }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Opens what the notification is about: a pull request selects it in the
    /// right pane (fetching it if the queue does not have it); anything else
    /// goes to the browser. Either way the thread is marked read.
    func open(_ notification: GitHubNotification, appState: AppState) {
        if notification.unread { markRead(notification, appState: appState) }

        guard notification.subjectType == .pullRequest, let number = notification.subjectNumber else {
            if let url = URL(string: notification.webUrl) { NSWorkspace.shared.open(url) }
            return
        }

        if let existing = queue.pullRequests.first(where: {
            $0.source == .gitHub && $0.number == number
                && $0.container.caseInsensitiveCompare(notification.owner) == .orderedSame
                && $0.repository.caseInsensitiveCompare(notification.repositoryName) == .orderedSame
        }) {
            selectedPullRequest = existing
            return
        }

        let config = gitHubConfig(appState)
        withThread(notification.id) { [weak self] in
            let pr = try await GitHubPullRequestService(config: config).getPullRequest(
                owner: notification.owner, repo: notification.repositoryName, number: number
            )
            guard let self else { return }
            if let pr {
                self.queue.insert(pr)
                self.selectedPullRequest = pr
            } else if let url = URL(string: notification.webUrl) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - View

/// Two panes: the queue or inbox on the left, the selected pull request
/// inline on the right — no sheet, so reading and acting is one flow.
struct DevelopmentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        DevelopmentContent(model: appState.development)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Split out so the model can come from AppState (environment) rather than
/// the view's init.
private struct DevelopmentContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: DevelopmentModel

    private let listWidth: CGFloat = 470
    private let activityWidth: CGFloat = 330

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: listWidth)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showActivity {
                Divider()
                ActivityPane(model: model)
                    .frame(width: activityWidth)
            }
        }
        .searchable(text: $model.searchText, prompt: searchPrompt)
        .toolbar { developmentToolbar }
        .task {
            model.loadAll(appState: appState)
            // Inbox freshness matters more than anywhere else in the app:
            // missing a review request for an hour is the failure mode this
            // tab exists to fix.
            // The inbox is one cheap REST call, so it polls every five
            // minutes; the pull-request searches cost GraphQL points per row
            // and refresh every fifteen, or on demand from the toolbar.
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                tick += 1
                model.loadInbox(appState: appState, force: true)
                if tick % 3 == 0 {
                    model.loadPullRequests(appState: appState, force: true)
                    model.loadCommits(appState: appState, force: true)
                    model.loadPipelines(appState: appState, force: true)
                } else if model.segment == .pipelines, model.pipelineRuns.contains(where: { $0.status.isActive }) {
                    // Something is running: keep the list honest while it is watched.
                    model.loadPipelines(appState: appState, force: true)
                }
            }
        }
        .onChange(of: appState.devOpsSsoAuthenticated) { _, ready in
            if ready { model.loadPullRequests(appState: appState, force: true) }
        }
        .alert(
            "Action failed",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var searchText: String { model.searchText }

    private var searchPrompt: String {
        switch model.segment {
        case .pullRequests, .inbox: return "Search pull requests..."
        case .commits: return "Search commits..."
        case .pipelines: return "Search runs..."
        }
    }

    @ToolbarContentBuilder
    private var developmentToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            SegmentedPill(
                selection: $model.segment,
                options: DevelopmentModel.Segment.allCases,
                label: { $0 == .inbox && model.unreadCount > 0 ? "Inbox \(model.unreadCount)" : $0.rawValue },
                segmentWidth: nil
            )

            if model.segment == .inbox {
                Button {
                    model.markAllRead(appState: appState)
                } label: {
                    Label("Mark all read", systemImage: "envelope.open")
                }
                .disabled(model.unreadCount == 0)
                .help("Mark every notification as read")
            }

            Button {
                model.showActivity.toggle()
            } label: {
                Label("Activity", systemImage: model.showActivity ? "sidebar.trailing" : "sidebar.trailing")
            }
            .help(model.showActivity ? "Hide the comment activity sidebar" : "Show comments across all pull requests")

            Button(action: { model.loadAll(appState: appState, force: true) }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingPullRequests && model.isLoadingInbox)
            .help("Refresh pull requests and inbox")
        }
    }

    // MARK: Left pane

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.segment {
            case .pullRequests: pullRequestList
            case .inbox: inboxList
            case .commits: commitsList
            case .pipelines: PipelinesListView(model: model, searchText: searchText)
            }
        }
    }

    // MARK: Pull requests

    private var pullRequestList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoadingPullRequests { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            filterRows
            Divider()
            let groups = model.groupedPullRequests(matching: searchText)
            if groups.isEmpty {
                emptyPullRequests
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.key) { group in
                            Section {
                                ForEach(group.rows) { pr in
                                    CodePullRequestRow(
                                        pullRequest: pr,
                                        isSelected: model.selectedPullRequest?.id == pr.id
                                    ) {
                                        model.selectedPullRequest = pr
                                    }
                                    Divider().padding(.leading, 12)
                                }
                            } header: {
                                repoHeader(group.key, count: group.rows.count)
                            }
                        }
                    }
                }
            }
            if !model.queue.errors.isEmpty {
                Divider()
                ForEach(model.queue.errors) { error in
                    Label("\(error.source.displayName): \(error.message)", systemImage: "exclamationmark.triangle")
                        .appFont(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if model.availableSources.count > 1 {
                    ForEach(PullRequestSource.allCases, id: \.self) { source in
                        if model.availableSources.contains(source) {
                            chip(
                                title: source.shortName,
                                count: model.count(for: source),
                                tint: source.tint,
                                isSelected: model.selectedSource == source
                            ) { model.toggleSource(source) }
                        }
                    }
                }
                chip(title: "Mine", count: nil, tint: .accentColor, isSelected: model.onlyMine) {
                    model.onlyMine.toggle()
                }
                .help("Only pull requests I created, review or took part in")
                Spacer()
                Text("\(model.visiblePullRequests(matching: searchText).count) open")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            let repos = model.repoCounts
            if !repos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(repos, id: \.repo) { entry in
                            chip(
                                title: entry.repo,
                                count: entry.count,
                                tint: .secondary,
                                isSelected: model.selectedRepo == entry.repo
                            ) { model.toggleRepo(entry.repo) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chip(title: String, count: Int?, tint: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
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

    private func repoHeader(_ key: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").appFont(.caption2).foregroundStyle(.secondary)
            Text(key).appFont(.caption, weight: .semibold, design: .monospaced)
            Text("\(count)")
                .appFont(.caption2).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var emptyPullRequests: some View {
        VStack(spacing: 8) {
            if model.isLoadingPullRequests {
                ProgressView()
                Text("Loading pull requests…").appFont(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle").appFont(.title2).foregroundStyle(.secondary)
                Text(model.queue.isEmpty ? "No open pull requests." : "Nothing matches the current filters.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inbox

    private var inboxList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                chip(title: "Unread", count: model.unreadCount, tint: .accentColor, isSelected: !model.showReadNotifications) {
                    model.setShowRead(false, appState: appState)
                }
                chip(title: "All", count: nil, tint: .secondary, isSelected: model.showReadNotifications) {
                    model.setShowRead(true, appState: appState)
                }
                Spacer()
                if let at = model.inboxLoadedAt {
                    Text("Checked \(DevelopmentView.relative(at))")
                        .appFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            let rows = model.visibleNotifications
            if let error = model.inboxError, rows.isEmpty {
                ContentUnavailableView("Inbox unavailable", systemImage: "bell.slash", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                VStack(spacing: 8) {
                    if model.isLoadingInbox {
                        ProgressView()
                        Text("Checking GitHub…").appFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "tray").appFont(.title2).foregroundStyle(.secondary)
                        Text(model.showReadNotifications ? "No notifications." : "Inbox zero.")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { notification in
                            InboxRow(
                                notification: notification,
                                isBusy: model.busyThreadIds.contains(notification.id),
                                onOpen: { model.open(notification, appState: appState) },
                                onMarkRead: { model.markRead(notification, appState: appState) },
                                onDone: { model.markDone(notification, appState: appState) },
                                onUnsubscribe: { model.unsubscribe(notification, appState: appState) }
                            )
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    // MARK: Commits

    private var commitsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoadingCommits { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            HStack(spacing: 6) {
                if model.availableSources.count > 1 {
                    ForEach(PullRequestSource.allCases, id: \.self) { source in
                        if model.availableSources.contains(source) {
                            chip(
                                title: source.shortName,
                                count: model.commitCount(for: source),
                                tint: source.tint,
                                isSelected: model.selectedSource == source
                            ) { model.toggleSource(source) }
                        }
                    }
                }
                Spacer()
                if let at = model.commitsLoadedAt {
                    Text("Checked \(DevelopmentView.relative(at))")
                        .appFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            let repos = model.visibleRepositoryCommits(matching: searchText)
            if repos.isEmpty {
                VStack(spacing: 8) {
                    if model.isLoadingCommits {
                        ProgressView()
                        Text("Loading commits…").appFont(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "circle.dotted.and.circle").appFont(.title2).foregroundStyle(.secondary)
                        Text(model.repositoryCommits.isEmpty ? "No commits in the last 14 days." : "Nothing matches.")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(repos) { repo in
                            let expanded = model.expandedCommitRepos.contains(repo.id)
                            let shown = expanded ? repo.commits : Array(repo.commits.prefix(3))
                            Section {
                                ForEach(shown) { commit in
                                    CommitRow(
                                        repository: repo,
                                        commit: commit,
                                        isSelected: model.selectedCommit?.commit.id == commit.id
                                            && model.selectedCommit?.repository.id == repo.id
                                    ) {
                                        model.selectedCommit = .init(repository: repo, commit: commit)
                                    }
                                    Divider().padding(.leading, 12)
                                }
                                if repo.commits.count > 3 {
                                    Button {
                                        if expanded { model.expandedCommitRepos.remove(repo.id) }
                                        else { model.expandedCommitRepos.insert(repo.id) }
                                    } label: {
                                        Text(expanded ? "Show fewer" : "Show all \(repo.commits.count)")
                                            .appFont(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                commitRepoHeader(repo)
                            }
                        }
                    }
                }
            }
            if let error = model.commitsError {
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

    private func commitRepoHeader(_ repo: RepositoryCommits) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(repo.source.tint)
                .frame(width: 3, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            Text(repo.displayName).appFont(.caption, weight: .semibold, design: .monospaced)
            if let branch = repo.defaultBranch {
                Text(branch).appFont(.caption2, design: .monospaced).foregroundStyle(.tertiary)
            }
            Text("\(repo.commits.count)")
                .appFont(.caption2).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
            Spacer()
            Text(DevelopmentView.relative(repo.latestDate))
                .appFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if model.segment == .pipelines {
            if let run = model.selectedRun {
                PipelineRunDetailView(run: run) {
                    model.loadPipelines(appState: appState, force: true)
                }
                .id(run.id)
                .environmentObject(appState)
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "play.circle",
                    description: Text("Every pipeline run across all projects, last 7 days.")
                )
            }
        } else if model.segment == .commits {
            if let selected = model.selectedCommit {
                CommitDetailView(selection: selected)
                    .id(selected.id)
                    .environmentObject(appState)
            } else {
                ContentUnavailableView(
                    "Select a commit",
                    systemImage: "circle.dotted.and.circle",
                    description: Text("Recent commits on every default branch, last 14 days.")
                )
            }
        } else if let pr = model.selectedPullRequest {
            PullRequestDetailView(pullRequest: pr, isInline: true) {
                model.noteActionCompleted(pr, appState: appState)
            }
            .id(pr.id)
            .environmentObject(appState)
        } else {
            ContentUnavailableView(
                "Select a pull request",
                systemImage: "arrow.triangle.pull",
                description: Text("Pick one on the left, or open a pull request from the inbox.")
            )
        }
    }

}

// MARK: - Rows

/// Compact PR row for the Code list: selection, not a sheet.
struct CodePullRequestRow: View {
    let pullRequest: UnifiedPullRequest
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Rectangle()
                    .fill(pullRequest.source.tint)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pullRequest.reference)
                            .appFont(fixed: 10, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(pullRequest.title)
                            .appFont(fixed: 12, weight: .semibold)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if pullRequest.state == .draft { pill("Draft", color: .secondary) }
                        if pullRequest.hasConflicts { pill("Conflicts", color: .orange) }
                    }
                    HStack(spacing: 6) {
                        Text(pullRequest.authorName)
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(pullRequest.sourceBranch)
                            .appFont(.caption2, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        relationTag
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                reviewerBubbles

                HStack(spacing: 3) {
                    Image(systemName: "bubble.left").appFont(fixed: 9)
                    Text("\(pullRequest.commentCount)").appFont(.caption2).monospacedDigit()
                }
                .foregroundStyle(pullRequest.commentCount > 0 ? .secondary : .tertiary)

                Text(DevelopmentView.relative(pullRequest.lastActivity))
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
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
                if let url = URL(string: pullRequest.webUrl) { NSWorkspace.shared.open(url) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.webUrl, forType: .string)
            }
            Button("Copy ID (\(pullRequest.number))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(pullRequest.number), forType: .string)
            }
        }
    }

    @ViewBuilder
    private var relationTag: some View {
        if pullRequest.relations.contains(.assignedToMe) {
            pill("Review", color: .orange)
        } else if pullRequest.relations.contains(.createdByMe) {
            pill("Mine", color: .accentColor)
        } else if pullRequest.relations.contains(.involved) {
            pill("Involved", color: .secondary)
        }
    }

    @ViewBuilder
    private var reviewerBubbles: some View {
        let shown = Array(pullRequest.reviewers.prefix(3))
        if !shown.isEmpty {
            HStack(spacing: -4) {
                ForEach(shown) { reviewer in
                    Text(reviewer.initials)
                        .appFont(fixed: 7, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(reviewer.vote.tint))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .help("\(reviewer.displayName) — \(reviewer.vote.label)")
                }
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .appFont(fixed: 9, weight: .medium)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// One notification thread. Click opens the subject; the hover cluster
/// carries the inbox verbs (read, done, unsubscribe, browser).
struct InboxRow: View {
    let notification: GitHubNotification
    let isBusy: Bool
    let onOpen: () -> Void
    let onMarkRead: () -> Void
    let onDone: () -> Void
    let onUnsubscribe: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(notification.unread ? Color.accentColor : Color.clear)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    Image(systemName: notification.subjectType.symbolName)
                        .appFont(fixed: 12)
                        .foregroundStyle(notification.reason.isActionable ? Color.orange : Color.secondary)
                        .frame(width: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notification.subjectTitle)
                            .appFont(fixed: 12, weight: notification.unread ? .semibold : .regular)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(notification.repository)
                                .appFont(.caption2, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let number = notification.subjectNumber,
                               notification.subjectType == .pullRequest || notification.subjectType == .issue {
                                Text("#\(number)")
                                    .appFont(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(notification.reason.displayName)
                                .appFont(fixed: 9, weight: .medium)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background((notification.reason.isActionable ? Color.orange : Color.secondary).opacity(0.15))
                                .foregroundStyle(notification.reason.isActionable ? Color.orange : Color.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Spacer(minLength: 0)
                            if let at = notification.updatedAt {
                                Text(DevelopmentView.relative(at))
                                    .appFont(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isBusy {
                ProgressView().controlSize(.mini)
            } else if isHovering {
                HStack(spacing: 2) {
                    if notification.unread {
                        iconButton("envelope.open", help: "Mark as read", action: onMarkRead)
                    }
                    iconButton("checkmark", help: "Done — remove from inbox", action: onDone)
                    iconButton("bell.slash", help: "Unsubscribe from this thread", action: onUnsubscribe)
                    iconButton("globe", help: "Open in browser") {
                        if let url = URL(string: notification.webUrl) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovering ? Color.secondary.opacity(0.07) : .clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            if notification.unread { Button("Mark as Read", action: onMarkRead) }
            Button("Done", action: onDone)
            Button("Unsubscribe", action: onUnsubscribe)
            Divider()
            Button("Open in Browser") {
                if let url = URL(string: notification.webUrl) { NSWorkspace.shared.open(url) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(notification.webUrl, forType: .string)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .appFont(fixed: 11)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}


// MARK: - Activity sidebar

/// Comments and reviews across every loaded pull request, newest first.
/// Click a row to select its pull request; the link icon opens the comment.
struct ActivityPane: View {
    @ObservedObject var model: DevelopmentModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Activity").appFont(.headline)
                Spacer()
                Toggle("Hide mine", isOn: $model.hideMyComments)
                    .toggleStyle(.checkbox)
                    .appFont(.caption)
                    .help("Hide comments you wrote")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            let entries = model.activity(appState: appState)
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").appFont(.title2).foregroundStyle(.secondary)
                    Text(model.isLoadingPullRequests ? "Loading…" : "No recent comments.")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            ActivityRow(
                                entry: entry,
                                isSelected: model.selectedPullRequest?.id == entry.pullRequest.id
                            ) {
                                model.selectedPullRequest = entry.pullRequest
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let entry: DevelopmentModel.ActivityEntry
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(entry.pullRequest.source.tint)
                        .frame(width: 3, height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    Text(entry.comment.authorName)
                        .appFont(fixed: 11, weight: .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = entry.comment.date {
                        Text(DevelopmentView.relative(date))
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if isHovering, let url = entry.comment.url.flatMap(URL.init) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square").appFont(fixed: 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open this comment in the browser")
                    }
                }
                Text(entry.comment.body.strippedOfHtml)
                    .appFont(fixed: 11)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(entry.pullRequest.reference)
                        .appFont(.caption2, weight: .medium)
                        .monospacedDigit()
                    Text(entry.pullRequest.title)
                        .appFont(.caption2)
                        .lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.pullRequest.repository)
                        .appFont(.caption2, design: .monospaced)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.secondary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}


// MARK: - Commits

struct CommitRow: View {
    let repository: RepositoryCommits
    let commit: PullRequestCommit
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Text(commit.shortSha)
                    .appFont(fixed: 10, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject)
                        .appFont(fixed: 12, weight: .medium)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(commit.authorName ?? "unknown")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let date = commit.date {
                    Text(DevelopmentView.relative(date))
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.secondary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") {
                if let url = commit.url.flatMap(URL.init) { NSWorkspace.shared.open(url) }
            }
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
            }
        }
    }
}

/// One commit in the centre pane: message, then the diff (GitHub) or the
/// change list (Azure DevOps).
struct CommitDetailView: View {
    let selection: DevelopmentModel.SelectedCommit

    @EnvironmentObject private var appState: AppState
    @State private var detail: CommitDetail?
    @State private var loadError: String?
    @State private var copied = false

    private var commit: PullRequestCommit { selection.commit }
    private var repository: RepositoryCommits { selection.repository }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandIcon(mark: repository.source.brandMark, size: 16)
                .foregroundStyle(repository.source.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .appFont(.title3, weight: .semibold)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(repository.displayName)
                        .appFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                    if let branch = repository.defaultBranch {
                        Image(systemName: "arrow.triangle.branch").appFont(.caption2).foregroundStyle(.secondary)
                        Text(branch).appFont(.caption, design: .monospaced).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(commit.authorName ?? "unknown").appFont(.caption).foregroundStyle(.secondary)
                    if let date = commit.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .appFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if let detail {
                HStack(spacing: 6) {
                    Text("+\(detail.additions)").appFont(.caption, weight: .semibold).foregroundStyle(.green)
                    Text("-\(detail.deletions)").appFont(.caption, weight: .semibold).foregroundStyle(.orange)
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                HStack(spacing: 4) {
                    Text(commit.shortSha).appFont(.caption, design: .monospaced)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").appFont(fixed: 9)
                }
            }
            .help("Copy the full SHA")
            Button {
                if let url = commit.url.flatMap(URL.init) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "globe")
            }
            .disabled(commit.url == nil)
            .help("Open in browser")
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView("Couldn't load commit", systemImage: "exclamationmark.triangle", description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let body = detail.message
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .dropFirst()
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        GroupBox {
                            Text(body)
                                .appFont(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                    }
                    if !detail.files.isEmpty {
                        HStack(spacing: 8) {
                            Text("Changes").appFont(.headline)
                            Text("\(detail.files.count)")
                                .appFont(.caption2).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.secondary)
                            if detail.truncated {
                                Text("Large commit — showing a capped set of files")
                                    .appFont(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        ForEach(detail.files) { file in
                            DiffFileCard(file: file)
                        }
                    } else if !detail.changes.isEmpty {
                        Text("Changed files").appFont(.headline)
                        GroupBox {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(detail.changes.enumerated()), id: \.element.id) { index, change in
                                    HStack(spacing: 8) {
                                        Text(change.changeType.prefix(1).uppercased())
                                            .appFont(fixed: 9, weight: .bold)
                                            .frame(width: 16, height: 16)
                                            .background(changeTint(change.changeType).opacity(0.18))
                                            .foregroundStyle(changeTint(change.changeType))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                        Text(change.path)
                                            .appFont(.caption, design: .monospaced)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    if index < detail.changes.count - 1 { Divider() }
                                }
                            }
                        }
                        if repository.source == .azureDevOps {
                            Text("Azure DevOps returns file paths for a commit but no patch; open in the browser for the diff.")
                                .appFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("No file changes recorded.")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading commit…").appFont(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func changeTint(_ type: String) -> Color {
        switch type {
        case "add", "added": return .green
        case "delete", "removed": return .orange
        case "rename", "renamed": return .accentColor
        default: return .secondary
        }
    }

    private func load() async {
        do {
            switch repository.source {
            case .gitHub:
                let config = appState.config.tasks?.providers.github ?? GitHubProviderConfig()
                detail = try await GitHubPullRequestService(config: config)
                    .getCommitDetail(owner: repository.container, repo: repository.repository, sha: commit.id)
            case .azureDevOps:
                guard let repoId = repository.repositoryId else {
                    throw AzDevOpsError.invalidUrl(repository.displayName)
                }
                detail = try await appState.devOpsService
                    .getCommitDetail(repositoryId: repoId, sha: commit.id, project: repository.container)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
