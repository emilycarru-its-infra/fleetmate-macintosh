import SwiftUI
import FleetMateCore

// Each tab's Widgets row. The cards are the ones the Dashboard used to carry,
// moved next to the list they summarise; a click filters that list in place.

// MARK: - Devices

struct DevicesWidgetsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var metrics: WidgetMetrics

    var body: some View {
        WidgetsSection(tab: .devices) {
            WidgetKPIColumn(kpis: [
                KPI(title: "Managed Devices", value: "\(metrics.deviceCount)", icon: "laptopcomputer",
                    color: .blue, loading: metrics.isLoading(.devices) && metrics.deviceCount == 0, tab: .devices),
                KPI(title: "Non-Compliant", value: "\(metrics.nonCompliantCount)", icon: "exclamationmark.triangle",
                    color: .orange, loading: metrics.isLoading(.devices) && metrics.deviceCount == 0, tab: .devices),
            ]) { kpi in
                if kpi.title == "Non-Compliant" {
                    appState.openWidgetFilter(tab: .devices, category: "Compliance", label: "Non-Compliant")
                }
            }

            WidgetCard(title: "Platform Distribution", isLoading: metrics.isLoading(.devices)) {
                if metrics.osSlices.isEmpty {
                    if metrics.isLoading(.devices) { SkeletonChartCard() } else { WidgetEmptyState("No device data") }
                } else {
                    TreemapChart(slices: metrics.osSlices, height: 120) { label in
                        appState.openWidgetFilter(tab: .devices, category: "Platform", label: label)
                    }
                }
            }

            WidgetCard(title: "Compliance", isLoading: metrics.isLoading(.devices)) {
                if metrics.complianceSlices.isEmpty {
                    if metrics.isLoading(.devices) { SkeletonChartCard() } else { WidgetEmptyState("No device data") }
                } else {
                    DonutWidget(slices: metrics.complianceSlices, size: 130) { label in
                        appState.openWidgetFilter(tab: .devices, category: "Compliance", label: label)
                    }
                }
            }

            if appState.config.reportMateUrl != nil {
                WidgetCard(title: "Errors by Category", isLoading: metrics.isLoading(.reportMate)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            WidgetMiniStat(label: "Managed", value: "\(metrics.rmDeviceCount)", color: .blue)
                            WidgetMiniStat(label: "Errors", value: "\(metrics.rmErrorCount)",
                                           color: metrics.rmErrorCount > 0 ? .orange : .green)
                        }
                        if metrics.errorCategoryBars.isEmpty {
                            if metrics.isLoading(.reportMate) { SkeletonChartCard() } else { WidgetEmptyState("No errors found") }
                        } else {
                            HorizontalBarList(bars: metrics.errorCategoryBars)
                        }
                    }
                }
            }
        }
        .task {
            await metrics.load(.devices, appState: appState)
            await metrics.load(.reportMate, appState: appState)
        }
        .onChange(of: appState.cachedDevices.count) { _, _ in
            Task { await metrics.load(.devices, appState: appState, force: true) }
        }
    }
}

// MARK: - Inventory

struct InventoryWidgetsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var metrics: WidgetMetrics

    var body: some View {
        WidgetsSection(tab: .inventory) {
            let loading = metrics.isLoading(.inventory) && metrics.assetCount == 0
            WidgetKPIColumn(kpis: [
                KPI(title: "Assets", value: "\(metrics.assetCount)", icon: "shippingbox",
                    color: .orange, loading: loading, tab: .inventory),
                KPI(title: "Deployed", value: "\(metrics.deployedCount)", icon: "checkmark.circle",
                    color: .green, loading: loading, tab: .inventory),
                KPI(title: "Unassigned", value: "\(metrics.unassignedCount)", icon: "person.crop.circle.badge.questionmark",
                    color: .blue, loading: loading, tab: .inventory),
            ]) { _ in }

            WidgetCard(title: "Assets by Category", isLoading: metrics.isLoading(.inventory)) {
                if metrics.assetCategoryBars.isEmpty {
                    if metrics.isLoading(.inventory) { SkeletonChartCard() } else { WidgetEmptyState("No asset data") }
                } else {
                    HorizontalBarList(bars: metrics.assetCategoryBars) { label in
                        appState.openWidgetFilter(tab: .inventory, category: "Category", label: label)
                    }
                }
            }

            WidgetCard(title: "Asset Status", isLoading: metrics.isLoading(.inventory)) {
                if metrics.assetStatusSlices.isEmpty {
                    if metrics.isLoading(.inventory) { SkeletonChartCard() } else { WidgetEmptyState("No asset data") }
                } else {
                    DonutWidget(slices: metrics.assetStatusSlices, size: 130) { label in
                        appState.openWidgetFilter(tab: .inventory, category: "Status", label: label)
                    }
                }
            }
        }
        .task { await metrics.load(.inventory, appState: appState) }
        .onChange(of: appState.cachedAssets.count) { _, _ in
            Task { await metrics.load(.inventory, appState: appState, force: true) }
        }
        .onChange(of: appState.snipeSsoAuthenticated) { _, ready in
            if ready { Task { await metrics.load(.inventory, appState: appState, force: true) } }
        }
    }
}

