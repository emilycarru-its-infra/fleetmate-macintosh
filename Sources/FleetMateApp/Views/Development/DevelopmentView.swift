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
        // First and the default: the checkouts people and agents work in.
        case repos = "Repos"
        case pullRequests = "Pulls"
        case commits = "Commits"
        case pipelines = "Pipelines"
        case skills = "Skills"
    }

    @Published var segment: Segment = .repos
    /// The Repos segment: tracked checkouts, their files, changes and editor.
    let repos = RepoWorkspaceModel()
    /// The GitHub inbox, shown in a toolbar popover rather than as a segment.
    @Published var showInbox = false
    @Published var selectedSkill: SkillCatalog.Entry?

    // Pull requests
    @Published private(set) var queue = PullRequestQueue()
    @Published private(set) var isLoadingPullRequests = false
    @Published private(set) var pullRequestsLoadedAt: Date?
    @Published var selectedSource: PullRequestSource?
    @Published var selectedRepo: String?
    @Published var selectedCommitRepo: String?
    @Published var selectedPipelineRepo: String?
    @Published var onlyMine = false
    /// Pulls list layout: one list by last modified (the default), or
    /// sections per repository. Remembered across launches.
    @Published var pullsGroupedByRepo = UserDefaults.standard.bool(forKey: "development.pulls.grouped") {
        didSet { UserDefaults.standard.set(pullsGroupedByRepo, forKey: "development.pulls.grouped") }
    }
    /// Oldest modified first instead of newest.
    @Published var pullsOldestFirst = UserDefaults.standard.bool(forKey: "development.pulls.oldestFirst") {
        didSet { UserDefaults.standard.set(pullsOldestFirst, forKey: "development.pulls.oldestFirst") }
    }
    /// Repository groups the Pulls list shows collapsed, by group key
    /// ("Project/Repo"). Remembered across launches; a new repository opens
    /// expanded.
    @Published var collapsedPullGroups = Set(UserDefaults.standard.stringArray(forKey: "development.pulls.collapsedGroups") ?? []) {
        didSet {
            UserDefaults.standard.set(collapsedPullGroups.sorted(), forKey: "development.pulls.collapsedGroups")
        }
    }
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
        if let selectedCommitRepo { rows = rows.filter { $0.repositoryFilterScope.matches(selectedCommitRepo, legacyKey: $0.displayName) } }
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
    @Published var pipelineStatusFilter: PipelineRunStatus? {
        didSet { if pipelineStatusFilter != nil { approvalFilter = false } }
    }
    /// Shows only runs held on an approval. Exclusive with the status filter.
    @Published var approvalFilter = false {
        didSet { if approvalFilter { pipelineStatusFilter = nil } }
    }
    /// How far back the Pipelines segment looks.
    static let pipelinesWindow: TimeInterval = 7 * 24 * 3600

    /// Pending approvals holding Azure Pipelines runs, keyed by `approvalKey`.
    @Published private(set) var pendingApprovals: [String: [PipelineApproval]] = [:]
    /// The run whose approval sheet is open, set from the row's context menu too.
    @Published var reviewingApprovalRunID: String?
    /// Approval id → build id, once a timeline has resolved it; ids never move.
    private var approvalBuilds: [String: Int] = [:]

    private var pipelinesTask: Task<Void, Never>?
    private var pipelineRefreshTask: Task<Void, Never>?
    private var pipelineRefresh = PipelineRefreshPolicy()
    private var pipelineRepos: [(owner: String, name: String)] = []
    private var pipelineProjects: [String] = []
    private var repositoryCursor = 0
    private var projectCursor = 0
    private var activeCursor = 0
    private var activeProjectCursor = 0
    var pipelinesVisible = false

    /// App-owned, one worker: tab changes never create additional pollers.
    func startPipelineRefresh(appState: AppState) {
        guard pipelineRefreshTask == nil else { return }
        pipelineRefreshTask = Task { [weak self, weak appState] in
            while !Task.isCancelled {
                guard let self, let appState else { return }
                self.checkPipelineFreshness(appState: appState)
                do { try await Task.sleep(for: .seconds(NSApplication.shared.isActive ? 5 : 60)) }
                catch { return }
            }
        }
    }

    func checkPipelineFreshness(appState: AppState) {
        guard NSApplication.shared.isActive,
              NSApplication.shared.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible && !$0.isMiniaturized }),
              pipelineRefresh.isDue(now: Date(), visible: pipelinesVisible, activeRuns: pipelineRuns.contains { $0.status.isActive }) else { return }
        loadPipelines(appState: appState, force: true, discovery: false)
    }

    private static func approvalKey(project: String, buildId: Int) -> String { "\(project)#\(buildId)" }

    func approvals(for run: PipelineRun) -> [PipelineApproval] {
        guard run.source == .azureDevOps, run.status.isActive else { return [] }
        return pendingApprovals[Self.approvalKey(project: run.container, buildId: run.runId)] ?? []
    }

    func isAwaitingApproval(_ run: PipelineRun) -> Bool { !approvals(for: run).isEmpty }

    /// Reads pending approvals for the projects that have active runs and
    /// pins each to its run. Environment approvals name their build;
    /// ManualValidation ones are found in the active runs' timelines.
    func refreshApprovals(appState: AppState, projects: Set<String>? = nil) async {
        let active = pipelineRuns.filter { $0.source == .azureDevOps && $0.status.isActive }
        let byProject = Dictionary(grouping: active, by: \.container)
        let targets = projects ?? Set(byProject.keys)
        var next = pendingApprovals.filter { key, _ in
            !targets.contains(where: { key.hasPrefix("\($0)#") }) && active.contains { Self.approvalKey(project: $0.container, buildId: $0.runId) == key }
        }
        for project in targets.sorted() {
            guard let runs = byProject[project], !runs.isEmpty else { continue }
            guard let approvals = try? await appState.devOpsService.getPendingApprovals(project: project) else {
                // Keep what we knew rather than dropping the badge on a blip.
                for run in runs {
                    let key = Self.approvalKey(project: project, buildId: run.runId)
                    if let known = pendingApprovals[key] { next[key] = known }
                }
                continue
            }
            var resolved: [PipelineApproval] = approvals.compactMap { approval in
                if let build = approval.buildId ?? approvalBuilds[approval.id.lowercased()] { return approval.assigned(to: build) }
                return nil
            }
            let unresolved = approvals.filter { approval in !resolved.contains { $0.id == approval.id } }
            if !unresolved.isEmpty {
                for run in runs {
                    guard let open = try? await appState.devOpsService.getOpenTimelineIdentifiers(project: project, buildId: run.runId) else { continue }
                    for approval in unresolved where open.contains(approval.id.lowercased()) {
                        approvalBuilds[approval.id.lowercased()] = run.runId
                        resolved.append(approval.assigned(to: run.runId))
                    }
                }
            }
            for approval in resolved {
                guard let build = approval.buildId else { continue }
                next[Self.approvalKey(project: project, buildId: build), default: []].append(approval)
            }
        }
        guard !Task.isCancelled else { return }
        if next != pendingApprovals { pendingApprovals = next }
    }

    /// Approves or rejects, then drops the approval locally and re-reads the run.
    func respond(to approval: PipelineApproval, approve: Bool, comment: String, appState: AppState) async throws {
        try await appState.devOpsService.respondToApproval(project: approval.project, approvalId: approval.id, approve: approve, comment: comment)
        if let build = approval.buildId {
            let key = Self.approvalKey(project: approval.project, buildId: build)
            pendingApprovals[key]?.removeAll { $0.id == approval.id }
            if pendingApprovals[key]?.isEmpty == true { pendingApprovals[key] = nil }
        }
        loadPipelines(appState: appState, force: true, discovery: false)
    }

    private func rotating<T>(_ values: [T], cursor: inout Int, count: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let result = (0..<min(count, values.count)).map { values[(cursor + $0) % values.count] }
        cursor = (cursor + result.count) % values.count
        return result
    }

    func visiblePipelineRuns(matching search: String) -> [PipelineRun] {
        var rows = pipelineRuns
        if let selectedSource { rows = rows.filter { $0.source == selectedSource } }
        if let selectedPipelineRepo { rows = rows.filter { $0.repositoryFilterScope.matches(selectedPipelineRepo, legacyKey: Self.pipelineRepoKey($0)) } }
        if let pipelineStatusFilter {
            rows = rows.filter { matches($0, status: pipelineStatusFilter) }
        }
        if approvalFilter { rows = rows.filter(isAwaitingApproval) }
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
    private var latestRunIDs: Set<String> = []

    private func updateLatestRunIDs() {
        var latest: [String: PipelineRun] = [:]
        for run in pipelineRuns {
            let key = "\(run.source.rawValue):\(run.container)/\(run.pipelineId.map(String.init) ?? run.pipelineName)"
            if let current = latest[key], current.sortDate >= run.sortDate { continue }
            latest[key] = run
        }
        latestRunIDs = Set(latest.values.map(\.id))
    }

    /// Repositories with commits in the current source scope, by commit count.
    var commitRepoCounts: [(repo: String, count: Int)] {
        let scoped = selectedSource.map { s in repositoryCommits.filter { $0.source == s } } ?? repositoryCommits
        var counts: [String: Int] = [:]
        for repo in scoped { counts[repo.displayName, default: 0] += repo.commits.count }
        guard counts.count > 1 else { return [] }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    /// A run's repository, or its project when the run has none.
    static func pipelineRepoKey(_ run: PipelineRun) -> String {
        run.repository.map { "\(run.container)/\($0)" } ?? run.container
    }

    var pipelineRepoCounts: [(repo: String, count: Int)] {
        let scoped = selectedSource.map { s in pipelineRuns.filter { $0.source == s } } ?? pipelineRuns
        return scoped.repoCounts(Self.pipelineRepoKey)
    }

    func togglePipelineStatus(_ status: PipelineRunStatus) {
        pipelineStatusFilter = (pipelineStatusFilter == status) ? nil : status
    }

    /// Runs held on an approval, across every source in scope.
    var approvalRunCount: Int { pipelineRuns.filter(isAwaitingApproval).count }

    func loadPipelines(appState: AppState, force: Bool = false, discovery: Bool = true) {
        guard !isLoadingPipelines else { return }
        if !force, let at = pipelinesLoadedAt, Date().timeIntervalSince(at) < 60 { return }
        isLoadingPipelines = true
        pipelinesTask = Task { await performPipelinesLoad(appState: appState, discovery: discovery) }
    }

    private func performPipelinesLoad(appState: AppState, discovery: Bool) async {
        defer { isLoadingPipelines = false }
        let now = Date()
        let since = now.addingTimeInterval(-Self.pipelinesWindow)
        let full = discovery || pipelineRefresh.needsDiscovery(now: now)
        let github = GitHubActionsService(config: gitHubConfig(appState))
        var updates: [PipelineRun] = []
        var errors: [String] = []
        var succeeded = false

        do {
            if full { pipelineRepos = try await github.getRecentRepositories() }
            let repos = full ? pipelineRepos : rotating(pipelineRepos, cursor: &repositoryCursor, count: 2)
            let result = await github.getRecentRuns(repositories: repos, since: since)
            updates += result.runs
            if let error = result.error { throw NSError(domain: "GitHub", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if !repos.isEmpty { succeeded = true }
            if !full {
                let active = pipelineRuns.filter { $0.source == .gitHub && $0.status.isActive }
                var targets = rotating(active, cursor: &activeCursor, count: 2)
                if let selectedRun, selectedRun.source == .gitHub, selectedRun.status.isActive,
                   !targets.contains(where: { $0.id == selectedRun.id }) {
                    targets = [selectedRun] + targets.prefix(1)
                }
                for run in targets {
                    guard let repo = run.repository else { continue }
                    updates.append(try await github.getRun(owner: run.container, repo: repo, runId: run.runId))
                }
            }
        } catch {
            if !error.localizedDescription.contains("No GitHub authentication token") {
                errors.append("GitHub: \(error.localizedDescription)")
            }
        }

        if appState.config.isDevOpsConfigured {
            do {
                guard await appState.devOpsService.ensureValidToken() else {
                    throw NSError(domain: "Azure DevOps", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign-in unavailable"])
                }
                if full { pipelineProjects = try await appState.devOpsService.listProjects().map(\.name) }
                let projects = full ? pipelineProjects : rotating(pipelineProjects, cursor: &projectCursor, count: 2)
                for project in projects {
                    try Task.checkCancellation()
                    updates += try await appState.devOpsService.getRecentPipelineRuns(project: project, since: since)
                }
                if !full {
                    let active = pipelineRuns.filter { $0.source == .azureDevOps && $0.status.isActive }
                    let groups = Dictionary(grouping: active, by: \.container)
                    let names = rotating(groups.keys.sorted(), cursor: &activeProjectCursor, count: 2)
                    for project in names {
                        updates += try await appState.devOpsService.getPipelineRuns(project: project, buildIds: groups[project, default: []].map(\.runId))
                    }
                }
                succeeded = true
            } catch { errors.append("Azure DevOps: \(error.localizedDescription)") }
        }

        guard !Task.isCancelled else { return }
        let merged = PipelineRefreshPolicy.merge(pipelineRuns, updates: updates, now: now)
        if pipelineRuns != merged {
            pipelineRuns = merged
            updateLatestRunIDs()
        }
        pipelinesError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        let complete = succeeded && errors.isEmpty
        pipelineRefresh.finish(now: Date(), succeeded: complete, discovery: full)
        if complete { pipelinesLoadedAt = Date() }
        if let selected = selectedRun, let updated = merged.first(where: { $0.id == selected.id }), selected != updated {
            selectedRun = updated
        }
        if appState.config.isDevOpsConfigured { await refreshApprovals(appState: appState) }
    }

    // Comment activity, shown in the toolbar's Recent Activity popover.
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

    func notificationAuthor(_ notification: GitHubNotification) -> String? {
        guard notification.subjectType == .pullRequest, let number = notification.subjectNumber else { return nil }
        return queue.pullRequests.first {
            $0.source == .gitHub && $0.number == number
                && $0.container.caseInsensitiveCompare(notification.owner) == .orderedSame
                && $0.repository.caseInsensitiveCompare(notification.repositoryName) == .orderedSame
        }?.authorName
    }

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
        if let selectedRepo { rows = rows.filter { $0.repositoryFilterScope.matches(selectedRepo, legacyKey: $0.repository) } }
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
        let oldestFirst = pullsOldestFirst
        return rows.sorted { oldestFirst ? $0.lastActivity < $1.lastActivity : $0.lastActivity > $1.lastActivity }
    }

    /// Rows grouped by "container/repository", in the chosen modified order.
    func groupedPullRequests(matching search: String) -> [(key: String, rows: [UnifiedPullRequest])] {
        let rows = visiblePullRequests(matching: search)
        var buckets: [String: [UnifiedPullRequest]] = [:]
        for pr in rows { buckets["\(pr.container)/\(pr.repository)", default: []].append(pr) }
        return buckets
            .map { (key: $0.key, rows: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.rows.first?.lastActivity ?? .distantPast
                let r = rhs.rows.first?.lastActivity ?? .distantPast
                return l == r ? lhs.key < rhs.key : (pullsOldestFirst ? l < r : l > r)
            }
    }

    /// Click a group header to collapse or expand it. With Option held, every
    /// group follows the one clicked, as in a Finder outline.
    func togglePullGroup(_ key: String, all: Bool) {
        let collapse = !collapsedPullGroups.contains(key)
        if all {
            setAllPullGroups(collapsed: collapse)
        } else if collapse {
            collapsedPullGroups.insert(key)
        } else {
            collapsedPullGroups.remove(key)
        }
    }

    /// View › Collapse All Groups and Expand All Groups.
    func setAllPullGroups(collapsed: Bool) {
        if collapsed {
            collapsedPullGroups.formUnion(groupedPullRequests(matching: searchText).map(\.key))
        } else {
            collapsedPullGroups.removeAll()
        }
    }

    var repositoryOptions: [RepositoryFilterEntry] {
        RepositoryFilterEntry.counts(sourceScoped, scope: \.repositoryFilterScope)
    }

    var commitRepositoryOptions: [RepositoryFilterEntry] {
        let rows = selectedSource.map { source in repositoryCommits.filter { $0.source == source } } ?? repositoryCommits
        return RepositoryFilterEntry.counts(rows, scope: \.repositoryFilterScope, legacyKey: \.displayName, weight: { $0.commits.count })
    }

    var pipelineRepositoryOptions: [RepositoryFilterEntry] {
        let rows = selectedSource.map { source in pipelineRuns.filter { $0.source == source } } ?? pipelineRuns
        return RepositoryFilterEntry.counts(rows, scope: \.repositoryFilterScope, legacyKey: Self.pipelineRepoKey)
    }

    var selectedRepoLabel: String? {
        selectedRepo.map { value in
            repositoryOptions.first(where: { $0.id == value })?.legacyKey
                ?? RepositoryFilterScope(id: value)?.repository ?? value
        }
    }
    var selectedCommitRepoLabel: String? {
        selectedCommitRepo.map { value in
            commitRepositoryOptions.first(where: { $0.id == value })?.legacyKey
                ?? RepositoryFilterScope.displayKey(value) ?? value
        }
    }
    var selectedPipelineRepoLabel: String? {
        selectedPipelineRepo.map { value in
            pipelineRepositoryOptions.first(where: { $0.id == value })?.legacyKey
                ?? RepositoryFilterScope.displayKey(value) ?? value
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
        selectedCommitRepo = nil
        selectedPipelineRepo = nil
    }

    func toggleRepo(_ repo: String) {
        selectedRepo = (selectedRepoLabel == repo) ? nil : repo
    }

    // MARK: Loading

    // MARK: Links

    /// Open what a `fleetmate://` link names: switch to its segment and select
    /// it, fetching it by id when the lists don't hold it.
    /// A link that arrived before Azure DevOps sign-in finished, opened again
    /// once it does.
    @Published var linkAwaitingSignIn: FleetMateLink?

    func open(_ link: FleetMateLink, appState: AppState) {
        searchText = ""
        let startedSignedIn = appState.devOpsSsoAuthenticated
        Task {
            do {
                switch link {
                case .pullRequest(let host, let number):
                    segment = .pullRequests
                    selectedSource = nil
                    selectedRepo = nil
                    onlyMine = false
                    if let pr = queue.pullRequests.first(where: { Self.matches($0, host: host, number: number) }) {
                        selectedPullRequest = pr
                        return
                    }
                    let fetched: UnifiedPullRequest?
                    switch host {
                    case .azureDevOps(let project, let repo):
                        fetched = try await appState.devOpsService.getUnifiedPullRequest(project: project, repository: repo, id: number)
                    case .gitHub(let owner, let repo):
                        fetched = try await GitHubPullRequestService(config: gitHubConfig(appState))
                            .getPullRequest(owner: owner, repo: repo, number: number)
                    }
                    guard let fetched else { throw LinkOpenError("Pull request \(number) was not found.") }
                    selectedPullRequest = fetched

                case .commit(let host, let sha):
                    segment = .commits
                    if let repo = repositoryCommits.first(where: { Self.matches($0, host: host) }),
                       let commit = repo.commits.first(where: { $0.id.hasPrefix(sha) || sha.hasPrefix($0.id) }) {
                        selectedCommit = .init(repository: repo, commit: commit)
                        return
                    }
                    // Not in the recent list: the detail pane loads it by sha.
                    let repository: RepositoryCommits
                    switch host {
                    case .azureDevOps(let project, let repo):
                        repository = RepositoryCommits(source: .azureDevOps, container: project, repository: repo,
                                                       repositoryId: repo, webUrl: "", defaultBranch: nil, commits: [])
                    case .gitHub(let owner, let repo):
                        repository = RepositoryCommits(source: .gitHub, container: owner, repository: repo,
                                                       webUrl: "https://github.com/\(owner)/\(repo)", defaultBranch: nil, commits: [])
                    }
                    selectedCommit = .init(repository: repository,
                                           commit: PullRequestCommit(id: sha, message: "", authorName: nil, date: nil))

                case .azureDevOpsRun(let project, let runId):
                    segment = .pipelines
                    pipelineStatusFilter = nil
                    approvalFilter = false
                    if let run = pipelineRuns.first(where: { $0.source == .azureDevOps && $0.runId == runId }) {
                        selectedRun = run
                    } else {
                        selectedRun = try await appState.devOpsService.getPipelineRun(project: project, buildId: runId)
                    }

                case .gitHubRun(let owner, let repo, let runId):
                    segment = .pipelines
                    pipelineStatusFilter = nil
                    approvalFilter = false
                    if let run = pipelineRuns.first(where: { $0.source == .gitHub && $0.runId == runId }) {
                        selectedRun = run
                    } else {
                        selectedRun = try await GitHubActionsService(config: gitHubConfig(appState))
                            .getRun(owner: owner, repo: repo, runId: runId)
                    }

                case .azureDevOpsPipeline(let project, let definitionId):
                    // A pipeline opens on its latest run. The list may not have
                    // loaded yet (a link from a cold launch), so ask for it.
                    segment = .pipelines
                    pipelineStatusFilter = nil
                    approvalFilter = false
                    if let run = pipelineRuns
                        .filter({ $0.source == .azureDevOps && $0.container == project && $0.pipelineId == definitionId })
                        .first {
                        selectedRun = run
                    } else if let run = try await appState.devOpsService
                        .getLatestPipelineRun(project: project, definitionId: definitionId) {
                        selectedRun = run
                    } else {
                        throw LinkOpenError("Pipeline \(definitionId) in \(project) has no runs.")
                    }

                case .workItem, .gitHubIssue, .device, .asset, .ticket, .user, .group, .reporting:
                    break // Routed to Projects by AppState.
                }
            } catch {
                // Opened from a cold launch, the lookup races sign-in and
                // loses. Hold the link rather than report a failure.
                let retry: SignInRetry = link.needsAzureDevOps
                    ? appState.devOpsRetry(startedSignedIn: startedSignedIn)
                    : .showError
                switch retry {
                case .retryNow:
                    open(link, appState: appState)
                case .waitForSignIn:
                    linkAwaitingSignIn = link
                case .showError:
                    appState.linkError = error.localizedDescription
                }
            }
        }
    }

    private struct LinkOpenError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func matches(_ pr: UnifiedPullRequest, host: FleetMateLink.Host, number: Int) -> Bool {
        guard pr.number == number else { return false }
        switch host {
        case .azureDevOps(let project, let repo):
            return pr.source == .azureDevOps && pr.container.caseInsensitiveCompare(project) == .orderedSame
                && pr.repository.caseInsensitiveCompare(repo) == .orderedSame
        case .gitHub(let owner, let repo):
            return pr.source == .gitHub && pr.container.caseInsensitiveCompare(owner) == .orderedSame
                && pr.repository.caseInsensitiveCompare(repo) == .orderedSame
        }
    }

    private static func matches(_ repo: RepositoryCommits, host: FleetMateLink.Host) -> Bool {
        switch host {
        case .azureDevOps(let project, let name):
            return repo.source == .azureDevOps && repo.container.caseInsensitiveCompare(project) == .orderedSame
                && repo.repository.caseInsensitiveCompare(name) == .orderedSame
        case .gitHub(let owner, let name):
            return repo.source == .gitHub && repo.container.caseInsensitiveCompare(owner) == .orderedSame
                && repo.repository.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func gitHubConfig(_ appState: AppState) -> GitHubProviderConfig {
        appState.config.tasks?.providers.github ?? GitHubProviderConfig()
    }

    func loadAll(appState: AppState, force: Bool = false) {
        loadPullRequests(appState: appState, force: force)
        loadInbox(appState: appState, force: force)
        loadCommits(appState: appState, force: force)
        loadPipelines(appState: appState, force: force, discovery: force)
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
            if let url = URL(string: notification.webUrl) { NSWorkspace.shared.openInBrowser(url) }
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
                NSWorkspace.shared.openInBrowser(url)
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

    /// The Repos segment's list is narrow: the editor needs the room.
    private var listWidth: CGFloat { model.segment == .repos ? 280 : 470 }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            // Each segment's own graphs: Repos carries the repository
            // statistics, the others summarise the list below them. The
            // workspace owns the screen: the strip takes at most two fifths
            // of the tab and scrolls past that.
            DevelopmentWidgetsSection(model: model, knowledge: appState.knowledge,
                                      maxHeight: max(180, geometry.size.height * 0.4))
            HStack(spacing: 0) {
                // Leading-aligned and clipped: content wider than the column
                // must never centre itself and push the list off the window.
                leftPane
                    .frame(width: listWidth, alignment: .leading)
                    .clipped()
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .toolbar { developmentToolbar }
        // Filters the list in view by title, repository, author, branch or
        // number, from the toolbar's one search field.
        // In Repos, the field filters the file tree and Return searches
        // every file's contents.
        .tabSearch(text: $model.searchText, prompt: searchPrompt, onSubmit: { [model] in
            guard model.segment == .repos else { return }
            Task { await model.repos.grep(model.searchText) }
        })
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
                }
            }
        }
        .onDevOpsSignIn(appState) {
            // Lists loaded before sign-in left out Azure DevOps entirely.
            model.loadPullRequests(appState: appState, force: true)
            model.loadCommits(appState: appState, force: true)
            model.loadPipelines(appState: appState, force: true)
            if let link = model.linkAwaitingSignIn {
                model.linkAwaitingSignIn = nil
                model.open(link, appState: appState)
            }
        }
        .onAppear {
            model.pipelinesVisible = model.segment == .pipelines
            model.checkPipelineFreshness(appState: appState)
            consumeLink()
        }
        .onDisappear { model.pipelinesVisible = false }
        .onChange(of: model.segment) { _, segment in
            model.pipelinesVisible = segment == .pipelines
            model.checkPipelineFreshness(appState: appState)
            if segment == .pullRequests { model.loadPullRequests(appState: appState) }
            if segment == .commits { model.loadCommits(appState: appState) }
        }
        .onChange(of: appState.pendingDevelopmentLink) { _, _ in consumeLink() }
        .actionErrorBanner($model.actionError)
    }

    private func consumeLink() {
        guard let link = appState.pendingDevelopmentLink else { return }
        appState.pendingDevelopmentLink = nil
        model.open(link, appState: appState)
    }

    private var searchText: String { model.searchText }

    private var searchPrompt: String {
        switch model.segment {
        case .pullRequests: return "Filter pull requests"
        case .commits: return "Filter commits"
        case .pipelines: return "Filter runs"
        case .skills: return "Filter skills and hooks"
        case .repos: return "Filter files · Return searches contents"
        }
    }

    @ToolbarContentBuilder
    private var developmentToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            SegmentedPill(
                selection: $model.segment,
                options: DevelopmentModel.Segment.allCases,
                label: { $0.rawValue },
                segmentWidth: nil
            )

            Button {
                model.showInbox.toggle()
                if model.showInbox { model.loadInbox(appState: appState, force: true) }
            } label: {
                Label("Inbox", systemImage: model.unreadCount > 0 ? "tray.full" : "tray")
            }
            .help(model.inboxError == nil ? "GitHub notification inbox" : "GitHub inbox needs attention")
            .popover(isPresented: $model.showInbox, arrowEdge: .bottom) {
                inboxList.frame(width: 440, height: 520)
            }

            Button(action: {
                if model.segment == .repos {
                    model.repos.reloadRecords()
                    Task { await model.repos.refreshStatuses(); await model.repos.loadSelected() }
                    return
                }
                if model.segment == .skills {
                    Task { await appState.knowledge.sync(token: await appState.devOpsService.currentToken()) }
                    return
                }
                // A manual refresh is the on-demand full resync: GitHub
                // searches refetch everything instead of only what changed.
                GitHubLocalCache.shared.invalidateSearches()
                model.loadAll(appState: appState, force: true)
            }) {
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
            case .commits: commitsList
            case .pipelines: PipelinesListView(model: model, searchText: searchText)
            case .skills: SkillsListView(knowledge: appState.knowledge, selection: $model.selectedSkill, filter: searchText)
            case .repos: ReposListView(model: model.repos)
            }
        }
    }

    // MARK: Pull requests

    private var pullRequestList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoadingPullRequests { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            filterRows
            Divider()
            let rows = model.visiblePullRequests(matching: searchText)
            if rows.isEmpty {
                emptyPullRequests
            } else if model.pullsGroupedByRepo {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.groupedPullRequests(matching: searchText), id: \.key) { group in
                            Section {
                                if !model.collapsedPullGroups.contains(group.key) {
                                    ForEach(group.rows) { pr in pullRequestRow(pr, showRepository: false) }
                                }
                            } header: {
                                repoHeader(group.key, count: group.rows.count)
                            }
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { pr in pullRequestRow(pr, showRepository: true) }
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

    @ViewBuilder
    private func pullRequestRow(_ pr: UnifiedPullRequest, showRepository: Bool) -> some View {
        CodePullRequestRow(
            pullRequest: pr,
            isSelected: model.selectedPullRequest?.id == pr.id,
            showRepository: showRepository
        ) {
            model.selectedPullRequest = pr
        }
        Divider().padding(.leading, 12)
    }

    private var pullsSortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.pullsOldestFirst) {
                Text("Recently Modified").tag(false)
                Text("Least Recently Modified").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Group by Repository", isOn: $model.pullsGroupedByRepo)
            if model.pullsGroupedByRepo {
                Divider()
                Button("Expand All Groups") { model.setAllPullGroups(collapsed: false) }
                Button("Collapse All Groups") { model.setAllPullGroups(collapsed: true) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sorted by \(model.pullsOldestFirst ? "least" : "most") recently modified\(model.pullsGroupedByRepo ? ", grouped by repository" : "")")
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
                if model.repositoryOptions.count > 1 || model.selectedRepo != nil {
                    RepoFilterMenu(selection: $model.selectedRepo, entries: model.repositoryOptions)
                        .layoutPriority(-1)
                }
                pullsSortMenu
                Spacer(minLength: 0)
                Text("\(model.visiblePullRequests(matching: searchText).count) open")
                    .lineLimit(1)
                    .fixedSize()
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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
        // A chip keeps its one-line size; the repository menu gives way instead.
        .lineLimit(1)
        .fixedSize()
    }

    /// A repository group's header: click to collapse or expand it,
    /// Option-click to collapse or expand every group.
    private func repoHeader(_ key: String, count: Int) -> some View {
        let collapsed = model.collapsedPullGroups.contains(key)
        return Button {
            let all = NSEvent.modifierFlags.contains(.option)
            withAnimation(.easeInOut(duration: 0.15)) { model.togglePullGroup(key, all: all) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .appFont(fixed: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand \(key) (Option-click expands every group)" : "Collapse \(key) (Option-click collapses every group)")
        .accessibilityLabel("\(key), \(count) pull requests")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .contextMenu {
            Button(collapsed ? "Expand" : "Collapse") { model.togglePullGroup(key, all: false) }
            Divider()
            Button("Expand All Groups") { model.setAllPullGroups(collapsed: false) }
            Button("Collapse All Groups") { model.setAllPullGroups(collapsed: true) }
        }
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
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.loadInbox(appState: appState, force: true)
                } label: {
                    Label("Refresh Inbox", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoadingInbox)
                .help("Refresh GitHub notifications")
                Button {
                    model.markAllRead(appState: appState)
                } label: {
                    Label("Mark all read", systemImage: "envelope.open").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(model.unreadCount == 0)
                .help("Mark every notification as read")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            let rows = model.visibleNotifications
            if let error = model.inboxError, !rows.isEmpty {
                Text("Refresh failed. Showing previously loaded notifications. \(error)")
                    .appFont(.caption).foregroundStyle(.secondary).padding(12)
            }
            Text("Latest 200 notifications. A PR author is shown when its details are loaded.")
                .appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
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
                                pullRequestAuthor: model.notificationAuthor(notification),
                                isBusy: model.busyThreadIds.contains(notification.id),
                                onOpen: {
                                    model.open(notification, appState: appState)
                                    model.segment = .pullRequests
                                    model.showInbox = false
                                },
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
                if model.commitRepositoryOptions.count > 1 || model.selectedCommitRepo != nil {
                    RepoFilterMenu(selection: $model.selectedCommitRepo, entries: model.commitRepositoryOptions)
                }
                Spacer()
                if let at = model.commitsLoadedAt {
                    Text("Checked \(DevelopmentView.relative(at))")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
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
                Text(branch).appFont(.caption2, design: .monospaced).foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if model.segment == .repos {
            RepoGitView(model: model.repos, searchText: searchText)
        } else if model.segment == .skills {
            if let entry = model.selectedSkill {
                SkillDetailView(entry: entry).id(entry.id)
            } else {
                ContentUnavailableView(
                    "Select a skill",
                    systemImage: "wand.and.stars",
                    description: Text("The skills, hooks and standards every repository's agents follow, as on main.")
                )
            }
        } else if model.segment == .pipelines {
            if let run = model.selectedRun {
                PipelineRunDetailView(run: run, model: model) {
                    model.loadPipelines(appState: appState, force: true)
                }
                .id(run.id)
                .environmentObject(appState)
            } else if model.linkAwaitingSignIn != nil {
                DevOpsSignInWaitView(subject: "the linked run", error: nil)
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
        } else if model.linkAwaitingSignIn != nil {
            DevOpsSignInWaitView(subject: "the linked pull request", error: nil)
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
    /// Names the repository on the row, for the ungrouped list.
    var showRepository = false
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
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
                        if showRepository {
                            Text(pullRequest.repository)
                                .appFont(.caption2, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("·").foregroundStyle(.secondary)
                        }
                        Text(pullRequest.authorName)
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
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
        .agentContextDrag { .pullRequest(pullRequest) }
        .contextMenu {
            AgentContextMenuItems(.pullRequest(pullRequest))
            Divider()
            Button("Open in Browser") {
                if let url = URL(string: pullRequest.webUrl) { NSWorkspace.shared.openInBrowser(url) }
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
        CopyTitleLinkButton(title: pullRequest.title, link: pullRequest.webUrl)
            .padding(.trailing, 8)
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
    var pullRequestAuthor: String? = nil
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
                        if notification.subjectType == .pullRequest {
                            Text(pullRequestAuthor.map { "PR author: \($0)" } ?? "PR author unavailable")
                                .appFont(.caption).foregroundStyle(.secondary)
                        }
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
                                    .foregroundStyle(.secondary)
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
                        if let url = URL(string: notification.webUrl) { NSWorkspace.shared.openInBrowser(url) }
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
                if let url = URL(string: notification.webUrl) { NSWorkspace.shared.openInBrowser(url) }
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


// MARK: - Comment activity

/// One comment in the Recent Activity popover's Development feed.
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
                            .foregroundStyle(.secondary)
                    }
                    if isHovering, let url = entry.comment.url.flatMap(URL.init) {
                        Button {
                            NSWorkspace.shared.openInBrowser(url)
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
                    Text("·").foregroundStyle(.secondary)
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
        .agentContextDrag { .commit(commit, in: repository) }
        .contextMenu {
            AgentContextMenuItems(.commit(commit, in: repository))
            Divider()
            Button("Open in Browser") {
                if let url = commit.url.flatMap(URL.init) { NSWorkspace.shared.openInBrowser(url) }
            }
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
            }
            Button("Copy Link") {
                guard let url = commit.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            .disabled(commit.url == nil)
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
    /// The load failed before Azure DevOps sign-in finished; it runs again
    /// once sign-in completes.
    @State private var awaitingSignIn = false
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
        .onDevOpsSignIn(appState) {
            if awaitingSignIn { Task { await load() } }
        }
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
                    Text("·").foregroundStyle(.secondary)
                    Text(commit.authorName ?? "unknown").appFont(.caption).foregroundStyle(.secondary)
                    if let date = commit.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
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
            AgentContextButton(.commit(commit, in: selection.repository))
            Button {
                guard let url = commit.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "link")
            }
            .disabled(commit.url == nil)
            .help("Copy link")
            Button {
                if let url = commit.url.flatMap(URL.init) { NSWorkspace.shared.openInBrowser(url) }
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
        if awaitingSignIn {
            DevOpsSignInWaitView(subject: "commit \(commit.shortSha)", error: loadError)
        } else if let loadError {
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
                            Spacer()
                            DiffLayoutPicker()
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
                        Text("These files are binary or too large to show as a diff.")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
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
        awaitingSignIn = false
        loadError = nil
        let startedSignedIn = appState.devOpsSsoAuthenticated
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
            let retry: SignInRetry = repository.source == .azureDevOps
                ? appState.devOpsRetry(startedSignedIn: startedSignedIn)
                : .showError
            switch retry {
            case .retryNow:
                await load()
            case .waitForSignIn:
                awaitingSignIn = true
                loadError = error.localizedDescription
            case .showError:
                loadError = error.localizedDescription
            }
        }
    }
}
