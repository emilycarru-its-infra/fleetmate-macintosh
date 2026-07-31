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
    let name: String
    let detail: String
    let time: String
    let timestamp: Date
    let tab: AppTab
    var deviceId: String?
    var ticketId: Int?
    /// Who/where context: ticket requestor, work-item area, device user,
    /// asset allocation. Middle column of the feed's grid.
    var context: String?
}

struct AlertPill: Hashable {
    let text: String
    let color: Color
    let tab: AppTab
}

struct KPI: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let icon: String
    let color: Color
    let loading: Bool
    let tab: AppTab
}

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.appFontScale) private var fontScale
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
    /// Snipe's activity log lives on AppState — refetching it per tab switch
    /// left the feed blank for seconds every time the Dashboard came back.
    private var snipeActivity: [SnipeActivityLog] { appState.cachedSnipeActivity }

    // "My pull requests" queue across Azure DevOps + GitHub. Owned by AppState so
    // it outlives this view — see AppState.pullRequestQueue.
    private var pullRequestModel: PullRequestQueueModel { appState.pullRequestQueue }

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
    @State private var showAuthPopover = false
    @State private var activityFilter: AppTab? = nil

    // Global search (top right): query + debounced results over the caches.
    @State private var searchQuery = ""
    @State private var searchResults: [GlobalSearchResult] = []
    @FocusState private var searchFocused: Bool

    // Draggable split
    @State private var splitFraction: CGFloat = 0.7
    @State private var splitFractionDragStart: CGFloat = 0.7

    private var isAnyLoading: Bool {
        isLoadingFleet || isLoadingReportMate || isLoadingTickets || isLoadingInventory
    }

    private var hasAnyService: Bool {
        appState.config.isGraphConfigured || appState.config.isSnipeConfigured ||
        appState.config.isTdxConfigured || appState.config.isDevOpsConfigured ||
        appState.config.reportMateUrl != nil ||
        !appState.authManager.configuredSystems.isEmpty
    }

    // Adaptive columns -- flow based on available width
    private let adaptiveColumns = [
        GridItem(.adaptive(minimum: 300, maximum: 520), spacing: 14, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed top: header + alerts + KPIs
            VStack(alignment: .leading, spacing: 10) {
                headerSection
                if let error = appState.errorMessage { errorBanner(error) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if !hasAnyService && !appState.showOnboardingWizard {
                connectServicesPrompt
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                splitLayout
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { searchResultsOverlay }
        .toolbar { dashboardToolbar }
        .onAppCommand { command in
            if command == .refresh { Task { await refreshAll() } }
            if command == .find { searchFocused = true }
        }
        .task(id: searchQuery) {
            guard searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 else {
                searchResults = []
                return
            }
            // Debounce; the task id change cancels a superseded scan.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            searchResults = GlobalSearchScanner.search(searchQuery, appState: appState)
        }
        .task {
            // Paint from the warm caches immediately; the loads refresh after.
            buildActivityFeed()
            await loadAllSections()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in }
        .onChange(of: appState.cachedDevices.count) { _, _ in refreshSection(.devices) }
        .onChange(of: appState.cachedAssets.count) { _, _ in refreshSection(.assets) }
        .onChange(of: appState.cachedTickets.count) { _, _ in refreshSection(.tickets) }
        .onChange(of: appState.cachedWorkItems.count) { _, _ in refreshSection(.tickets) }
        .onChange(of: appState.showOnboardingWizard) { _, s in if !s { refreshSection(.all) } }
        .onChange(of: appState.snipeSsoAuthenticated) { _, a in if a { refreshSection(.assets) } }
        .onChange(of: appState.secretsConfigured) { _, _ in refreshSection(.all) }
        // DevOps PRs need the SSO bearer token, which usually lands after first paint.
        .onChange(of: appState.devOpsSsoAuthenticated) { _, a in
            if a { pullRequestModel.load(appState: appState, force: true) }
        }
    }

    // MARK: - Split Layout (draggable)

    private var splitLayout: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                // Left panel: widgets
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PullRequestQueueSection(model: pullRequestModel, tasksModel: appState.dashboardTasks)
                            .environmentObject(appState)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 16)
                        kpiHeaderRow
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        chartGrid
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
                .frame(width: floor(geo.size.width * splitFraction))
                .frame(maxHeight: .infinity)

                // Draggable divider
                DashboardSplitHandle(
                    splitFraction: $splitFraction,
                    splitFractionDragStart: $splitFractionDragStart,
                    totalWidth: geo.size.width
                )

                // Right panel: activity feed
                activityFeedSection
                    .frame(width: max(geo.size.width * (1 - splitFraction) - 8, 0))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func navigate(to tab: AppTab, deviceId: String? = nil, ticketId: Int? = nil, filter: String? = nil) {
        if let deviceId { appState.navigateToDeviceId = deviceId }
        if let ticketId { appState.navigateToTicketId = ticketId }
        if let filter { appState.navigateToFilter = filter }
        appState.navigateToTab = tab
    }

    private enum RefreshSection { case all, devices, assets, tickets }

    private func refreshSection(_ section: RefreshSection) {
        Task {
            switch section {
            case .all:     await loadAllSections()
            case .devices: await loadFleetHealth(); buildActivityFeed()
            case .assets:  await loadInventory(); buildActivityFeed()
            case .tickets: await loadTicketsWork(); buildActivityFeed()
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: { Task { await refreshAll() } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isAnyLoading)

            Button(action: { showAuthPopover.toggle() }) {
                Label("Authentication", systemImage: "lock.shield")
            }
            .popover(isPresented: $showAuthPopover, arrowEdge: .bottom) {
                AuthSettingsView()
                    .environmentObject(appState)
                    .frame(width: 480)
                    .frame(minHeight: 300, idealHeight: 560, maxHeight: 640)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .appFont(.largeTitle, weight: .bold)
                Text("Fleet overview across all connected systems")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isAnyLoading {
                ProgressView().controlSize(.small)
            }
            // The search shares the title row — generous, but capped so the
            // title keeps its breathing room.
            GlobalSearchField(query: $searchQuery, focused: $searchFocused, large: true)
                .frame(maxWidth: 560)
        }
    }

    // MARK: - Global Search

    @ViewBuilder
    private var searchResultsOverlay: some View {
        if !searchQuery.isEmpty && !searchResults.isEmpty {
            ZStack(alignment: .topTrailing) {
                // Tap anywhere outside the panel to dismiss.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { searchQuery = "" }
                GlobalSearchResultsPanel(results: searchResults, width: 560) { hit in
                    openSearchResult(hit)
                }
                // Flush under the field: same width, same trailing edge.
                .padding(.trailing, 16)
                .padding(.top, 70)
            }
            .transition(.opacity)
        }
    }

    private func openSearchResult(_ hit: GlobalSearchResult) {
        switch hit.category {
        case .devices:
            navigate(to: .devices, deviceId: hit.deviceId)
        case .inventory:
            appState.navigateToInventorySearch = hit.inventoryFilter
            navigate(to: .inventory)
        case .tickets:
            navigate(to: .tickets, ticketId: hit.ticketId)
        case .workItems:
            navigate(to: .projects)
        case .users, .groups:
            navigate(to: .identity)
        }
        searchQuery = ""
    }

    // MARK: - Connect Prompt

    private var connectServicesPrompt: some View {
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("No services connected").appFont(.headline)
                Text("Run the setup wizard to connect your IT systems.")
                    .foregroundStyle(.secondary)
                Button("Run Setup Wizard") {
                    appState.showOnboardingWizard = true
                }
                .controlSize(.large)
                Button("Open Settings") { settingsSelectedTab = 0; openSettings() }
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
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
                            .appFont(.caption).fontWeight(.medium)
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
        if nonCompliantCount > 0 { pills.append(.init(text: "\(nonCompliantCount) non-compliant", color: .red, tab: .devices)) }
        if staleCount > 0 { pills.append(.init(text: "\(staleCount) stale (30d+)", color: .orange, tab: .devices)) }
        if slaViolatedCount > 0 { pills.append(.init(text: "\(slaViolatedCount) SLA violations", color: .red, tab: .tickets)) }
        if unassignedCount > 5 { pills.append(.init(text: "\(unassignedCount) unassigned assets", color: .blue, tab: .inventory)) }
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
            kpis.append(KPI(title: "Devices", value: "\(deviceCount)", icon: "laptopcomputer", color: .blue, loading: isLoadingFleet, tab: .devices))
            if nonCompliantCount > 0 {
                kpis.append(KPI(title: "Non-Compliant", value: "\(nonCompliantCount)", icon: "exclamationmark.triangle", color: .red, loading: false, tab: .devices))
            }
            if staleCount > 0 {
                kpis.append(KPI(title: "Stale (30d+)", value: "\(staleCount)", icon: "clock.badge.exclamationmark", color: .orange, loading: false, tab: .devices))
            }
        }
        if appState.config.isTdxConfigured {
            kpis.append(KPI(title: "Open Tickets", value: "\(openTicketCount)", icon: "ticket", color: .purple, loading: isLoadingTickets, tab: .tickets))
        }
        if appState.config.isDevOpsConfigured {
            kpis.append(KPI(title: "Active Work Items", value: "\(activeWorkItems)", icon: "list.bullet.rectangle", color: .indigo, loading: isLoadingTickets, tab: .projects))
        }
        if appState.config.isSnipeConfigured {
            kpis.append(KPI(title: "Assets", value: "\(assetCount)", icon: "shippingbox", color: .orange, loading: isLoadingInventory, tab: .inventory))
        }
        if appState.config.reportMateUrl != nil {
            kpis.append(KPI(title: "Managed Macs", value: "\(rmDeviceCount)", icon: "desktopcomputer", color: .teal, loading: isLoadingReportMate, tab: .devices))
        }
        return kpis
    }

    // MARK: - KPI Grid (2x2)

    /// The four KPI cards in one row, between the PR/tasks split and the charts.
    private var kpiHeaderRow: some View {
        let cfg = appState.config
        return HStack(spacing: 12) {
            if cfg.isGraphConfigured {
                KPICard(kpi: KPI(title: "Managed Devices", value: "\(deviceCount)", icon: "laptopcomputer", color: .blue, loading: isLoadingFleet, tab: .devices)) { navigate(to: .devices) }
            }
            if cfg.isSnipeConfigured {
                KPICard(kpi: KPI(title: "Assets Inventory", value: "\(assetCount)", icon: "shippingbox", color: .orange, loading: isLoadingInventory, tab: .inventory)) { navigate(to: .inventory) }
            }
            if cfg.isDevOpsConfigured {
                KPICard(kpi: KPI(title: "Active Work Items", value: "\(activeWorkItems)", icon: "list.bullet.rectangle", color: .indigo, loading: isLoadingTickets, tab: .projects)) { navigate(to: .projects) }
            }
            if cfg.isTdxConfigured {
                KPICard(kpi: KPI(title: "Open Tickets", value: "\(openTicketCount)", icon: "ticket", color: .purple, loading: isLoadingTickets, tab: .tickets)) { navigate(to: .tickets) }
            }
        }
    }

    // MARK: - Chart Grid (flowing, Assets by Category first)

    private var chartGrid: some View {
        LazyVGrid(columns: adaptiveColumns, spacing: 16) {
            // Assets by Category first
            if appState.config.isSnipeConfigured {
                chartCard("Assets by Category", tab: .inventory, isLoading: isLoadingInventory) {
                    if isLoadingInventory && assetCategoryBars.isEmpty {
                        SkeletonChartCard()
                    } else if assetCategoryBars.isEmpty {
                        emptyState("No asset data")
                    } else {
                        barChart(assetCategoryBars, height: 180, tab: .inventory, filterCategory: "Category")
                    }
                }
            }

            if appState.config.isGraphConfigured {
                chartCard("Platform Distribution", tab: .devices, isLoading: isLoadingFleet) {
                    if isLoadingFleet && osSlices.isEmpty {
                        SkeletonChartCard()
                    } else if osSlices.isEmpty {
                        emptyState("No device data")
                    } else {
                        TreemapChart(slices: osSlices, height: 180) { label in
                            openChartFilter(tab: .devices, category: "Platform", label: label)
                        }
                    }
                }
            }

            if appState.config.isTdxConfigured {
                chartCard("Ticket Status", tab: .tickets, isLoading: isLoadingTickets) {
                    if isLoadingTickets && ticketStatusSlices.isEmpty {
                        SkeletonChartCard()
                    } else if ticketStatusSlices.isEmpty {
                        emptyState("No ticket data")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            donutChart(ticketStatusSlices, size: 180, tab: .tickets, filterCategory: "Status")
                            if slaViolatedCount > 0 {
                                Text("\(slaViolatedCount) SLA violated")
                                    .appFont(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }
                chartCard("Tickets by Priority", tab: .tickets, isLoading: isLoadingTickets) {
                    if isLoadingTickets && ticketPriorityBars.isEmpty {
                        SkeletonChartCard()
                    } else if ticketPriorityBars.isEmpty {
                        emptyState("No ticket data")
                    } else {
                        barChart(ticketPriorityBars, height: 120, tab: .tickets, filterCategory: "Priority")
                    }
                }
            }

            if appState.config.isDevOpsConfigured {
                chartCard("Work Items", tab: .projects, isLoading: isLoadingTickets) {
                    if isLoadingTickets && workItemSlices.isEmpty {
                        SkeletonChartCard()
                    } else if workItemSlices.isEmpty {
                        emptyState("No work item data")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            donutChart(workItemSlices, size: 180, tab: .projects)
                            if !sprintInfo.isEmpty {
                                Text(sprintInfo).appFont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if appState.config.reportMateUrl != nil {
                chartCard("Errors by Category", tab: .devices, isLoading: isLoadingReportMate) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            miniStat("Managed", "\(rmDeviceCount)", color: .blue)
                            miniStat("Errors", "\(rmErrorCount)", color: rmErrorCount > 0 ? .red : .green)
                        }
                        if isLoadingReportMate && errorCategoryBars.isEmpty {
                            SkeletonChartCard()
                        } else if errorCategoryBars.isEmpty {
                            emptyState("No errors found")
                        } else {
                            barChart(errorCategoryBars, height: 180)
                        }
                    }
                }
            }

            if appState.config.isGraphConfigured {
                chartCard("Compliance", tab: .devices, isLoading: isLoadingFleet) {
                    if isLoadingFleet && complianceSlices.isEmpty {
                        SkeletonChartCard()
                    } else if complianceSlices.isEmpty {
                        emptyState("No device data")
                    } else {
                        donutChart(complianceSlices, size: 180, tab: .devices, filterCategory: "Compliance")
                    }
                }
            }

            if appState.config.isSnipeConfigured {
                chartCard("Asset Status", tab: .inventory, isLoading: isLoadingInventory) {
                    if isLoadingInventory && assetStatusSlices.isEmpty {
                        SkeletonChartCard()
                    } else if assetStatusSlices.isEmpty {
                        emptyState("No asset data")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            donutChart(assetStatusSlices, size: 180, tab: .inventory, filterCategory: "Status")
                            Text("\(deployedCount) deployed - \(unassignedCount) unassigned")
                                .appFont(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Activity Feed (right column, fills height)

    private var activityFeedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Activity").appFont(.headline)
                Spacer()
                if isAnyLoading { ProgressView().controlSize(.mini) }
            }

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    activityFilterChip("All", tab: nil)
                    ForEach(AppTab.enabledTabs(config: appState.config).filter { $0 != .dashboard }) { tab in
                        activityFilterChip(tab.rawValue.capitalized, tab: tab)
                    }
                }
            }

            // Feed fills remaining height
            GroupBox {
                if filteredActivityItems.isEmpty && isAnyLoading {
                    VStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonRow()
                            Divider()
                        }
                    }
                } else if filteredActivityItems.isEmpty {
                    Text(activityItems.isEmpty ? "Activity will appear once data loads." : "No activity for this filter.")
                        .foregroundStyle(.secondary).appFont(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredActivityItems) { item in
                                Button(action: { navigate(to: item.tab, deviceId: item.deviceId, ticketId: item.ticketId) }) {
                                    // Same invisible-grid treatment as the task
                                    // tables: fixed columns so rows line up.
                                    HStack(spacing: 6) {
                                        Image(systemName: item.icon)
                                            .appFont(fixed: 11)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 14)
                                        Text(item.name)
                                            .appFont(fixed: 12)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if let context = item.context, !context.isEmpty {
                                            Text(context)
                                                .appFont(fixed: 10)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 130, alignment: .trailing)
                                        } else {
                                            Color.clear.frame(width: 130, height: 1)
                                        }
                                        Group {
                                            if item.detail.isEmpty {
                                                Color.clear.frame(height: 1)
                                            } else {
                                                Text(item.detail)
                                                    .appFont(fixed: 10, weight: .medium)
                                                    .lineLimit(1)
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 2)
                                                    .background(Color.secondary.opacity(0.12))
                                                    .foregroundStyle(.secondary)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        .frame(width: 82, alignment: .center)
                                        Text(item.time)
                                            .appFont(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 52, alignment: .trailing)
                                    }
                                    .padding(.vertical, 7)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
    }

    private func activityFilterChip(_ label: String, tab: AppTab?) -> some View {
        let isSelected = activityFilter == tab
        return Button(action: { activityFilter = tab }) {
            Text(label)
                .appFont(.caption).fontWeight(.medium)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filteredActivityItems: [ActivityItem] {
        guard let filter = activityFilter else { return activityItems }
        return activityItems.filter { $0.tab == filter }
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

    private func chartCard<Content: View>(_ title: String, tab: AppTab, isLoading: Bool, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(action: { navigate(to: tab) }) {
                        HStack(spacing: 4) {
                            Text(title).appFont(.subheadline, weight: .bold)
                            Image(systemName: "chevron.right")
                                .appFont(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if isLoading { ProgressView().controlSize(.mini).padding(.leading, 2) }
                }
                content()
            }
            .padding(4)
        }
    }

    /// Wedge click → open the tab with that value filtered. Deliberately a real
    /// tap gesture, NOT `.chartAngleSelection`: angle selection tracks the
    /// pointer continuously, so merely resting the cursor on a donut navigated
    /// tabs — the long-mysterious "app randomly opens Inventory" bug.
    private func donutChart(_ slices: [ChartSlice], size: CGFloat, tab: AppTab? = nil, filterCategory: String? = nil) -> some View {
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
                        .appFont(.caption2, weight: .bold)
                        .foregroundStyle(.white)
                }
            }
        }
        .chartForegroundStyleScale(domain: slices.map(\.label), range: slices.map(\.color))
        .chartLegend(position: .trailing, alignment: .center, spacing: 8)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let tab, let plotAnchor = proxy.plotFrame else { return }
                        let plot = geo[plotAnchor]
                        let dx = location.x - plot.midX
                        let dy = location.y - plot.midY
                        let radius = (dx * dx + dy * dy).squareRoot()
                        let outer = min(plot.width, plot.height) / 2
                        guard radius <= outer, radius >= outer * 0.4 else { return }
                        // SectorMarks start at 12 o'clock and run clockwise.
                        var angle = atan2(dy, dx) + .pi / 2
                        if angle < 0 { angle += 2 * .pi }
                        let fraction = angle / (2 * .pi)
                        let total = slices.reduce(0) { $0 + $1.value }
                        guard total > 0 else { return }
                        var cumulative = 0.0
                        for slice in slices {
                            cumulative += Double(slice.value) / Double(total)
                            if fraction <= cumulative {
                                openChartFilter(tab: tab, category: filterCategory, label: slice.label)
                                break
                            }
                        }
                    }
            }
        }
        .frame(height: size)
    }

    /// Bar/wedge deep-link: strip any "(count)" suffix from the label, stash
    /// the filter for the destination tab, and go.
    private func openChartFilter(tab: AppTab, category: String?, label: String) {
        let value = label.components(separatedBy: " (").first ?? label
        if let category {
            appState.navigateToModuleFilter = ModuleFilterLink(tab: tab, category: category, value: value)
        }
        navigate(to: tab)
    }

    private func barChart(_ bars: [ChartBar], height: CGFloat, tab: AppTab? = nil, filterCategory: String? = nil) -> some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Count", bar.value),
                y: .value("Label", bar.label)
            )
            .foregroundStyle(by: .value("Category", bar.label))
            .annotation(position: .trailing, alignment: .leading) {
                if bar.value > 0 {
                    Text("\(bar.value)").appFont(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .chartForegroundStyleScale(domain: bars.map(\.label), range: bars.map(\.color))
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            // AxisValueLabel is chart content, not a View, so it takes a resolved
            // Font rather than the .appFont modifier.
            AxisMarks { _ in AxisValueLabel().font(AppTextStyle.caption2.font(scale: fontScale)) }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let tab, let plotAnchor = proxy.plotFrame else { return }
                        let plot = geo[plotAnchor]
                        guard let label: String = proxy.value(atY: location.y - plot.origin.y) else { return }
                        openChartFilter(tab: tab, category: filterCategory, label: label)
                    }
            }
        }
        .frame(height: max(height, CGFloat(bars.count) * 28))
    }

    private func emptyState(_ msg: String) -> some View {
        Text(msg)
            .appFont(.callout).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private func miniStat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).appFont(.title3, weight: .bold).monospacedDigit().foregroundStyle(color)
            Text(label).appFont(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Data Loading

    private func refreshAll() async {
        appState.invalidateAllCaches()
        pullRequestModel.load(appState: appState, force: true)
        await appState.preloadAllData()
        await loadAllSections()
    }

    private func loadAllSections() async {
        // The PR queue runs on its own task so a slow provider never holds up
        // the charts (and vice versa).
        pullRequestModel.load(appState: appState)
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

        let platformColorMap: [String: Color] = [
            "Macintosh": .orange,
            "Windows": .blue,
            "iOS/iPadOS": .purple,
            "Android": .green,
            "Linux": .teal,
            "ChromeOS": .brown
        ]
        let platformLabelMap: [String: String] = [
            "macOS": "Macintosh",
            "iOS": "iOS/iPadOS",
            "iPadOS": "iOS/iPadOS"
        ]
        let osCounts = Dictionary(grouping: devices, by: { platformLabelMap[$0.operatingSystem ?? ""] ?? ($0.operatingSystem ?? "") })
            .filter { !$0.key.isEmpty && $0.value.count > 0 }
            .map { (key: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(6)
        let fallbackColors: [Color] = [.blue, .purple, .orange, .teal, .brown, .gray]
        osSlices = osCounts.enumerated().map { i, os in
            ChartSlice(label: os.key, value: os.count, color: platformColorMap[os.key] ?? fallbackColors[i % fallbackColors.count])
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
            // Only attempt API call if we have auth (SSO cookies or API key)
            guard appState.snipeService.isConfigured else { return }
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

        // Fetch recent activity log (last 24h worth, up to 50 entries)
        do {
            appState.cachedSnipeActivity = try await appState.snipeService.getActivityLog(limit: 50)
        } catch {
            dbg.error("Dashboard snipe activity: \(error)", category: "dashboard")
        }
    }

    private func buildActivityFeed() {
        var items: [ActivityItem] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoAlt = ISO8601DateFormatter()
        isoAlt.formatOptions = [.withInternetDateTime]
        let cutoff = Date().addingTimeInterval(-86400) // last 24 hours
        // Inventory moves slower than tickets and syncs — a day of Snipe
        // activity is often near-empty, so it looks back a week.
        let inventoryCutoff = Date().addingTimeInterval(-7 * 86400)

        func parse(_ str: String?) -> Date? {
            guard let s = str else { return nil }
            return iso.date(from: s) ?? isoAlt.date(from: s)
        }

        // Tickets – all modified in last 24h
        for (t, date) in appState.cachedTickets
            .compactMap({ t -> (TdxTicket, Date)? in
                guard let d = parse(t.modifiedDate), d > cutoff else { return nil }
                return (t, d)
            })
            .sorted(by: { $0.1 > $1.1 }) {
            let title = String((t.title ?? "").prefix(50))
            items.append(ActivityItem(icon: "ticket", name: "#\(t.id ?? 0)  \(title)",
                                      detail: t.statusName ?? "",
                                      time: formatRelative(date), timestamp: date, tab: .tickets, ticketId: t.id,
                                      context: t.requestorName))
        }

        // Work items – all changed in last 24h
        for (w, date) in appState.cachedWorkItems
            .compactMap({ w -> (WorkItem, Date)? in
                guard let d = parse(w.fields?.changedDate), d > cutoff else { return nil }
                return (w, d)
            })
            .sorted(by: { $0.1 > $1.1 }) {
            let title = String((w.fields?.title ?? "").prefix(50))
            items.append(ActivityItem(icon: "list.bullet.rectangle", name: "#\(w.id)  \(title)",
                                      detail: w.fields?.state ?? "",
                                      time: formatRelative(date), timestamp: date, tab: .projects,
                                      context: w.fields?.areaPath?.split(separator: "\\").joined(separator: " › ")))
        }

        // Devices – all synced in last 24h
        for (d, date) in appState.cachedDevices
            .compactMap({ d -> (IntuneDevice, Date)? in
                guard let dt = parse(d.lastSyncDateTime), dt > cutoff else { return nil }
                return (d, dt)
            })
            .sorted(by: { $0.1 > $1.1 }) {
            items.append(ActivityItem(icon: "laptopcomputer", name: d.deviceName ?? "Device",
                                      detail: "synced",
                                      time: formatRelative(date), timestamp: date, tab: .devices, deviceId: d.id,
                                      context: d.userDisplayName ?? d.operatingSystem))
        }

        // Assets – updated within the inventory window
        for a in appState.cachedAssets {
            if let dateStr = a.updatedAt?.value, let date = parse(dateStr), date > inventoryCutoff {
                let name = a.name ?? a.assetTag ?? "Asset"
                items.append(ActivityItem(icon: "shippingbox", name: name,
                                          detail: a.statusLabel?.name ?? "",
                                          time: formatRelative(date), timestamp: date, tab: .inventory,
                                          context: a.assignedTo?.name ?? a.rtdLocation?.name))
            }
        }

        // Snipe activity log – inventory window
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        let dateFmtAlt = DateFormatter()
        dateFmtAlt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFmtAlt.timeZone = TimeZone(identifier: "UTC")
        for entry in snipeActivity {
            let dateStr = entry.createdAt?.value
            let date = dateStr.flatMap { parse($0) ?? dateFmt.date(from: $0) ?? dateFmtAlt.date(from: $0) }
            if let date = date, date > inventoryCutoff {
                let action = entry.actionType ?? "activity"
                let itemName = entry.item?.name ?? "item"
                let admin = entry.admin?.name ?? ""
                items.append(ActivityItem(icon: "arrow.triangle.2.circlepath", name: "\(admin) \(action)".trimmingCharacters(in: .whitespaces),
                                          detail: itemName,
                                          time: formatRelative(date), timestamp: date, tab: .inventory))
            }
        }

        activityItems = items.sorted { $0.timestamp > $1.timestamp }
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

// MARK: - Treemap Chart

struct TreemapChart: View {
    let slices: [ChartSlice]
    let height: CGFloat
    /// Block click → deep-link into the owning tab, filtered to that value.
    var onSelect: ((String) -> Void)? = nil

    @State private var hoveredSlice: ChartSlice? = nil
    @State private var hoveredRect: CGRect = .zero

    var body: some View {
        let total = slices.reduce(0) { $0 + $1.value }
        VStack(spacing: 4) {
            GeometryReader { geo in
                let rects = treemapLayout(slices: slices, total: total, bounds: CGRect(origin: .zero, size: geo.size))
                ZStack {
                    ForEach(Array(zip(slices, rects)), id: \.0.id) { slice, rect in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(slice.color.opacity(hoveredSlice?.id == slice.id ? 0.72 : 1.0))
                            .frame(width: max(rect.width - 2, 0), height: max(rect.height - 2, 0))
                            .overlay {
                                if rect.width > 40 && rect.height > 30 {
                                    VStack(spacing: 1) {
                                        Text(slice.label)
                                            .appFont(.caption2, weight: .bold)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                        Text("\(slice.value)")
                                            .appFont(.caption2)
                                    }
                                    .foregroundStyle(.white)
                                }
                            }
                            .position(x: rect.midX, y: rect.midY)
                            .onHover { isHovering in
                                hoveredSlice = isHovering ? slice : nil
                                hoveredRect = isHovering ? rect : .zero
                            }
                            .onTapGesture { onSelect?(slice.label) }
                    }
                    // Hover tooltip
                    if let slice = hoveredSlice {
                        let pct = total > 0 ? Int(Double(slice.value) / Double(total) * 100) : 0
                        let tx = min(max(hoveredRect.midX, 55), geo.size.width - 55)
                        let ty = hoveredRect.minY > 44 ? hoveredRect.minY - 28 : hoveredRect.maxY + 28
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slice.label).appFont(.caption, weight: .bold)
                            Text("\(slice.value)  ·  \(pct)%").appFont(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .position(x: tx, y: ty)
                        .zIndex(100)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: height)
            // Legend
            HStack(spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 4) {
                        Circle().fill(slice.color).frame(width: 7, height: 7)
                        Text("\(slice.label) (\(slice.value))")
                            .appFont(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func treemapLayout(slices: [ChartSlice], total: Int, bounds: CGRect) -> [CGRect] {
        guard !slices.isEmpty, total > 0 else { return [] }
        let areas = slices.map { CGFloat($0.value) / CGFloat(total) * bounds.width * bounds.height }
        var rects = Array(repeating: CGRect.zero, count: slices.count)
        var remaining = bounds
        var i = 0
        while i < slices.count {
            let isWide = remaining.width >= remaining.height
            let sideLen = isWide ? remaining.height : remaining.width
            var rowIndices: [Int] = []
            var rowArea: CGFloat = 0
            var bestWorst: CGFloat = .infinity
            for j in i..<slices.count {
                let candidate = rowArea + areas[j]
                let strip = candidate / sideLen
                let aspectWorst = (rowIndices + [j]).map { idx -> CGFloat in
                    let w = areas[idx] / strip
                    let h = strip
                    return max(w / h, h / w)
                }.max() ?? .infinity
                if aspectWorst <= bestWorst || rowIndices.isEmpty {
                    rowIndices.append(j)
                    rowArea = candidate
                    bestWorst = aspectWorst
                } else {
                    break
                }
            }
            let stripSize = rowArea / sideLen
            var offset: CGFloat = 0
            for idx in rowIndices {
                let itemLen = areas[idx] / stripSize
                if isWide {
                    rects[idx] = CGRect(x: remaining.minX, y: remaining.minY + offset, width: stripSize, height: itemLen)
                } else {
                    rects[idx] = CGRect(x: remaining.minX + offset, y: remaining.minY, width: itemLen, height: stripSize)
                }
                offset += itemLen
            }
            if isWide {
                remaining = CGRect(x: remaining.minX + stripSize, y: remaining.minY,
                                   width: remaining.width - stripSize, height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + stripSize,
                                   width: remaining.width, height: remaining.height - stripSize)
            }
            i += rowIndices.count
        }
        return rects
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
                        .appFont(.title3)
                        .foregroundStyle(kpi.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        if kpi.loading {
                            SkeletonView(width: 60, height: 22, cornerRadius: 4)
                        } else {
                            Text(kpi.value)
                                .appFont(.title2, weight: .bold).monospacedDigit()
                        }
                        Text(kpi.title)
                            .appFont(.caption2)
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

// MARK: - Draggable Split Handle

struct DashboardSplitHandle: View {
    @Binding var splitFraction: CGFloat
    @Binding var splitFractionDragStart: CGFloat
    let totalWidth: CGFloat

    @State private var isHovering = false

    var body: some View {
        ZStack {
            // Visible divider line
            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
                .frame(width: isHovering ? 2 : 1)
            // Grab indicator dots
            if isHovering {
                VStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle()
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        // Wide invisible hit-area
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        let newFraction = splitFractionDragStart + value.translation.width / totalWidth
                        splitFraction = min(0.8, max(0.2, newFraction))
                    }
                }
                .onEnded { value in
                    let newFraction = splitFractionDragStart + value.translation.width / totalWidth
                    splitFraction = min(0.8, max(0.2, newFraction))
                    splitFractionDragStart = splitFraction
                }
        )
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
