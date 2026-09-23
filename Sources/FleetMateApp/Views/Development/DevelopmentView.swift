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
        .searchable(text: $model.searchText, prompt: "Search pull requests...")
        .toolbar { developmentToolbar }
        .task {
            model.loadAll(appState: appState)
            // Inbox freshness matters more than anywhere else in the app:
            // missing a review request for an hour is the failure mode this
            // tab exists to fix.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                model.loadInbox(appState: appState, force: true)
                model.loadPullRequests(appState: appState, force: true)
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

    @ToolbarContentBuilder
    private var developmentToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            SegmentedPill(
                selection: $model.segment,
                options: DevelopmentModel.Segment.allCases,
                label: { $0 == .inbox && model.unreadCount > 0 ? "Inbox \(model.unreadCount)" : $0.rawValue }
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

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let pr = model.selectedPullRequest {
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
