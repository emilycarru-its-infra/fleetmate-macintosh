import SwiftUI
import AppKit
import FleetMateCore

/// In-place viewer for a DevOps work item or a GitHub issue: the same detail
/// view the Projects tab shows in its sidebar, presented centred and large
/// the way the pull-request lightbox is, so a dashboard row can be read and
/// acted on without leaving the dashboard. The header's Projects button hands
/// the item to its home tab for anything that wants the full board around it.
struct TaskLightboxView: View {
    /// A stub is enough: `provider`, `id`/`externalUrl` and a title. The
    /// detail views load everything else themselves.
    let task: UnifiedTask

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Following a link inside a work item swaps what the lightbox shows.
    @State private var current: UnifiedTask

    init(task: UnifiedTask) {
        self.task = task
        _current = State(initialValue: task)
    }

    /// Same sizing rule as the pull-request lightbox: ~80% of the window,
    /// measured up front because a sheet cannot observe its host.
    private let sheetSize: CGSize = {
        let host = NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
            .max(by: { $0.frame.width < $1.frame.width })
        let size = host?.frame.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: max(860, size.width * 0.8), height: max(560, size.height * 0.8))
    }()

    var body: some View {
        Group {
            if current.provider == "github" {
                GitHubIssueSidebarView(
                    task: current,
                    config: appState.config.tasks?.providers.github,
                    onClose: { dismiss() },
                    onOpenInProjects: openInProjects,
                    layout: .wide
                )
            } else {
                AzDoTaskSidebarView(
                    task: current,
                    service: appState.devOpsService,
                    onClose: { dismiss() },
                    onSelectWorkItem: { id in
                        current = Self.workItemStub(id: id, config: appState.config, project: nil)
                    },
                    onOpenInProjects: openInProjects,
                    layout: .wide
                )
            }
        }
        .id(current.id)
        .frame(width: sheetSize.width, height: sheetSize.height)
        // Escape closes the lightbox, matching the pull-request lightbox and
        // the Windows app. The button carries the shortcut without taking
        // any space, since the header's own close control cannot: it is the
        // same view that lives in the Projects sidebar.
        .background {
            Button(action: { dismiss() }) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .onExitCommand { dismiss() }
    }

    private func openInProjects() {
        if current.provider == "github" {
            appState.navigateToGitHubIssueUrl = current.externalUrl
        } else if let id = Int(current.id) {
            appState.navigateToWorkItemId = id
        }
        appState.navigateToTab = .projects
        dismiss()
    }

    // MARK: Stubs

    /// A DevOps work item from the dashboard cache, with the web URL the
    /// sidebar's globe button needs.
    static func workItemStub(_ item: WorkItem, config: FleetMateConfig) -> UnifiedTask {
        var stub = workItemStub(id: item.id, config: config, project: item.fields?.teamProject)
        stub.title = item.fields?.title ?? "#\(item.id)"
        return stub
    }

    static func workItemStub(id: Int, config: FleetMateConfig, project: String?) -> UnifiedTask {
        var url: String?
        if let org = config.devopsOrganization,
           let projectPart = (project ?? config.devopsProject)?
               .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            url = "\(config.effectiveDevopsBaseUrl)/\(org)/\(projectPart)/_workitems/edit/\(id)"
        }
        return UnifiedTask(id: String(id), provider: "azdevops", title: "#\(id)", externalUrl: url)
    }

    static func issueStub(_ issue: GitHubIssueSummary) -> UnifiedTask {
        UnifiedTask(
            id: String(issue.number),
            provider: "github",
            title: issue.title,
            state: issue.state == "closed" ? .closed : .open,
            externalUrl: issue.webUrl
        )
    }
}
