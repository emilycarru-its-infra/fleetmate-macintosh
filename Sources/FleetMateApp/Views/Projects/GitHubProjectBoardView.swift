import SwiftUI
import AppKit
import FleetMateCore

/// The Board segment's GitHub source: the configured GitHub Projects v2 project
/// as a board, one column per Status option. Selecting a card opens the same
/// detail sidebar as the Azure DevOps board.
///
/// Items load once — on first open and on Refresh — and live on
/// `AppState.projects`, so switching modes or tabs costs nothing. The project id
/// and Status field come from the project context `BoardsView` already loads.
struct GitHubProjectBoardView: View {
    @EnvironmentObject var appState: AppState
    let searchText: String
    /// True while BoardsView is still resolving which project to show.
    let isResolvingProject: Bool
    @Binding var selectedTask: UnifiedTask?

    @State private var isLoading = false

    /// Upper bound on items read per load. Each 100 is one GraphQL page.
    static let itemLimit = 500

    private var columns: [GitHubProjectBoardColumn] {
        GitHubProjectBoard.columns(
            items: appState.projects.githubBoardItems,
            statusField: appState.projects.projectStatusField,
            search: searchText
        )
    }

    var body: some View {
        Group {
            if appState.projects.currentProjectId == nil {
                if isResolvingProject {
                    loading("Finding project…")
                } else {
                    VStack {
                        ContentUnavailableView(
                            "No GitHub Project",
                            systemImage: "square.grid.3x2",
                            description: Text("Set a GitHub project number and scope in Settings, or create a project from New.")
                        )
                        Spacer()
                    }
                }
            } else if isLoading && appState.projects.githubBoardLoadedAt == nil {
                loading("Loading project…")
            } else if let error = appState.projects.githubBoardError, appState.projects.githubBoardItems.isEmpty {
                VStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .appFont(.callout)
                        .foregroundColor(.orange)
                        .padding(.top, 60)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                board
            }
        }
        .task(id: "\(appState.projects.currentProjectId ?? "")#\(appState.projects.githubBoardRefreshRequested)") {
            let cache = appState.projects
            if cache.githubBoardLoadedAt == nil || cache.githubBoardRefreshLoaded != cache.githubBoardRefreshRequested {
                await load()
            }
        }
    }

    private func loading(_ text: String) -> some View {
        VStack {
            ProgressView(text).padding(.top, 60)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Board

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    columnView(column)
                }
            }
            .padding(16)
        }
    }

    private func columnView(_ column: GitHubProjectBoardColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.color(for: column.color))
                    .frame(width: 9, height: 9)
                Text(column.name)
                    .appFont(.headline)
                Text("\(column.items.count)")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(column.items) { item in
                        card(item)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func card(_ item: GitHubProjectItem) -> some View {
        let task = GitHubProjectsTaskProvider.unifiedTask(from: item)
        let isSelected = task != nil && selectedTask?.compositeKey == task?.compositeKey
        return Button {
            selectedTask = task
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: Self.icon(for: item))
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    if let content = item.content {
                        Text("\(content.repository.map { "\($0) " } ?? "")#\(content.number)")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Draft")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(item.displayTitle)
                    .appFont(.body)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if let assignees = item.content?.assignees, !assignees.isEmpty {
                    Text(assignees.joined(separator: ", "))
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let labels = item.content?.labels, !labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(labels.prefix(3), id: \.self) { label in
                            Text(label)
                                .appFont(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(task == nil)
        .contextMenu {
            if let url = item.content?.url.flatMap(URL.init(string:)) {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let projectId = appState.projects.currentProjectId,
              let ghConfig = appState.projects.currentGhConfig, !isLoading else { return }
        let requested = appState.projects.githubBoardRefreshRequested
        isLoading = true
        defer { isLoading = false }
        do {
            let service = GitHubProjectsService(config: ghConfig)
            let items = try await service.listProjectItems(projectId: projectId, limit: Self.itemLimit)
            appState.projects.githubBoardItems = items
            appState.projects.githubBoardError = nil
        } catch {
            appState.projects.githubBoardError = "Could not load the project: \(error.localizedDescription)"
        }
        appState.projects.githubBoardLoadedAt = Date()
        appState.projects.githubBoardRefreshLoaded = requested
    }

    // MARK: - Styling

    private static func icon(for item: GitHubProjectItem) -> String {
        if item.isDraft { return "doc.text" }
        if item.content?.isPullRequest == true { return "arrow.triangle.pull" }
        return item.content?.state == "CLOSED" ? "checkmark.circle" : "circle.circle"
    }

    /// GitHub's single-select colour names. Red maps to orange, per the
    /// no-red-badges rule.
    static func color(for name: String?) -> Color {
        switch name?.uppercased() {
        case "BLUE": return .blue
        case "GREEN": return .green
        case "YELLOW": return .yellow
        case "ORANGE", "RED": return .orange
        case "PINK": return .pink
        case "PURPLE": return .purple
        default: return .secondary
        }
    }
}