// MARK: - Tickets

struct TicketsWidgetsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var metrics: WidgetMetrics

    var body: some View {
        WidgetsSection(tab: .tickets) {
            let loading = metrics.isLoading(.tickets) && metrics.openTicketCount == 0
            WidgetKPIColumn(kpis: [
                KPI(title: "Open Tickets", value: "\(metrics.openTicketCount)", icon: "ticket",
                    color: .purple, loading: loading, tab: .tickets),
                KPI(title: "SLA Violated", value: "\(metrics.slaViolatedCount)", icon: "clock.badge.exclamationmark",
                    color: .orange, loading: loading, tab: .tickets),
            ]) { _ in }

            WidgetCard(title: "Ticket Status", isLoading: metrics.isLoading(.tickets)) {
                if metrics.ticketStatusSlices.isEmpty {
                    if metrics.isLoading(.tickets) { SkeletonChartCard() } else { WidgetEmptyState("No ticket data") }
                } else {
                    DonutWidget(slices: metrics.ticketStatusSlices, size: 130) { label in
                        appState.openWidgetFilter(tab: .tickets, category: "Status", label: label)
                    }
                }
            }

            WidgetCard(title: "Tickets by Priority", isLoading: metrics.isLoading(.tickets)) {
                if metrics.ticketPriorityBars.isEmpty {
                    if metrics.isLoading(.tickets) { SkeletonChartCard() } else { WidgetEmptyState("No ticket data") }
                } else {
                    HorizontalBarList(bars: metrics.ticketPriorityBars) { label in
                        appState.openWidgetFilter(tab: .tickets, category: "Priority", label: label)
                    }
                }
            }
        }
        .task { await metrics.load(.tickets, appState: appState) }
        .onChange(of: appState.cachedTickets.count) { _, _ in
            Task { await metrics.load(.tickets, appState: appState, force: true) }
        }
    }
}

// MARK: - Projects

