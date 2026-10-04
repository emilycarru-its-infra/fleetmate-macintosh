import SwiftUI
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

struct KPI: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let icon: String
    let color: Color
    let loading: Bool
    let tab: AppTab
}

// MARK: - Widget Metrics

/// The numbers behind every tab's Widgets section, computed from the shared
/// caches. Owned by AppState rather than the tab views: ContentView swaps the
/// tab content wholesale on every switch, so a view-owned copy came back empty
/// and recomputed (and, for ReportMate and sprints, refetched) each visit.
@MainActor
final class WidgetMetrics: ObservableObject {
    enum Section: Hashable { case devices, reportMate, tickets, workItems, inventory }

    // Devices
    @Published private(set) var deviceCount = 0
    @Published private(set) var nonCompliantCount = 0
    @Published private(set) var staleCount = 0
    @Published private(set) var complianceSlices: [ChartSlice] = []
    @Published private(set) var osSlices: [ChartSlice] = []

    // ReportMate
    @Published private(set) var rmDeviceCount = 0
    @Published private(set) var rmErrorCount = 0
    @Published private(set) var errorCategoryBars: [ChartBar] = []

    // Tickets
    @Published private(set) var openTicketCount = 0
    @Published private(set) var slaViolatedCount = 0
    @Published private(set) var ticketStatusSlices: [ChartSlice] = []
    @Published private(set) var ticketPriorityBars: [ChartBar] = []

    // Work items
    @Published private(set) var activeWorkItems = 0
    @Published private(set) var workItemSlices: [ChartSlice] = []
    @Published private(set) var sprintInfo = ""

    // Inventory
    @Published private(set) var assetCount = 0
    @Published private(set) var deployedCount = 0
    @Published private(set) var unassignedCount = 0
    @Published private(set) var assetStatusSlices: [ChartSlice] = []
    @Published private(set) var assetCategoryBars: [ChartBar] = []

    @Published private(set) var loading: Set<Section> = []
    private var loadedAt: [Section: Date] = [:]

    /// Sections that only re-read the caches are cheap; the ones that make a
    /// network call of their own (ReportMate, sprints, Snipe activity) are
    /// held to this so a burst of tab switches does not refetch them.
    private static let freshness: TimeInterval = 120

    func isLoading(_ section: Section) -> Bool { loading.contains(section) }

    func load(_ section: Section, appState: AppState, force: Bool = false) async {
        if loading.contains(section) { return }
        if !force, let at = loadedAt[section], Date().timeIntervalSince(at) < Self.freshness { return }
        loading.insert(section)
        defer {
            loading.remove(section)
            loadedAt[section] = Date()
        }
        switch section {
        case .devices:    await loadDevices(appState)
        case .reportMate: await loadReportMate(appState)
        case .tickets:    await loadTickets(appState)
        case .workItems:  await loadWorkItems(appState)
        case .inventory:  await loadInventory(appState)
        }
    }

