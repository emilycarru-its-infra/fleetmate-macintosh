import SwiftUI
import Charts
import FleetMateCore

// MARK: - Data Models

struct ChartSlice: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let color: Color
}

struct ChartBar: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let color: Color
}

struct ActivityItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let time: String
    let timestamp: Date
    let tab: String
}

struct AlertPill: Hashable {
    let text: String
    let color: Color
    let tab: String
}

struct KPI: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let icon: String
    let color: Color
    let loading: Bool
    let tab: String
}

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selectedTab") private var settingsSelectedTab: Int = 0

    // Section data
    @State private var complianceSlices: [ChartSlice] = []
    @State private var osSlices: [ChartSlice] = []
    @State private var ticketStatusSlices: [ChartSlice] = []
    @State private var ticketPriorityBars: [ChartBar] = []
    @State private var workItemSlices: [ChartSlice] = []
    @State private var assetStatusSlices: [ChartSlice] = []
    @State private var assetCategoryBars: [ChartBar] = []
    @State private var errorCategoryBars: [ChartBar] = []
    @State private var activityItems: [ActivityItem] = []

    // Counts
    @State private var deviceCount = 0
    @State private var nonCompliantCount = 0
    @State private var staleCount = 0
    @State private var rmDeviceCount = 0
    @State private var rmErrorCount = 0
    @State private var assetCount = 0
    @State private var deployedCount = 0
    @State private var unassignedCount = 0
    @State private var openTicketCount = 0
    @State private var slaViolatedCount = 0
    @State private var activeWorkItems = 0
    @State private var sprintInfo = ""

    // Loading
    @State private var isLoadingFleet = false
    @State private var isLoadingReportMate = false
    @State private var isLoadingTickets = false
    @State private var isLoadingInventory = false

    private var isAnyLoading: Bool {
        isLoadingFleet || isLoadingReportMate || isLoadingTickets || isLoadingInventory
    }

    private var hasAnyService: Bool {
        appState.config.isGraphConfigured || appState.config.isSnipeConfigured ||
        appState.config.isTdxConfigured || appState.config.isDevOpsConfigured ||
        appState.config.reportMateUrl != nil
    }

    // Adaptive columns -- flow based on available width
    private let adaptiveColumns = [
        GridItem(.adaptive(minimum: 260, maximum: 480), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection

                if !hasAnyService {
                    connectServicesPrompt
                } else {
                    alertBanner
                    kpiStrip

                    // Top split: charts (left) + activity feed (right)
                    HStack(alignment: .top, spacing: 16) {
                        chartGrid
                            .frame(maxWidth: .infinity)
                        activityFeedSection
                            .frame(maxWidth: .infinity)
                    }
                }

                if let error = appState.errorMessage {
                    errorBanner(error)
                }
            }
            .padding(16)
        }
        .task { await loadAllSections() }
        .onChange(of: appState.cachedDevices.count) { _, _ in Task { await loadFleetHealth(); buildActivityFeed() } }
        .onChange(of: appState.cachedAssets.count) { _, _ in Task { await loadInventory(); buildActivityFeed() } }
        .onChange(of: appState.cachedTickets.count) { _, _ in Task { await loadTicketsWork(); buildActivityFeed() } }
        .onChange(of: appState.cachedWorkItems.count) { _, _ in Task { await loadTicketsWork(); buildActivityFeed() } }
    }

    private func navigate(to tab: String) {
        appState.navigateToTab = tab
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.largeTitle.bold())
                Text("Fleet overview across all connected systems")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isAnyLoading {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }
            Button(action: { Task { await refreshAll() } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isAnyLoading)
            Button(action: { settingsSelectedTab = 1; openSettings() }) {
                Label("Authentication", systemImage: "lock.shield")
            }
        }
    }

    // MARK: - Connect Prompt

    private var connectServicesPrompt: some View {
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("No services connected").font(.headline)
                Text("Configure your systems in Settings to see fleet data here.")
                    .foregroundStyle(.secondary)
                Button("Open Settings") { settingsSelectedTab = 0; openSettings() }
            }
            .frame(maxWidth: .infinity).padding()
        }
    }

    // MARK: - Alert Banner

    @ViewBuilder
    private var alertBanner: some View {
        let pills = buildAlerts()
        if !pills.isEmpty {
            DashboardFlowLayout(spacing: 6) {
                ForEach(pills, id: \.self) { pill in
                    Button(action: { navigate(to: pill.tab) }) {
                        Text(pill.text)
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(pill.color.opacity(0.12))
                            .foregroundStyle(pill.color)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func buildAlerts() -> [AlertPill] {
        var pills: [AlertPill] = []
        if nonCompliantCount > 0 { pills.append(.init(text: "\(nonCompliantCount) non-compliant", color: .red, tab: "Devices")) }
        if staleCount > 0 { pills.append(.init(text: "\(staleCount) stale (30d+)", color: .orange, tab: "Devices")) }
        if slaViolatedCount > 0 { pills.append(.init(text: "\(slaViolatedCount) SLA violations", color: .red, tab: "Tickets")) }
        if unassignedCount > 5 { pills.append(.init(text: "\(unassignedCount) unassigned assets", color: .blue, tab: "Inventory")) }
        return pills
    }

    // MARK: - KPI Strip

    @ViewBuilder
    private var kpiStrip: some View {
        let kpis = buildKPIs()
        if !kpis.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: min(kpis.count, 6)), spacing: 10) {
                ForEach(kpis) { kpi in
                    KPICard(kpi: kpi, onTap: { navigate(to: kpi.tab) })
                }
            }
        }
    }

    private func buildKPIs() -> [KPI] {
        var kpis: [KPI] = []
        if appState.config.isGraphConfigured {
            kpis.append(KPI(title: "Devices", value: "\(deviceCount)", icon: "laptopcomputer", color: .blue, loading: isLoadingFleet, tab: "Devices"))
            if nonCompliantCount > 0 {
                kpis.append(KPI(title: "Non-Compliant", value: "\(nonCompliantCount)", icon: "exclamationmark.triangle", color: .red, loading: false, tab: "Devices"))
            }
            if staleCount > 0 {
                kpis.append(KPI(title: "Stale (30d+)", value: "\(staleCount)", icon: "clock.badge.exclamationmark", color: .orange, loading: false, tab: "Devices"))
            }
        }
        if appState.config.isTdxConfigured {
            kpis.append(KPI(title: "Open Tickets", value: "\(openTicketCount)", icon: "ticket", color: .purple, loading: isLoadingTickets, tab: "Tickets"))
        }
        if appState.config.isDevOpsConfigured {
            kpis.append(KPI(title: "Active Work Items", value: "\(activeWorkItems)", icon: "list.bullet.rectangle", color: .indigo, loading: isLoadingTickets, tab: "Projects"))
        }
        if appState.config.isSnipeConfigured {
            kpis.append(KPI(title: "Assets", value: "\(assetCount)", icon: "shippingbox", color: .orange, loading: isLoadingInventory, tab: "Inventory"))
        }
        if appState.config.reportMateUrl != nil {
            kpis.append(KPI(title: "Managed Macs", value: "\(rmDeviceCount)", icon: "desktopcomputer", color: .teal, loading: isLoadingReportMate, tab: "Devices"))
        }
        return kpis
    }

    // MARK: - Chart Grid (flowing, Assets by Category first)

    private var chartGrid: some View {
        LazyVGrid(columns: adaptiveColumns, spacing: 12) {
            // Assets by Category first
            if appState.config.isSnipeConfigured {
                chartCard("Assets by Category", tab: "Inventory", isLoading: isLoadingInventory) {
                    if assetCategoryBars.isEmpty && !isLoadingInventory {
                        emptyState("No asset data")
                    } else {
                        barChart(assetCategoryBars, height: 160)
                    }
                }
            }

            if appState.config.isGraphConfigured {
                chartCard("Platform Distribution", tab: "Devices", isLoading: isLoadingFleet) {
                    if osSlices.isEmpty && !isLoadingFleet {
                        emptyState("No device data")
                    } else {
                        donutChart(osSlices, size: 160)
                    }
                }
            }

            if appState.config.isTdxConfigured {
                chartCard("Ticket Status", tab: "Tickets", isLoading: isLoadingTickets) {
                    if ticketStatusSlices.isEmpty && !isLoadingTickets {
                        emptyState("No ticket data")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            donutChart(ticketStatusSlices, size: 160)
                            if slaViolatedCount > 0 {
                                Text("\(slaViolatedCount) SLA violated")
                                    .font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }
                chartCard("Tickets by Priority", tab: "Tickets", isLoading: isLoadingTickets) {
                    if ticketPriorityBars.isEmpty && !isLoadingTickets {
                        emptyState("No ticket data")
                    } else {
                        barChart(ticketPriorityBars, height: 160)
                    }
                }
            }

            if appState.config.isDevOpsConfigured {
                chartCard("Work Items", tab: "Projects", isLoading: isLoadingTickets) {
                    if workItemSlices.isEmpty && !isLoadingTickets {
                        emptyState("No work item data")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            donutChart(workItemSlices, size: 160)
                            if !sprintInfo.isEmpty {
                                Text(sprintInfo).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if appState.config.reportMateUrl != nil {
                chartCard("Errors by Category", tab: "Devices", isLoading: isLoadingReportMate) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            miniStat("Managed", "\(rmDeviceCount)", color: .blue)
                            miniStat("Errors", "\(rmErrorCount)", color: rmErrorCount > 0 ? .red : .green)
                        }
                        if errorCategoryBars.isEmpty && !isLoadingReportMate {
                            emptyState("No errors found")
                        } else {
                            barChart(errorCategoryBars, height: 140)
                        }
                    }
                }
            }

            if appState.config.isGraphConfigured {
                chartCard("Compliance", tab: "Devices", isLoading: isLoadingFleet) {
                    if complianceSlices.isEmpty && !isLoadingFleet {
                        emptyState("No device data")
                    } else {
                        donutChart(complianceSlices, size: 160)
                    }
                }
            }

            if appState.config.isSnipeConfigured {
                chartCard("Asset Status", tab: "Inventory", isLoading: isLoadingInventory) {
                    if assetStatusSlices.isEmpty && !isLoadingInventory {
                        emptyState("No asset data")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            donutChart(assetStatusSlices, size: 160)
                            Text("\(deployedCount) deployed - \(unassignedCount) unassigned")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Activity Feed (right column)

    private var activityFeedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.headline)
            GroupBox {
                if activityItems.isEmpty {
                    Text("Activity will appear once data loads.")
                        .foregroundStyle(.secondary).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(activityItems) { item in
                            Button(action: { navigate(to: item.tab) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    Text(item.text)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(item.time)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if item.id != activityItems.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        GroupBox {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { appState.errorMessage = nil }.buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Chart Helpers

    private func chartCard<Content: View>(_ title: String, tab: String, isLoading: Bool, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(action: { navigate(to: tab) }) {
                        HStack(spacing: 4) {
                            Text(title).font(.subheadline.bold())
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if isLoading { ProgressView().controlSize(.mini).padding(.leading, 2) }
                }
                content()
            }
            .padding(2)
        }
    }

    private func donutChart(_ slices: [ChartSlice], size: CGFloat) -> some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Count", slice.value),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Category", slice.label))
            .annotation(position: .overlay) {
                if slice.value > 0 {
                    Text("\(slice.value)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                }
            }
        }
        .chartForegroundStyleScale(domain: slices.map(\.label), range: slices.map(\.color))
        .chartLegend(position: .trailing, alignment: .center, spacing: 8)
        .frame(height: size)
    }

    private func barChart(_ bars: [ChartBar], height: CGFloat) -> some View {
        Chart(bars) { bar in
            BarMark(x: .value("Label", bar.label), y: .value("Count", bar.value))
                .foregroundStyle(by: .value("Category", bar.label))
                .annotation(position: .top) {
                    if bar.value > 0 {
                        Text("\(bar.value)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
        }
        .chartForegroundStyleScale(domain: bars.map(\.label), range: bars.map(\.color))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.caption2) }
        }
        .frame(height: height)
    }

    private func emptyState(_ msg: String) -> some View {
        Text(msg)
            .font(.callout).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private func miniStat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Data Loading

    private func refreshAll() async {
        appState.invalidateAllCaches()
        await appState.preloadAllData()
        await loadAllSections()
    }

    private func loadAllSections() async {
        async let f: () = loadFleetHealth()
        async let r: () = loadReportMate()
        async let t: () = loadTicketsWork()
        async let i: () = loadInventory()
        _ = await (f, r, t, i)
        buildActivityFeed()
    }

    private func loadFleetHealth() async {
        guard appState.config.isGraphConfigured else { return }
        isLoadingFleet = true
        defer { isLoadingFleet = false }

        // Ensure cache is populated
        if appState.cachedDevices.isEmpty && !appState.isDevicesCacheValid {
            do {
                let devices = try await appState.graphService.getManagedDevices(limit: 10000)
                appState.updateDevicesCache(devices)
            } catch {
                dbg.error("Dashboard device fetch: \(error)", category: "dashboard")
                return
            }
        }

        let devices = appState.cachedDevices
        guard !devices.isEmpty else { return }

        deviceCount = devices.count
        nonCompliantCount = devices.filter { $0.complianceState?.lowercased() == "noncompliant" }.count

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        staleCount = devices.filter { d in
            guard let s = d.lastSyncDateTime, let dt = iso.date(from: s) else { return false }
            return now.timeIntervalSince(dt) > 30 * 86400
        }.count

        let compliant = deviceCount - nonCompliantCount
        complianceSlices = [
            ChartSlice(label: "Compliant", value: compliant, color: .green),
            ChartSlice(label: "Non-Compliant", value: nonCompliantCount, color: .red)
        ].filter { $0.value > 0 }

        let osCounts = Dictionary(grouping: devices, by: { $0.operatingSystem ?? "Unknown" })
            .map { (key: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(6)
        let colors: [Color] = [.blue, .purple, .orange, .teal, .brown, .gray]
        osSlices = osCounts.enumerated().map { i, os in
            ChartSlice(label: os.key, value: os.count, color: colors[i % colors.count])
        }
    }

    private func loadReportMate() async {
        guard appState.config.reportMateUrl != nil else { return }
        isLoadingReportMate = true
        defer { isLoadingReportMate = false }

        do {
            async let dr = appState.reportMateService.getDevices()
            async let er = appState.reportMateService.getErrorsByItem()
            let (rmDevs, rmErrs) = try await (dr, er)
            rmDeviceCount = rmDevs.count
            rmErrorCount = rmErrs.count
            let cats = Dictionary(grouping: rmErrs, by: { $0.category })
                .map { (cat: $0.key, count: $0.value.reduce(0) { $0 + $1.deviceCount }) }
                .sorted { $0.count > $1.count }
                .prefix(8)
            errorCategoryBars = cats.map { ChartBar(label: $0.cat.rawValue, value: $0.count, color: .red) }
        } catch {
            dbg.error("Dashboard ReportMate: \(error)", category: "dashboard")
        }
    }

    private func loadTicketsWork() async {
        isLoadingTickets = true
        defer { isLoadingTickets = false }

        // Tickets
        if appState.config.isTdxConfigured {
            if appState.cachedTickets.isEmpty && !appState.isTicketsCacheValid {
                do {
                    var search = TicketSearchRequest(maxResults: 500)
                    if let gid = appState.config.tdxResponsibleGroupId { search.responsibleGroupIds = [gid] }
                    let tickets = try await appState.tdxService.searchTickets(search: search, maxResults: 500)
                    appState.updateTicketsCache(tickets)
                } catch {
                    dbg.error("Dashboard ticket fetch: \(error)", category: "dashboard")
                }
            }

            let tickets = appState.cachedTickets
            if !tickets.isEmpty {
                let closed = Set(["closed", "cancelled", "canceled"])
                let open = tickets.filter { t in
                    guard let s = t.statusName?.lowercased() else { return true }
                    return !closed.contains(s) && t.isOnHold != true
                }.count
                let onHold = tickets.filter { $0.isOnHold == true }.count
                let closedN = tickets.count - open - onHold

                openTicketCount = open
                ticketStatusSlices = [
                    ChartSlice(label: "Open (\(open))", value: open, color: .blue),
                    ChartSlice(label: "On Hold (\(onHold))", value: onHold, color: .orange)
                ].filter { $0.value > 0 }

                slaViolatedCount = tickets.filter { $0.slaViolated == true }.count

                let priorityOrder = ["Low": 0, "Medium": 1, "High": 2]
                let prios = Dictionary(grouping: tickets.filter { t in
                    guard let s = t.statusName?.lowercased() else { return true }
                    return !closed.contains(s)
                }, by: { $0.priorityName ?? "None" })
                    .map { (label: $0.key, count: $0.value.count) }
                    .sorted { (priorityOrder[$0.label] ?? 99) < (priorityOrder[$1.label] ?? 99) }
                let prioColors: [Color] = [.green, .orange, .red, .purple, .gray]
                ticketPriorityBars = prios.enumerated().map { i, p in ChartBar(label: p.label, value: p.count, color: prioColors[i % prioColors.count]) }
            }
        }

        // Work Items
        if appState.config.isDevOpsConfigured {
            if appState.cachedWorkItems.isEmpty && !appState.isWorkItemsCacheValid {
                do {
                    let items = try await appState.devOpsService.getWorkItems(limit: 200)
                    appState.updateWorkItemsCache(items)
                } catch {
                    dbg.error("Dashboard work items fetch: \(error)", category: "dashboard")
                }
            }

            let workItems = appState.cachedWorkItems
            if !workItems.isEmpty {
                let states = Dictionary(grouping: workItems, by: { $0.fields?.state ?? "Unknown" })
                    .map { (state: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }
                let sc: [Color] = [.blue, .green, .orange, .red, .gray, .brown]
                workItemSlices = states.enumerated().map { i, s in
                    ChartSlice(label: "\(s.state) (\(s.count))", value: s.count, color: sc[i % sc.count])
                }
                activeWorkItems = workItems.filter {
                    let s = $0.fields?.state?.lowercased() ?? ""
                    return s != "done" && s != "closed" && s != "removed"
                }.count

                do {
                    let sprints = try await appState.devOpsService.getSprints()
                    if let current = sprints.first(where: { $0.isCurrent }) {
                        let name = current.name ?? "Current"
                        let si = workItems.filter { $0.fields?.iterationPath?.hasSuffix(name) == true }
                        let done = si.filter { $0.fields?.state?.lowercased() == "done" }.count
                        sprintInfo = "Sprint: \(name) · \(done)/\(si.count) done"
                    }
                } catch {
                    dbg.error("Dashboard sprints: \(error)", category: "dashboard")
                }
            }
        }
    }

    private func loadInventory() async {
        guard appState.config.isSnipeConfigured else { return }
        isLoadingInventory = true
        defer { isLoadingInventory = false }

        if appState.cachedAssets.isEmpty && !appState.isAssetsCacheValid {
            do {
                let assets = try await appState.snipeService.getAllAssets()
                appState.updateAssetsCache(assets)
            } catch {
                dbg.error("Dashboard asset fetch: \(error)", category: "dashboard")
                return
            }
        }

        let assets = appState.cachedAssets
        guard !assets.isEmpty else { return }

        assetCount = assets.count
        deployedCount = assets.filter { $0.statusLabel?.statusMeta?.lowercased() == "deployed" }.count
        unassignedCount = assets.filter { $0.assignedTo == nil }.count

        let statusGroups = Dictionary(grouping: assets, by: { $0.statusLabel?.statusMeta ?? $0.statusLabel?.name ?? "Unknown" })
            .map { (status: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(5)
        let sc: [Color] = [.green, .blue, .orange, .red, .gray]
        assetStatusSlices = statusGroups.enumerated().map { i, s in
            ChartSlice(label: "\(s.status) (\(s.count))", value: s.count, color: sc[i % sc.count])
        }

        let cats = Dictionary(grouping: assets, by: { $0.category?.name ?? "Uncategorized" })
            .map { (cat: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(8)
        let catColors: [Color] = [.orange, .blue, .purple, .teal, .green, .red, .brown, .indigo]
        assetCategoryBars = cats.enumerated().map { i, c in ChartBar(label: c.cat, value: c.count, color: catColors[i % catColors.count]) }
    }

    private func buildActivityFeed() {
        var items: [ActivityItem] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoAlt = ISO8601DateFormatter()
        isoAlt.formatOptions = [.withInternetDateTime]

        func parse(_ str: String?) -> Date? {
            guard let s = str else { return nil }
            return iso.date(from: s) ?? isoAlt.date(from: s)
        }

        // Tickets (recent by modifiedDate)
        let sortedTickets = appState.cachedTickets
            .compactMap { t -> (TdxTicket, Date)? in
                guard let d = parse(t.modifiedDate) else { return nil }
                return (t, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
        for (t, date) in sortedTickets {
            let title = String((t.title ?? "").prefix(50))
            items.append(ActivityItem(icon: "ticket", text: "#\(t.id ?? 0)  \(title)  -  \(t.statusName ?? "")",
                                      time: formatRelative(date), timestamp: date, tab: "Tickets"))
        }

        // Work items
        let sortedWork = appState.cachedWorkItems
            .compactMap { w -> (WorkItem, Date)? in
                guard let d = parse(w.fields?.changedDate) else { return nil }
                return (w, d)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
        for (w, date) in sortedWork {
            let title = String((w.fields?.title ?? "").prefix(50))
            items.append(ActivityItem(icon: "list.bullet.rectangle", text: "#\(w.id)  \(title)  -  \(w.fields?.state ?? "")",
                                      time: formatRelative(date), timestamp: date, tab: "Projects"))
        }

        // Devices
        let sortedDevices = appState.cachedDevices
            .compactMap { d -> (IntuneDevice, Date)? in
                guard let dt = parse(d.lastSyncDateTime) else { return nil }
                return (d, dt)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
        for (d, date) in sortedDevices {
            items.append(ActivityItem(icon: "laptopcomputer", text: "\(d.deviceName ?? "Device") synced  -  \(d.operatingSystem ?? "")",
                                      time: formatRelative(date), timestamp: date, tab: "Devices"))
        }

        // Assets
        for a in appState.cachedAssets.prefix(4) {
            if let dateStr = a.updatedAt?.value, let date = parse(dateStr) {
                let name = a.name ?? a.assetTag ?? "Asset"
                items.append(ActivityItem(icon: "shippingbox", text: "\(name)  -  \(a.statusLabel?.name ?? "")",
                                          time: formatRelative(date), timestamp: date, tab: "Inventory"))
            }
        }

        activityItems = items.sorted { $0.timestamp > $1.timestamp }.prefix(15).map { $0 }
    }

    private func formatRelative(_ date: Date) -> String {
        let span = Date().timeIntervalSince(date)
        if span < 120 { return "just now" }
        if span < 3600 { return "\(Int(span / 60))m ago" }
        if span < 86400 { return "\(Int(span / 3600))h ago" }
        if span < 604800 { return "\(Int(span / 86400))d ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}

// MARK: - KPI Card

struct KPICard: View {
    let kpi: KPI
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: kpi.icon)
                        .font(.title3)
                        .foregroundStyle(kpi.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        if kpi.loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(kpi.value)
                                .font(.title2.bold().monospacedDigit())
                        }
                        Text(kpi.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout

struct DashboardFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
