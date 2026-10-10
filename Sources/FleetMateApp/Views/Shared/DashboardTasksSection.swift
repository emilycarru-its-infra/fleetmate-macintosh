import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Model

/// Backs the dashboard's side-by-side task tables: DevOps work items (from the
/// AppState cache) and GitHub issues for the signed-in account. Owned by
/// AppState so tab switches don't refetch.
@MainActor
final class DashboardTasksModel: ObservableObject {
    @Published private(set) var issues: [GitHubIssueSummary] = []
    @Published private(set) var issuesError: String?
    @Published private(set) var isLoadingIssues = false
    private var lastLoaded: Date?
    private var backoffUntil: Date?

    private static let freshness: TimeInterval = 5 * 60

    func load(appState: AppState, force: Bool = false) {
        if !force {
            if isLoadingIssues { return }
            if let lastLoaded, Date().timeIntervalSince(lastLoaded) < Self.freshness { return }
        }
        if (backoffUntil ?? .distantPast) > Date() { return }

        let config = appState.config.tasks?.providers.github ?? GitHubProviderConfig()
        isLoadingIssues = true
        Task {
            defer { isLoadingIssues = false }
            do {
                let fetched = try await GitHubPullRequestService(config: config).getMyIssues()
                issues = fetched
                issuesError = nil
                lastLoaded = Date()
            } catch {
                let message = error.localizedDescription
                if message.localizedCaseInsensitiveContains("rate limit") {
                    backoffUntil = Date().addingTimeInterval(15 * 60)
                    // Keep whatever rows we already have; just annotate.
                    issuesError = issues.isEmpty
                        ? "Rate limited — retrying later"
                        : "Rate limited — showing earlier results"
                } else {
                    issuesError = message
                }
                dbg.error("GitHub issues load failed: \(message)", category: "dashboard")
            }
        }
    }
}

// MARK: - Pane