    private func loadDevices(_ appState: AppState) async {
        guard appState.config.isGraphConfigured else { return }
        if appState.cachedDevices.isEmpty && !appState.isDevicesCacheValid {
            do {
                let devices = try await appState.graphService.getManagedDevices(limit: 10000)
                appState.updateDevicesCache(devices)
            } catch {
                dbg.error("Widget device fetch: \(error)", category: "widgets")
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
            ChartSlice(label: "Non-Compliant", value: nonCompliantCount, color: .orange)
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

    private func loadReportMate(_ appState: AppState) async {
        guard appState.config.reportMateUrl != nil else { return }
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
            errorCategoryBars = cats.map { ChartBar(label: $0.cat.rawValue, value: $0.count, color: .orange) }
        } catch {
            dbg.error("Widget ReportMate: \(error)", category: "widgets")
        }
    }

    private func loadTickets(_ appState: AppState) async {
        guard appState.config.isTdxConfigured else { return }
        if appState.cachedTickets.isEmpty && !appState.isTicketsCacheValid {
            do {
                var search = TicketSearchRequest(maxResults: 500)
                if let gid = appState.config.tdxResponsibleGroupId { search.responsibleGroupIds = [gid] }
                let tickets = try await appState.tdxService.searchTickets(search: search, maxResults: 500)
                appState.updateTicketsCache(tickets)
            } catch {
                dbg.error("Widget ticket fetch: \(error)", category: "widgets")
            }
        }

        let tickets = appState.cachedTickets
        guard !tickets.isEmpty else { return }
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
        // Keyed by name, not position, so a missing priority never shifts the
        // others' colours. No red: High is orange.
        let prioColors: [String: Color] = ["Low": .green, "Medium": .blue, "High": .orange]
        let otherColors: [Color] = [.purple, .gray, .teal]
        ticketPriorityBars = prios.enumerated().map { i, p in
            ChartBar(label: p.label, value: p.count, color: prioColors[p.label] ?? otherColors[i % otherColors.count])
        }
    }

    private func loadWorkItems(_ appState: AppState) async {
        guard appState.config.isDevOpsConfigured else { return }
        // The signed-in user's open items across every project — the same set
        // the work-items list shows, so the donut and the count agree with it.
        if !appState.isMyWorkItemsCacheValid {
            do {
                let items = try await appState.devOpsService.getMyOpenWorkItems()
                appState.updateMyWorkItemsCache(items)
            } catch {
                dbg.error("Widget work items fetch: \(error)", category: "widgets")
            }
        }

        let workItems = appState.cachedMyWorkItems
        activeWorkItems = workItems.count
        guard !workItems.isEmpty else {
            workItemSlices = []
            return
        }
        let states = Dictionary(grouping: workItems, by: { $0.fields?.state ?? "Unknown" })
            .map { (state: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        let sc: [Color] = [.blue, .green, .orange, .purple, .gray, .brown]
        workItemSlices = states.enumerated().map { i, s in
            ChartSlice(label: "\(s.state) (\(s.count))", value: s.count, color: sc[i % sc.count])
        }

        do {
            let sprints = try await appState.devOpsService.getSprints()
            if let current = sprints.first(where: { $0.isCurrent }) {
                let name = current.name ?? "Current"
                let si = workItems.filter { $0.fields?.iterationPath?.hasSuffix(name) == true }
                sprintInfo = "Sprint: \(name) · \(si.count) open"
            }
        } catch {
            dbg.error("Widget sprints: \(error)", category: "widgets")
        }
    }

    private func loadInventory(_ appState: AppState) async {
        guard appState.config.isSnipeConfigured else { return }
        if appState.cachedAssets.isEmpty && !appState.isAssetsCacheValid {
            // Only attempt the call with auth in hand (SSO cookies or API key).
            guard appState.snipeService.isConfigured else { return }
            do {
                let assets = try await appState.snipeService.getAllAssets()
                appState.updateAssetsCache(assets)
            } catch {
                dbg.error("Widget asset fetch: \(error)", category: "widgets")
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
        let sc: [Color] = [.green, .blue, .orange, .purple, .gray]
        assetStatusSlices = statusGroups.enumerated().map { i, s in
            ChartSlice(label: "\(s.status) (\(s.count))", value: s.count, color: sc[i % sc.count])
        }

        let cats = Dictionary(grouping: assets, by: { $0.category?.name ?? "Uncategorized" })
            .map { (cat: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(8)
        let catColors: [Color] = [.orange, .blue, .purple, .teal, .green, .pink, .brown, .indigo]
        assetCategoryBars = cats.enumerated().map { i, c in ChartBar(label: c.cat, value: c.count, color: catColors[i % catColors.count]) }

        // The Inventory activity feed reads Snipe's activity log.
        do {
            appState.cachedSnipeActivity = try await appState.snipeService.getActivityLog(limit: 50)
        } catch {
            dbg.error("Widget snipe activity: \(error)", category: "widgets")
        }
    }
}
