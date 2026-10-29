import SwiftUI
import FleetMateCore

// Each tab's Widgets row. The cards are the ones the Dashboard used to carry,
// moved next to the list they summarise; a click filters that list in place.

// MARK: - Devices

struct DevicesWidgetsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var metrics: WidgetMetrics

    var body: some View {
        // One band: the cards share the row's height and the three tiles
        // split the column, so nothing ends short of its neighbours.
        WidgetsSection(tab: .devices, equalHeights: true) {
            let waiting = metrics.isLoading(.devices) && metrics.deviceCount == 0
            WidgetKPIColumn(kpis: [
                KPI(title: "Managed Devices", value: "\(metrics.deviceCount)", icon: "laptopcomputer",
                    color: .blue, loading: waiting, tab: .devices),
                KPI(title: "Non-Compliant", value: "\(metrics.nonCompliantCount)", icon: "exclamationmark.triangle",
                    color: .orange, loading: waiting, tab: .devices),
                KPI(title: "Not Synced in 30 Days", value: "\(metrics.staleCount)", icon: "clock.arrow.circlepath",
                    color: .secondary, loading: waiting, tab: .devices),
            ], fillsHeight: true) { kpi in
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
                    if !metrics.errorCategoryBars.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                WidgetMiniStat(label: "Managed", value: "\(metrics.rmDeviceCount)", color: .blue)
                                WidgetMiniStat(label: "Errors", value: "\(metrics.rmErrorCount)", color: .orange)
                            }
                            HorizontalBarList(bars: metrics.errorCategoryBars)
                        }
                    } else if metrics.isLoading(.reportMate) {
                        SkeletonChartCard()
                    } else {
                        WidgetAllClear(title: "No errors reported",
                                       detail: "\(metrics.rmDeviceCount) devices reporting")
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
                    if metrics.isLoading(.inventory) { SkeletonChartCard() } else { WidgetEmptyState(AssetsLoadFailure.headline(appState.assetsLoadError)) }
                } else {
                    HorizontalBarList(bars: metrics.assetCategoryBars) { label in
                        appState.openWidgetFilter(tab: .inventory, category: "Category", label: label)
                    }
                }
            }

            WidgetCard(title: "Asset Status", isLoading: metrics.isLoading(.inventory)) {
                if metrics.assetStatusSlices.isEmpty {
                    if metrics.isLoading(.inventory) { SkeletonChartCard() } else { WidgetEmptyState(AssetsLoadFailure.headline(appState.assetsLoadError)) }
                } else {
                    DonutWidget(slices: metrics.assetStatusSlices, size: 130) { label in
                        appState.openWidgetFilter(tab: .inventory, category: "Status Type", label: label)
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
    /// The tickets the list would show with every filter applied except the
    /// given category's (nil: every filter). Each breakdown counts with its
    /// own category left out, so its other values stay on screen and can be
    /// added to the selection — clicking widgets mixes and matches filters.
    let tickets: (TicketFilterCategory?) -> [TdxTicket]
    /// The list's own filters: every widget reads and changes them, so the
    /// filter panel, the list and the widgets always agree.
    let filters: FilterState<TicketFilterCategory>
    var isLoading = false

    private var selected: [TicketFilterCategory: Set<String>] { filters.selectedValues }

    var body: some View {
        let shown = tickets(nil)
        let stats = TicketStats(tickets: shown)
        WidgetsSection(tab: .tickets, equalHeights: true, singleRow: true) {
            WidgetKPIGrid(loading: isLoading && shown.isEmpty, tiles: kpiTiles(openStatuses: openStatuses))

            let byStatus = TicketStats(tickets: tickets(.status)).byStatus
            WidgetCard(title: "By Status", isLoading: isLoading) {
                if byStatus.isEmpty {
                    emptyState
                } else {
                    DonutWidget(slices: byStatus.map {
                        ChartSlice(label: $0.label, value: $0.value,
                                   color: shade(ticketStatusColor($0.label), $0.label, in: .status))
                    }, size: 110, adaptsToWidth: true) { toggle(.status, $0) }
                }
            }

            barCard("By Priority", TicketStats(tickets: tickets(.priority)).byPriority, category: .priority) {
                ticketPriorityColor($0)
            }
            barCard("By Age", TicketStats(tickets: tickets(.age)).byAge, category: .age) { ticketAgeColor($0) }
            barCard("By Responsible", TicketStats(tickets: tickets(.responsible)).byResponsible, category: .responsible) {
                $0 == TicketStats.unassigned ? .gray : .teal
            }
            barCard("By Group", TicketStats(tickets: tickets(.group)).byGroup, category: .group) {
                $0 == TicketStats.unassigned ? .gray : .indigo
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading { SkeletonChartCard() } else { WidgetEmptyState("No tickets match") }
    }

    /// Values outside an active selection fade, so the chart shows what is
    /// picked and what else could be.
    private func shade(_ color: Color, _ label: String, in category: TicketFilterCategory?) -> Color {
        guard let category, let picked = selected[category], !picked.isEmpty else { return color }
        return picked.contains(label) ? color : color.opacity(0.3)
    }

    private func barCard(_ title: String, _ counts: [TicketStats.Count], category: TicketFilterCategory?,
                         color: @escaping (String) -> Color) -> some View {
        WidgetCard(title: title, isLoading: isLoading) {
            if counts.isEmpty {
                emptyState
            } else {
                HorizontalBarList(
                    bars: counts.map {
                        ChartBar(label: $0.label, value: $0.value, color: shade(color($0.label), $0.label, in: category))
                    },
                    compact: true,
                    onSelect: category.map { category in { label in toggle(category, label) } }
                )
            }
        }
    }

    private func toggle(_ category: TicketFilterCategory, _ label: String) {
        filters.toggle(value: label, in: category)
    }

    /// Statuses that count as open (everything shown but On Hold), for the
    /// Open tile.
    private var openStatuses: Set<String> {
        Set(TicketStats(tickets: tickets(.status)).byStatus.map(\.label)).subtracting([Self.onHold])
    }

    private static let onHold = "On Hold"

    /// The figures double as filters: each tile toggles the selection it
    /// counts, and lights up while that selection is on.
    private func kpiTiles(openStatuses: Set<String>) -> [TicketKPITile] {
        func single(_ category: TicketFilterCategory, _ value: String) -> (Bool, () -> Void) {
            (selected[category]?.contains(value) ?? false, { toggle(category, value) })
        }
        let openOn = !openStatuses.isEmpty && selected[.status] == openStatuses
        let onHold = single(.status, Self.onHold)
        let unassigned = single(.responsible, TicketStats.unassigned)
        let sla = single(.sla, "Violated")
        let aging = single(.age, TicketStats.ageBuckets.last!.label)
        return [
            TicketKPITile(title: "Showing", value: TicketStats(tickets: tickets(nil)).total, icon: "list.bullet",
                          color: .secondary, isOn: false, help: "Clear every filter") { filters.clearAll() },
            TicketKPITile(title: "Open", value: TicketStats(tickets: tickets(nil)).open, icon: "ticket",
                          color: .purple, isOn: openOn, help: "Show open tickets") {
                filters.selectedValues[.status] = openOn ? [] : openStatuses
            },
            TicketKPITile(title: "On Hold", value: TicketStats(tickets: tickets(nil)).onHold, icon: "pause.circle",
                          color: .yellow, isOn: onHold.0, help: "Show tickets on hold", action: onHold.1),
            TicketKPITile(title: "Unassigned", value: TicketStats(tickets: tickets(nil)).unassigned,
                          icon: "person.crop.circle.badge.questionmark", color: .teal, isOn: unassigned.0,
                          help: "Show tickets nobody is responsible for", action: unassigned.1),
            TicketKPITile(title: "SLA Violated", value: TicketStats(tickets: tickets(nil)).slaViolated,
                          icon: "clock.badge.exclamationmark", color: .orange, isOn: sla.0,
                          help: "Show tickets past their SLA", action: sla.1),
            TicketKPITile(title: "Over \(TicketStats.agingDays) days", value: TicketStats(tickets: tickets(nil)).aging,
                          icon: "hourglass", color: .indigo, isOn: aging.0,
                          help: "Show tickets older than \(TicketStats.agingDays) days", action: aging.1),
        ]
    }
}

struct TicketKPITile {
    let title: String
    let value: Int
    let icon: String
    let color: Color
    let isOn: Bool
    let help: String
    let action: () -> Void
}

/// Figures as a grid of buttons in one cell of the strip. At narrower widths
/// the tiles take fewer columns and more rows; the grid always fills the
/// height the row offers, so it ends level with the cards beside it. Text
/// never shrinks below the caption size.
struct WidgetKPIGrid: View {
    let loading: Bool
    let tiles: [TicketKPITile]
    /// The most columns to try, widest first.
    var maxColumns = 3

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: maxColumns, through: 2, by: -1)), id: \.self) { columns in
                grid(columns: columns).frame(minWidth: CGFloat(columns) * 110)
            }
            grid(columns: 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func grid(columns: Int) -> some View {
        let rows = Int((Double(tiles.count) / Double(columns)).rounded(.up))
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        let index = row * columns + col
                        if index < tiles.count {
                            tile(tiles[index])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    private func tile(_ t: TicketKPITile) -> some View {
        Button(action: t.action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: t.icon).appFont(.caption).foregroundStyle(t.color)
                    if loading {
                        SkeletonView(width: 30, height: 16, cornerRadius: 4)
                    } else {
                        Text(t.value, format: .number).appFont(.title3, weight: .bold)
                            .monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(t.title).appFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(t.isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(t.isOn ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: t.isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.help)
        .accessibilityLabel("\(t.title): \(t.value)")
        .accessibilityAddTraits(t.isOn ? .isSelected : [])
        .accessibilityHint(t.help)
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
/// the Dashboard — beside tiles and breakdowns of the same items. Every
/// figure comes from what the tab has already loaded.
struct ProjectsWidgetsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var metrics: WidgetMetrics
    @ObservedObject var tasks: DashboardTasksModel
    /// The tile filtering the Projects list, if any.
    @Binding var selection: WorkItemTile?

    var body: some View {
        let items = appState.cachedMyWorkItems
        let stats = WorkItemStats(items)
        let loading = metrics.isLoading(.workItems) && items.isEmpty
        WidgetsSection(tab: .projects) {
            WidgetKPIGrid(loading: loading, tiles: tiles(stats), maxColumns: 4)
                .widgetSpan(2)

            WidgetCard(title: "By State", isLoading: metrics.isLoading(.workItems)) {
                if metrics.workItemSlices.isEmpty {
                    if metrics.isLoading(.workItems) { SkeletonChartCard() } else { WidgetEmptyState("No work item data") }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        DonutWidget(slices: metrics.workItemSlices, size: 110, adaptsToWidth: true)
                        if !metrics.sprintInfo.isEmpty {
                            Text(metrics.sprintInfo).appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            barCard("By Type", WorkItemStats.ranked(items) { $0.workItemType }, color: .indigo, loading: loading)
            barCard("By Project", WorkItemStats.ranked(items) { $0.teamProject }, color: .teal, loading: loading)

            // The user's work items and GitHub issues, five rows each; the
            // full lists open in a sheet.
            ForEach([PullRequestSource.azureDevOps, .gitHub], id: \.self) { source in
                TasksWidget(source: source, model: tasks)
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

    private func barCard(_ title: String, _ counts: [DevelopmentStats.Count], color: Color, loading: Bool) -> some View {
        WidgetCard(title: title, isLoading: metrics.isLoading(.workItems)) {
            if counts.isEmpty {
                if loading { SkeletonChartCard() } else { WidgetEmptyState("No work item data") }
            } else {
                HorizontalBarList(bars: counts.prefix(8).map { ChartBar(label: $0.label, value: $0.value, color: color) })
            }
        }
    }

    /// Each tile filters the Projects list to the items it counts; clicking
    /// the lit tile again, or Clear Filters, shows everything again.
    private func tiles(_ stats: WorkItemStats) -> [TicketKPITile] {
        func tile(_ kind: WorkItemTile, _ value: Int, _ icon: String, _ color: Color, _ help: String) -> TicketKPITile {
            let isOn = selection == kind
            return TicketKPITile(title: kind.title, value: value, icon: icon, color: color, isOn: isOn,
                                 help: isOn ? "Show every item again" : help) {
                selection = isOn ? nil : kind
            }
        }
        return [
            tile(.assignedToMe, stats.open, "list.bullet.rectangle", .indigo, "Show your open work items"),
            tile(.inProgress, stats.inProgress, "play.circle", .blue, "Show items open and past New"),
            tile(.newThisWeek, stats.newThisWeek, "sparkles", .green, "Show items created in the last 7 days"),
            tile(.updatedThisWeek, stats.updatedThisWeek, "clock.arrow.circlepath", .teal,
                 "Show items changed in the last 7 days"),
            tile(.blocked, stats.blocked, "hand.raised", .orange, "Show items tagged Blocked, or on a Blocked column or state"),
            tile(.overdue, stats.overdue, "calendar.badge.exclamationmark", .purple, "Show items past their due date"),
            tile(.stale, stats.stale, "hourglass", .gray, "Show items not changed in \(WorkItemStats.staleDays) days"),
            tile(.gitHubIssues, tasks.issues.count, "exclamationmark.circle", .indigo, "Show the open GitHub issues in your list"),
        ]
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

/// A card with nothing to chart: one centred line in the card's own height,
/// rather than two zero figures over a lone "none" message.
struct WidgetAllClear: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .appFont(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(title).appFont(.callout, weight: .medium)
            Text(detail).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct WidgetMiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).appFont(.title3, weight: .bold).monospacedDigit().foregroundStyle(color)
            Text(label).appFont(.caption).foregroundStyle(.secondary)
        }
    }
}
