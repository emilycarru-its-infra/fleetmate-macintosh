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
    /// The tickets the list is showing, after its filters and search, so
    /// every figure here matches the rows below it.
    let tickets: [TdxTicket]
    var isLoading = false

    var body: some View {
        let stats = TicketStats(tickets: tickets)
        WidgetsSection(tab: .tickets) {
            TicketKPIGrid(stats: stats, loading: isLoading && tickets.isEmpty)
                .widgetSpan(2)

            WidgetCard(title: "By Status", isLoading: isLoading) {
                if stats.byStatus.isEmpty {
                    emptyState
                } else {
                    DonutWidget(slices: stats.byStatus.map {
                        ChartSlice(label: $0.label, value: $0.value, color: ticketStatusColor($0.label))
                    }, size: 110) { filter("Status", $0) }
                }
            }

            barCard("By Priority", stats.byPriority, category: "Priority") { ticketPriorityColor($0) }
            barCard("By Age", stats.byAge, category: nil) { ticketAgeColor($0) }
            barCard("By Responsible", stats.byResponsible, category: "Responsible") {
                $0 == TicketStats.unassigned ? .gray : .teal
            }
            barCard("By Group", stats.byGroup, category: "Group") {
                $0 == TicketStats.unassigned ? .gray : .indigo
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading { SkeletonChartCard() } else { WidgetEmptyState("No tickets match") }
    }

    private func barCard(_ title: String, _ counts: [TicketStats.Count], category: String?,
                         color: @escaping (String) -> Color) -> some View {
        WidgetCard(title: title, isLoading: isLoading) {
            if counts.isEmpty {
                emptyState
            } else {
                HorizontalBarList(
                    bars: counts.map { ChartBar(label: $0.label, value: $0.value, color: color($0.label)) },
                    onSelect: category.map { category in { label in filter(category, label) } }
                )
            }
        }
    }

    /// Narrows the list to the clicked value. Unassigned has no filter value,
    /// so it is not a link.
    private func filter(_ category: String, _ label: String) {
        guard label != TicketStats.unassigned else { return }
        appState.openWidgetFilter(tab: .tickets, category: category, label: label)
    }
}

/// Six small figures in a 3 × 2 grid, so they take one card's height instead
/// of a column of full-width tiles.
private struct TicketKPIGrid: View {
    let stats: TicketStats
    let loading: Bool

    var body: some View {
        let tiles: [(String, Int, String, Color)] = [
            ("Showing", stats.total, "list.bullet", .secondary),
            ("Open", stats.open, "ticket", .purple),
            ("On Hold", stats.onHold, "pause.circle", .yellow),
            ("Unassigned", stats.unassigned, "person.crop.circle.badge.questionmark", .teal),
            ("SLA Violated", stats.slaViolated, "clock.badge.exclamationmark", .orange),
            ("Over \(TicketStats.agingDays) days", stats.aging, "hourglass", .indigo),
        ]
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        let t = tiles[row * 3 + col]
                        tile(title: t.0, value: t.1, icon: t.2, color: t.3)
                    }
                }
            }
        }
    }

    private func tile(title: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .appFont(.body)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                if loading {
                    SkeletonView(width: 36, height: 18, cornerRadius: 4)
                } else {
                    Text(value, format: .number).appFont(.title3, weight: .bold).monospacedDigit()
                }
                Text(title).appFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }
}

/// Status colours shared by the board columns and the status donut. No red.
func ticketStatusColor(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("new") || n.contains("open") { return .blue }
    if n.contains("progress") { return .orange }
    if n.contains("hold") || n.contains("pending") || n.contains("waiting") { return .yellow }
    if n.contains("resolved") || n.contains("completed") { return .green }
    if n.contains("closed") { return .gray }
    if n.contains("cancel") { return .orange }
    return .secondary
}

/// Keyed by name so a missing priority never shifts the others' colours. No
/// red: High is orange.
func ticketPriorityColor(_ name: String) -> Color {
    ["Low": .green, "Medium": .blue, "High": .orange, "Emergency": .purple][name] ?? .gray
}

func ticketAgeColor(_ bucket: String) -> Color {
    ["Today": .green, "1–7 days": .blue, "8–30 days": .orange, "Over 30 days": .purple][bucket] ?? .gray
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
                if kpi.title == "Unread in Inbox", model.unreadCount > 0 {
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
