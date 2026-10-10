import SwiftUI
import FleetMateCore

/// One row in the Recent Activity feed.
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
    var assetId: Int?
    var workItemId: Int?
    /// Who/where context: ticket requestor, work-item area, device user,
    /// asset allocation. Middle column of the feed's grid.
    var context: String?
}

/// The toolbar's Recent Activity button: a launcher for whatever changed
/// lately in the tab being looked at, plus the search across every cache.
/// Lives in the window toolbar beside the authentication shield, so it is
/// reachable from every tab.
struct RecentActivityToolbarButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            Label {
                Text("Recent Activity")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .overlay(alignment: .topTrailing) {
                        // An app-level error used to sit in a Dashboard banner;
                        // the dot is how it stays visible on every tab.
                        if appState.errorMessage != nil {
                            Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .help("Recent activity in \(appState.selectedTab.rawValue)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RecentActivityPopover(tab: appState.selectedTab, development: appState.development) {
                isPresented = false
            }
            .environmentObject(appState)
            .frame(width: 560)
            .frame(minHeight: 320, idealHeight: 560, maxHeight: 640)
        }
    }
}

struct RecentActivityPopover: View {
    @EnvironmentObject var appState: AppState
    let tab: AppTab
    @ObservedObject var development: DevelopmentModel
    let dismiss: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = appState.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { appState.errorMessage = nil }.buttonStyle(.borderless).controlSize(.small)
                }
            }

            Group {
                HStack {
                    Label("Recent Activity", systemImage: tab.icon).appFont(.headline)
                    Text(tab.rawValue).appFont(.headline).foregroundStyle(.secondary)
                    Spacer()
                    if tab == .development {
                        Toggle("Hide mine", isOn: $development.hideMyComments)
                            .toggleStyle(.checkbox)
                            .appFont(.caption)
                            .help("Hide comments you wrote")
                    }
                }
                Divider()
                if tab == .development {
                    developmentFeed
                } else {
                    feed(ActivityFeedBuilder.items(for: tab, appState: appState))
                }
            }
        }
        .padding(16)
    }

    // MARK: Feeds

    @ViewBuilder
    private func feed(_ items: [ActivityItem]) -> some View {
        if items.isEmpty {
            emptyFeed(icon: tab.icon, message: "No recent activity in \(tab.rawValue).")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        Button { open(item) } label: { ActivityFeedRow(item: item) }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    /// The comment feed that used to be the Development tab's Activity
    /// sidebar: comments and reviews across every loaded pull request.
    @ViewBuilder
    private var developmentFeed: some View {
        let entries = development.activity(appState: appState)
        if entries.isEmpty {
            emptyFeed(icon: "bubble.left.and.bubble.right",
                      message: development.isLoadingPullRequests ? "Loading…" : "No recent comments.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        ActivityRow(
                            entry: entry,
                            isSelected: development.selectedPullRequest?.id == entry.pullRequest.id
                        ) {
                            development.segment = .pullRequests
                            development.selectedPullRequest = entry.pullRequest
                            appState.navigateToTab = .development
                            dismiss()
                        }
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func emptyFeed(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).appFont(.title2).foregroundStyle(.secondary)
            Text(message).appFont(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Navigation

    private func open(_ item: ActivityItem) {
        if let deviceId = item.deviceId { appState.navigateToDeviceId = deviceId }
        if let assetId = item.assetId { appState.navigateToAssetId = assetId }
        if let ticketId = item.ticketId { appState.navigateToTicketId = ticketId }
        if let workItemId = item.workItemId { appState.navigateToWorkItemId = workItemId }
        appState.navigateToTab = item.tab
        dismiss()
    }

}

/// Fixed columns so rows line up: icon, name, context, status pill, time.
struct ActivityFeedRow: View {
    let item: ActivityItem

    var body: some View {
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
                    .frame(width: 120, alignment: .trailing)
            } else {
                Color.clear.frame(width: 120, height: 1)
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
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Feed builder

/// Builds one tab's feed from the shared caches. Computed when the popover
/// opens rather than kept up to date, so it costs nothing until it is looked at.
@MainActor
enum ActivityFeedBuilder {
    static func items(for tab: AppTab, appState: AppState) -> [ActivityItem] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoAlt = ISO8601DateFormatter()
        isoAlt.formatOptions = [.withInternetDateTime]
        func parse(_ str: String?) -> Date? {
            guard let s = str else { return nil }
            return iso.date(from: s) ?? isoAlt.date(from: s)
        }
        let cutoff = Date().addingTimeInterval(-86400)
        // Inventory moves slower than tickets and syncs — a day of Snipe
        // activity is often near-empty, so it looks back a week.
        let inventoryCutoff = Date().addingTimeInterval(-7 * 86400)

        var items: [ActivityItem] = []
        switch tab {
        case .tickets:
            for t in appState.cachedTickets {
                guard let date = parse(t.modifiedDate), date > cutoff else { continue }
                let title = String((t.title ?? "").prefix(50))
                items.append(ActivityItem(icon: "ticket", name: "#\(t.id ?? 0)  \(title)",
                                          detail: t.statusName ?? "",
                                          time: relative(date), timestamp: date, tab: .tickets, ticketId: t.id,
                                          context: t.requestorName))
            }
        case .projects:
            var seen: Set<Int> = []
            for w in appState.cachedWorkItems + appState.cachedMyWorkItems {
                guard seen.insert(w.id).inserted,
                      let date = parse(w.fields?.changedDate), date > cutoff else { continue }
                let title = String((w.fields?.title ?? "").prefix(50))
                items.append(ActivityItem(icon: "list.bullet.rectangle", name: "#\(w.id)  \(title)",
                                          detail: w.fields?.state ?? "",
                                          time: relative(date), timestamp: date, tab: .projects,
                                          workItemId: w.id,
                                          context: w.fields?.areaPath?.split(separator: "\\").joined(separator: " › ")))
            }
        case .devices:
            for d in appState.cachedDevices {
                guard let date = parse(d.lastSyncDateTime), date > cutoff else { continue }
                items.append(ActivityItem(icon: "laptopcomputer", name: d.deviceName ?? "Device",
                                          detail: "synced",
                                          time: relative(date), timestamp: date, tab: .devices, deviceId: d.id,
                                          context: d.userDisplayName ?? d.operatingSystem))
            }
        case .inventory:
            for a in appState.cachedAssets {
                guard let date = parse(a.updatedAt?.value), date > inventoryCutoff else { continue }
                items.append(ActivityItem(icon: "shippingbox", name: a.name ?? a.assetTag ?? "Asset",
                                          detail: a.statusLabel?.name ?? "",
                                          time: relative(date), timestamp: date, tab: .inventory,
                                          assetId: a.id,
                                          context: a.assignedTo?.name ?? a.rtdLocation?.name))
            }
            items += snipeActivity(appState, cutoff: inventoryCutoff, parse: parse)
        case .development, .reporting, .manage, .identity:
            // Development has its own comment feed; Manage and Identity record
            // no timestamped activity yet.
            break
        }
        return items.sorted { $0.timestamp > $1.timestamp }
    }

    private static func snipeActivity(_ appState: AppState, cutoff: Date,
                                      parse: (String?) -> Date?) -> [ActivityItem] {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        let dateFmtAlt = DateFormatter()
        dateFmtAlt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Snipe's bare datetimes are in the instance's configured timezone,
        // not UTC — parsing as UTC pushed every row hours into the past.
        dateFmtAlt.timeZone = TimeZone(identifier: "America/Vancouver")
        return appState.cachedSnipeActivity.compactMap { entry in
            let dateStr = entry.createdAt?.value
            guard let date = dateStr.flatMap({ parse($0) ?? dateFmt.date(from: $0) ?? dateFmtAlt.date(from: $0) }),
                  date > cutoff else { return nil }
            // The asset leads the row: "Admins update" on every line said
            // nothing about which asset changed.
            let isAsset = (entry.item?.type ?? "asset").lowercased() == "asset"
            return ActivityItem(icon: "arrow.triangle.2.circlepath", name: entry.item?.name ?? "item",
                                detail: entry.actionType ?? "activity",
                                time: relative(date), timestamp: date, tab: .inventory,
                                assetId: isAsset ? entry.item?.id : nil,
                                context: entry.admin?.name)
        }
    }

    static func relative(_ date: Date) -> String {
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