/// The task side of the dashboard's 50/50 split: work items when the PR queue
/// is filtered to DevOps, GitHub issues when filtered to GitHub, both stacked
/// when the filter is cleared. Rows link out to their web UIs.
struct DashboardTasksPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var model: DashboardTasksModel
    /// Mirrors the PR queue's source filter, so one set of pills drives both
    /// halves of the split.
    let source: PullRequestSource?
    /// The PR queue's repo pill, applied to GitHub issues too.
    var repoFilter: String?

    private let rowLimit = 20
    /// When set, each list shows only this many rows at their natural height
    /// (no inner scroll) — the Projects tab's widget strip uses it.
    var compactRows: Int? = nil

    /// The row being read in place. Rows link out through the context menu.
    @State private var lightboxTask: UnifiedTask?

    /// Widest area path rendered so far, so the path column fits its longest
    /// entry instead of truncating, and the title column starts at one x.
    @State private var pathColumnWidth: CGFloat = 0

    /// The signed-in user's open work items across every project. The query
    /// already excludes finished states; filtering again keeps the list right
    /// when an item is closed from inside the app before the next refresh.
    private var activeWorkItems: [WorkItem] {
        let closed = Set(AzureDevOpsService.finishedWorkItemStates.map { $0.lowercased() })
        return appState.cachedMyWorkItems
            .filter { !closed.contains(($0.fields?.state ?? "").lowercased()) }
            .sorted { ($0.fields?.changedDate ?? "") > ($1.fields?.changedDate ?? "") }
    }

    private var visibleIssues: [GitHubIssueSummary] {
        guard let repoFilter else { return model.issues }
        return model.issues.filter {
            $0.repository.split(separator: "/").last.map(String.init) == repoFilter
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch source {
            case .azureDevOps:
                workItemsCard
            case .gitHub:
                issuesCard
            case nil:
                workItemsCard
                issuesCard
            }
        }
        .task { model.load(appState: appState) }
        .onAppCommand { command in
            if command == .refresh { model.load(appState: appState, force: true) }
        }
        .sheet(item: $lightboxTask) { task in
            TaskLightboxView(task: task)
                .environmentObject(appState)
        }
    }

    // MARK: DevOps work items

    @State private var workItemSearch = ""

    private var visibleWorkItems: [WorkItem] {
        guard !workItemSearch.isEmpty else { return activeWorkItems }
        return activeWorkItems.filter { item in
            let f = item.fields
            return String(item.id).contains(workItemSearch)
                || (f?.title?.localizedCaseInsensitiveContains(workItemSearch) ?? false)
                || (f?.areaPath?.localizedCaseInsensitiveContains(workItemSearch) ?? false)
                || (f?.iterationPath?.localizedCaseInsensitiveContains(workItemSearch) ?? false)
                || (f?.workItemType?.localizedCaseInsensitiveContains(workItemSearch) ?? false)
        }
    }

    /// Bespoke card (not `taskCard`): it carries its own search field and a
    /// scrollable full list rather than a capped one.
    private var workItemsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    BrandIcon(mark: PullRequestSource.azureDevOps.brandMark, size: 11)
                    Text("Work items").appFont(.subheadline, weight: .semibold)
                    Text("\(visibleWorkItems.count)")
                        .appFont(.caption2).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("Filter", text: $workItemSearch)
                            .textFieldStyle(.plain)
                            .appFont(.caption)
                            .frame(width: 110)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
                }
                .padding(.vertical, 6)

                Divider()

                if visibleWorkItems.isEmpty {
                    Text(workItemSearch.isEmpty ? "No active work items" : "No matches")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                    Spacer(minLength: 0)
                } else if let compactRows {
                    VStack(alignment: .leading, spacing: 0) {
                        let rows = Array(visibleWorkItems.prefix(compactRows))
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            workItemRow(item)
                            if index < rows.count - 1 { Divider() }
                        }
                    }
                    .onPreferenceChange(PathColumnWidthKey.self) { width in
                        if width > pathColumnWidth { pathColumnWidth = ceil(width) }
                    }
                } else {
                    // The ideal height is fixed so ~200 rows never set the
                    // card's height inside the dashboard's unbounded
                    // ScrollView; the max is open so the list fills the space
                    // when the pull-request column beside it is taller.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visibleWorkItems.enumerated()), id: \.element.id) { index, item in
                                workItemRow(item)
                                if index < visibleWorkItems.count - 1 { Divider() }
                            }
                        }
                        .onPreferenceChange(PathColumnWidthKey.self) { width in
                            // Only ever widen: shrinking as rows scroll out
                            // would make the title column jump.
                            if width > pathColumnWidth { pathColumnWidth = ceil(width) }
                        }
                    }
                    .frame(minHeight: 240, idealHeight: 540, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workItemRow(_ item: WorkItem) -> some View {
        Button {
            // Read it here, like a pull request; the Projects tab is one
            // click further in the lightbox header or the context menu.
            lightboxTask = TaskLightboxView.workItemStub(item, config: appState.config)
        } label: {
            // Invisible grid: fixed-width columns so pills line up down the
            // list. Area path leads (where the ids used to be) at its full
            // width — never truncated — and the title takes what is left and
            // truncates instead; then Type / Iteration / State pill columns.
            HStack(spacing: 8) {
                Text(breadcrumb(item.fields?.areaPath) ?? "")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: PathColumnWidthKey.self, value: geo.size.width)
                    })
                    .frame(minWidth: pathColumnWidth, alignment: .leading)
                    .layoutPriority(1)
                Text(item.fields?.title ?? "(untitled)")
                    .appFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pillColumn(item.fields?.workItemType, tint: .teal, width: 84)
                pillColumn(
                    breadcrumb(item.fields?.iterationPath)?
                        .split(separator: "›").last.map { $0.trimmingCharacters(in: .whitespaces) },
                    tint: .gray, width: 76
                )
                pillColumn(item.fields?.state, tint: .indigo, width: 62)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.fields?.title ?? "")
        .contextMenu {
            Button("Open in Projects") {
                appState.navigateToWorkItemId = item.id
                appState.navigateToTab = .projects
            }
            Button("Open in Azure DevOps") {
                if let url = workItemWebUrl(item) { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// "Projects\\Web\\Frontend" → "Projects › Web › Frontend".
    private func breadcrumb(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.split(separator: "\\").joined(separator: " › ")
    }

    private func workItemWebUrl(_ item: WorkItem) -> URL? {
        guard let org = appState.config.devopsOrganization,
              let project = item.fields?.teamProject?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(appState.config.effectiveDevopsBaseUrl)/\(org)/\(project)/_workitems/edit/\(item.id)")
    }

    // MARK: GitHub issues

    private var issuesCard: some View {
        taskCard(
            title: "GitHub issues",
            mark: PullRequestSource.gitHub.brandMark,
            count: visibleIssues.count,
            emptyText: model.isLoadingIssues ? "Loading…" : "No open issues",
            errorText: model.issuesError,
            isLoading: model.isLoadingIssues
        ) {
            let limit = compactRows ?? rowLimit
            ForEach(Array(visibleIssues.prefix(limit).enumerated()), id: \.element.id) { index, issue in
                issueRow(issue)
                if index < min(visibleIssues.count, limit) - 1 { Divider() }
            }
        }
    }

    private func issueRow(_ issue: GitHubIssueSummary) -> some View {
        Button {
            lightboxTask = TaskLightboxView.issueStub(issue)
        } label: {
            HStack(spacing: 8) {
                Text(issue.repository.split(separator: "/").last.map(String.init) ?? issue.repository)
                    .appFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
                Text(issue.title)
                    .appFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text("#\(issue.number)")
                    .appFont(.caption2, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(issue.repository) #\(issue.number) — \(issue.title)")
        .contextMenu {
            Button("Open in Projects") {
                appState.navigateToGitHubIssueUrl = issue.webUrl
                appState.navigateToTab = .projects
            }
            Button("Open in GitHub") {
                if let url = URL(string: issue.webUrl) { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: Card chrome

    @ViewBuilder
    private func taskCard<Content: View>(
        title: String,
        mark: BrandShape,
        count: Int,
        emptyText: String,
        errorText: String? = nil,
        isLoading: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    BrandIcon(mark: mark, size: 11)
                    Text(title).appFont(.subheadline, weight: .semibold)
                    Text("\(count)")
                        .appFont(.caption2).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                    // A spinner beside the title while the list loads, as
                    // the widget cards show.
                    if isLoading { ProgressView().controlSize(.mini).padding(.leading, 2) }
                    Spacer()
                }
                .padding(.vertical, 6)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.bottom, 4)
                }

                Divider()
                if count == 0 && errorText == nil {
                    Text(emptyText)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    content()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A pill in a fixed-width column — empty values keep the column's space
    /// so the grid stays aligned.
    @ViewBuilder
    private func pillColumn(_ text: String?, tint: Color, width: CGFloat) -> some View {
        Group {
            if let text, !text.isEmpty {
                statePill(text, tint: tint)
                    .lineLimit(1)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func statePill(_ state: String, tint: Color) -> some View {
        Text(state)
            .appFont(.caption2, weight: .medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

/// Reports the widest area-path text in the work-items list.
private struct PathColumnWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
