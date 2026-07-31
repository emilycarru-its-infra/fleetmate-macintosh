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

    private var activeWorkItems: [WorkItem] {
        let closed: Set<String> = ["done", "closed", "removed", "completed", "resolved"]
        return appState.cachedWorkItems
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
    }

    // MARK: DevOps work items

    private var workItemsCard: some View {
        taskCard(
            title: "Work items",
            mark: PullRequestSource.azureDevOps.brandMark,
            count: activeWorkItems.count,
            emptyText: "No active work items"
        ) {
            ForEach(Array(activeWorkItems.prefix(rowLimit).enumerated()), id: \.element.id) { index, item in
                workItemRow(item)
                if index < min(activeWorkItems.count, rowLimit) - 1 { Divider() }
            }
            if activeWorkItems.count > rowLimit {
                Divider()
                Button {
                    appState.navigateToTab = .projects
                } label: {
                    Text("Show all \(activeWorkItems.count) in Projects")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func workItemRow(_ item: WorkItem) -> some View {
        Button {
            // In-app: hand off to the Projects tab, which opens the sidebar.
            appState.navigateToWorkItemId = item.id
            appState.navigateToTab = .projects
        } label: {
            HStack(spacing: 8) {
                Text("#\(item.id)")
                    .appFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                Text(item.fields?.title ?? "(untitled)")
                    .appFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                statePill(item.fields?.state ?? "", tint: .indigo)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.fields?.title ?? "")
        .contextMenu {
            Button("Open in Azure DevOps") {
                if let url = workItemWebUrl(item) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func workItemWebUrl(_ item: WorkItem) -> URL? {
        guard let org = appState.config.devopsOrganization,
              let project = item.fields?.teamProject?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://dev.azure.com/\(org)/\(project)/_workitems/edit/\(item.id)")
    }

    // MARK: GitHub issues

    private var issuesCard: some View {
        taskCard(
            title: "GitHub issues",
            mark: PullRequestSource.gitHub.brandMark,
            count: visibleIssues.count,
            emptyText: model.isLoadingIssues ? "Loading…" : "No open issues",
            errorText: model.issuesError
        ) {
            ForEach(Array(visibleIssues.prefix(rowLimit).enumerated()), id: \.element.id) { index, issue in
                issueRow(issue)
                if index < min(visibleIssues.count, rowLimit) - 1 { Divider() }
            }
        }
    }

    private func issueRow(_ issue: GitHubIssueSummary) -> some View {
        Button {
            if let url = URL(string: issue.webUrl) { NSWorkspace.shared.open(url) }
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
    }

    // MARK: Card chrome

    @ViewBuilder
    private func taskCard<Content: View>(
        title: String,
        mark: BrandShape,
        count: Int,
        emptyText: String,
        errorText: String? = nil,
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