/// The signed-in user's work items and GitHub issues — the lists that headed
/// the Dashboard — beside the work-item count and state breakdown.
struct ProjectsWidgetsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var metrics: WidgetMetrics

    var body: some View {
        WidgetsSection(tab: .projects) {
            WidgetKPIColumn(kpis: [
                KPI(title: "Active Work Items", value: "\(metrics.activeWorkItems)", icon: "list.bullet.rectangle",
                    color: .indigo, loading: metrics.isLoading(.workItems) && metrics.activeWorkItems == 0, tab: .projects),
            ]) { _ in }

            WidgetCard(title: "Work Items", isLoading: metrics.isLoading(.workItems)) {
                if metrics.workItemSlices.isEmpty {
                    if metrics.isLoading(.workItems) { SkeletonChartCard() } else { WidgetEmptyState("No work item data") }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        DonutWidget(slices: metrics.workItemSlices, size: 130)
                        if !metrics.sprintInfo.isEmpty {
                            Text(metrics.sprintInfo).appFont(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // The user's work items and GitHub issues, five rows each; the
            // full lists open in a sheet.
            ForEach([PullRequestSource.azureDevOps, .gitHub], id: \.self) { source in
                TasksWidget(source: source, model: appState.dashboardTasks)
                    .widgetSpan(2)
            }
        }
        .task { await metrics.load(.workItems, appState: appState) }
        .onChange(of: appState.cachedMyWorkItems.count) { _, _ in
            Task { await metrics.load(.workItems, appState: appState, force: true) }
        }
        .onChange(of: appState.devOpsSsoAuthenticated) { _, ready in
            if ready { Task { await metrics.load(.workItems, appState: appState, force: true) } }
        }
    }
}

// MARK: - Development

/// Counts from what the Development tab has already loaded — no requests of
/// its own, so the widgets cost nothing against the GitHub budget. Each card
/// jumps to the segment and filter it counts.
struct DevelopmentWidgetsSection: View {
    @ObservedObject var model: DevelopmentModel

    private func count(_ relation: PullRequestRelation) -> Int {
        model.queue.section(relation).count
    }

    private var repoBars: [ChartBar] {
        var counts: [String: Int] = [:]
        for pr in model.queue.pullRequests { counts[pr.repository, default: 0] += 1 }
        let colors: [Color] = [.blue, .purple, .orange, .teal, .green, .indigo, .brown, .pink]
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8)
            .enumerated()
            .map { i, entry in ChartBar(label: entry.key, value: entry.value, color: colors[i % colors.count]) }
    }

    var body: some View {
        WidgetsSection(tab: .development) {
            let prLoading = model.isLoadingPullRequests && model.queue.isEmpty
            WidgetKPIColumn(kpis: [
                KPI(title: "Unread in Inbox", value: "\(model.unreadCount)", icon: "tray",
                    color: .blue, loading: model.isLoadingInbox && model.notifications.isEmpty, tab: .development),
                KPI(title: "Review Requested",
                    value: model.queue.failed() ? "--" : "\(count(.assignedToMe))", icon: "person.crop.circle.badge.checkmark",
                    color: .purple, loading: prLoading, tab: .development),
            ]) { kpi in
                if kpi.title == "Unread in Inbox" {
                    model.segment = .inbox
                } else {
                    model.selectedSource = nil
                    model.segment = .pullRequests
                }
            }

            WidgetKPIColumn(kpis: PullRequestSource.allCases.map { source in
                KPI(title: "\(source.shortName) Pull Requests",
                    value: model.queue.failed(source) ? "--" : "\(model.count(for: source))",
                    icon: source.symbolName, color: source == .gitHub ? .indigo : .blue,
                    loading: prLoading, tab: .development)
            }) { kpi in
                model.selectedSource = PullRequestSource.allCases.first { kpi.title.hasPrefix($0.shortName) }
                model.segment = .pullRequests
            }

            WidgetKPIColumn(kpis: [
                KPI(title: "Failing Pipelines", value: "\(model.pipelineCount(for: .failed))", icon: "xmark.octagon",
                    color: .orange, loading: model.isLoadingPipelines && model.pipelineRuns.isEmpty, tab: .development),
                KPI(title: "Running Pipelines", value: "\(model.pipelineCount(for: .running))", icon: "play.circle",
                    color: .teal, loading: model.isLoadingPipelines && model.pipelineRuns.isEmpty, tab: .development),
            ]) { kpi in
                model.pipelineStatusFilter = kpi.title.hasPrefix("Failing") ? .failed : .running
                model.segment = .pipelines
            }

            WidgetCard(title: "Pull Requests by Repository", isLoading: model.isLoadingPullRequests) {
                let bars = repoBars
                if bars.isEmpty {
                    if model.isLoadingPullRequests { SkeletonChartCard() } else { WidgetEmptyState("No open pull requests") }
                } else {
                    HorizontalBarList(bars: bars) { label in
                        model.selectedSource = nil
                        model.selectedRepo = label
                        model.segment = .pullRequests
                    }
                }
            }
        }
    }
}

/// One of the Projects strip's task lists: the first rows in place, the
/// whole list one click away.
struct TasksWidget: View {
    @EnvironmentObject var appState: AppState
    let source: PullRequestSource
    @ObservedObject var model: DashboardTasksModel
    @State private var showAll = false

    private static let rows = 5

    private var total: Int {
        source == .azureDevOps ? appState.cachedMyWorkItems.count : model.issues.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DashboardTasksPane(model: model, source: source, repoFilter: nil, compactRows: Self.rows)
                .fixedSize(horizontal: false, vertical: true)
            if total > Self.rows {
                Button("Show all \(total)") { showAll = true }
                    .buttonStyle(.link)
                    .appFont(.caption)
                    .padding(.leading, 4)
            }
        }
        .sheet(isPresented: $showAll) {
            VStack(alignment: .trailing, spacing: 8) {
                DashboardTasksPane(model: model, source: source, repoFilter: nil)
                Button("Done") { showAll = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .frame(minWidth: 820, minHeight: 560)
            .environmentObject(appState)
        }
    }
}

struct WidgetMiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).appFont(.title3, weight: .bold).monospacedDigit().foregroundStyle(color)
            Text(label).appFont(.caption2).foregroundStyle(.secondary)
        }
    }
}
