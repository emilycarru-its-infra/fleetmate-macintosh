import SwiftUI
import FleetMateCore

// MARK: - Result model

/// One hit from the dashboard's cross-system search. Everything comes from the
/// AppState caches, so scans are instant and never touch the network.
struct GlobalSearchResult: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case devices = "Devices"
        case reporting = "Reporting"
        case inventory = "Inventory"
        case tickets = "Tickets"
        case workItems = "Work Items"
        case pullRequests = "Pull Requests"
        case issues = "Issues"
        case commits = "Commits"
        case pipelines = "Pipeline Runs"
        case handbook = "Handbook"
        case users = "Users"
        case groups = "Groups"

        var icon: String {
            switch self {
            case .devices:   return "laptopcomputer"
            case .reporting: return "chart.bar.doc.horizontal"
            case .inventory: return "shippingbox"
            case .tickets:   return "ticket"
            case .workItems: return "list.bullet.rectangle"
            case .pullRequests: return "arrow.triangle.pull"
            case .issues: return "smallcircle.filled.circle"
            case .commits: return "point.3.connected.trianglepath.dotted"
            case .pipelines: return "play.circle"
            case .handbook: return "book.closed"
            case .users:     return "person"
            case .groups:    return "person.3"
            }
        }
    }

    let category: Category
    let id: String
    let title: String
    let subtitle: String
    /// Which field matched, so "why is this here?" is answered in the row.
    let matchLabel: String

    // Navigation payloads — whichever applies to the category.
    var deviceId: String?
    /// A ReportMate device, opened on the Reporting tab by serial.
    var reportingSerial: String?
    var ticketId: Int?
    var workItemId: Int?
    var inventoryFilter: String?
    var assetId: Int?
    /// Pull requests, issues, commits and runs open through their
    /// fleetmate:// link, the same route an outside link takes.
    var link: FleetMateLink?
    var handbookPage: HandbookPage?
}

/// A work-item id the way people actually type it: bare digits, or carrying a
/// `#` or `AB#` prefix copied out of Azure Boards.
/// Nil for anything else, so a search for "5030 Ridgeway" stays a text search.
func parseWorkItemId(_ rawQuery: String) -> Int? {
    var text = rawQuery.trimmingCharacters(in: .whitespaces)
    for prefix in ["AB#", "ab#", "AB", "ab", "#"] where text.hasPrefix(prefix) {
        text = String(text.dropFirst(prefix.count))
        break
    }
    text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, text.count <= 9, text.allSatisfy(\.isNumber) else { return nil }
    return Int(text)
}

// MARK: - Scanner

/// Pure in-memory fan-out over every cached system. Deliberately not a view or
/// a service: given the same caches and query it always returns the same rows.
@MainActor
enum GlobalSearchScanner {
    static let perCategoryLimit = 6

    static func search(_ rawQuery: String, appState: AppState) -> [GlobalSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 || parseWorkItemId(query) != nil else { return [] }

        var results: [GlobalSearchResult] = []
        results += devices(query, appState.cachedDevices)
        results += reportingDevices(query, appState.reporting.session.devices.map(ReportingHost.record))
        results += assets(query, appState.cachedAssets)
        results += tickets(query, appState.cachedTickets)
        results += workItems(query, appState.cachedWorkItems)
        results += pullRequests(query, appState.development.queue.pullRequests)
        results += issues(query, appState.dashboardTasks.issues)
        results += commits(query, appState.development.repositoryCommits)
        results += pipelineRuns(query, appState.development.pipelineRuns)
        results += appState.knowledge.handbook.search(query, limit: perCategoryLimit).map { page in
            GlobalSearchResult(category: .handbook, id: "hb-\(page.path)", title: page.title,
                               subtitle: page.breadcrumb, matchLabel: "Handbook", handbookPage: page)
        }
        results += users(query, appState.cachedEntraUsers)
        results += groups(query, appState.cachedGroups)
        return results
    }

    /// First matching (label, value) pair, so the row can say what matched.
    private static func firstMatch(_ query: String, _ fields: [(String, String?)]) -> (String, String)? {
        for (label, value) in fields {
            if let value, value.localizedCaseInsensitiveContains(query) {
                return (label, value)
            }
        }
        return nil
    }

    private static func devices(_ q: String, _ devices: [IntuneDevice]) -> [GlobalSearchResult] {
        devices.compactMap { device -> GlobalSearchResult? in
            guard let (label, value) = firstMatch(q, [
                ("Name", device.deviceName),
                ("Serial", device.serialNumber),
                ("User", device.userDisplayName),
                ("UPN", device.userPrincipalName),
                ("Model", device.model)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .devices,
                id: "device-\(device.id)",
                title: device.deviceName ?? device.serialNumber ?? "(unnamed)",
                subtitle: [device.model, device.userDisplayName].compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                deviceId: device.id
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func reportingDevices(_ q: String, _ devices: [ReportingDeviceRecord]) -> [GlobalSearchResult] {
        ReportingDeviceSearch.search(q, in: devices, limit: perCategoryLimit).map { hit in
            GlobalSearchResult(
                category: .reporting,
                id: "reporting-\(hit.device.serial)",
                title: hit.device.name,
                subtitle: [hit.device.platform, hit.device.user].compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(hit.field): \(hit.value)",
                reportingSerial: hit.device.serial
            )
        }
    }

    private static func assets(_ q: String, _ assets: [SnipeAsset]) -> [GlobalSearchResult] {
        assets.compactMap { asset -> GlobalSearchResult? in
            var fields: [(String, String?)] = [
                ("Name", asset.displayName),
                ("Serial", asset.serial),
                ("Tag", asset.assetTag),
                ("Allocation", asset.assignedTo?.name),
                ("Location", asset.rtdLocation?.name),
                ("Model", asset.model?.name)
            ]
            // Hostname, sharing name, fleet, … — whatever custom fields hold.
            for (name, field) in asset.customFields ?? [:] {
                fields.append((name, field.value))
            }
            guard let (label, value) = firstMatch(q, fields) else { return nil }
            return GlobalSearchResult(
                category: .inventory,
                id: "asset-\(asset.id)",
                title: asset.displayName ?? asset.assetTag ?? asset.serial ?? "(unnamed)",
                subtitle: [asset.model?.name, asset.assignedTo?.name ?? asset.rtdLocation?.name]
                    .compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                inventoryFilter: asset.serial ?? asset.assetTag ?? asset.displayName,
                assetId: asset.id
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func tickets(_ q: String, _ tickets: [TdxTicket]) -> [GlobalSearchResult] {
        tickets.compactMap { ticket -> GlobalSearchResult? in
            guard let id = ticket.id else { return nil }
            guard let (label, value) = firstMatch(q, [
                ("ID", String(id)),
                ("Title", ticket.title),
                ("Requestor", ticket.requestorName)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .tickets,
                id: "ticket-\(id)",
                title: ticket.title ?? "Ticket \(id)",
                subtitle: ["#\(id)", ticket.requestorName].compactMap { $0 }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                ticketId: id
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    static func workItems(_ q: String, _ items: [WorkItem]) -> [GlobalSearchResult] {
        // A prefixed id names the bare-digit id underneath it; a substring
        // scan for the whole string never matches, so resolve that form first.
        let idQuery = parseWorkItemId(q)
        return items.compactMap { item -> GlobalSearchResult? in
            let matched: (String, String)?
            if let idQuery, item.id == idQuery {
                matched = ("ID", String(item.id))
            } else {
                matched = firstMatch(q, [
                    ("ID", String(item.id)),
                    ("Title", item.fields?.title),
                    ("Assigned", item.fields?.assignedTo?.displayName)
                ])
            }
            guard let (label, value) = matched else { return nil }
            return row(for: item, matchLabel: "\(label): \(value)")
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    /// One work-item row, shared by the cached scan and the live id lookup.
    static func row(for item: WorkItem, matchLabel: String) -> GlobalSearchResult {
        GlobalSearchResult(
            category: .workItems,
            id: "wi-\(item.id)",
            title: item.fields?.title ?? "Work item \(item.id)",
            subtitle: ["AB#\(item.id)", item.fields?.workItemType, item.fields?.state]
                .compactMap { $0 }.joined(separator: " · "),
            matchLabel: matchLabel,
            workItemId: item.id
        )
    }

    /// A number the way people paste it: `27391`, `#27391`, `!27391`.
    private static func number(_ q: String) -> Int? {
        var text = q.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") || text.hasPrefix("!") { text.removeFirst() }
        guard !text.isEmpty, text.count <= 10, text.allSatisfy(\.isNumber) else { return nil }
        return Int(text)
    }

    private static func pullRequests(_ q: String, _ prs: [UnifiedPullRequest]) -> [GlobalSearchResult] {
        let wanted = number(q)
        return prs.compactMap { pr -> GlobalSearchResult? in
            let matched: (String, String)?
            if let wanted {
                matched = pr.number == wanted ? ("Number", "\(pr.number)") : nil
            } else {
                matched = firstMatch(q, [
                    ("Title", pr.title), ("Repository", "\(pr.container)/\(pr.repository)"),
                    ("Author", pr.authorName), ("Branch", pr.sourceBranch),
                ])
            }
            guard let (label, value) = matched else { return nil }
            let host: FleetMateLink.Host = pr.source == .gitHub
                ? .gitHub(owner: pr.container, repo: pr.repository)
                : .azureDevOps(project: pr.container, repo: pr.repository)
            return GlobalSearchResult(
                category: .pullRequests, id: "pr-\(pr.id)",
                title: pr.title,
                subtitle: ["\(pr.source == .gitHub ? "#" : "!")\(pr.number)", "\(pr.container)/\(pr.repository)", pr.authorName]
                    .joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                link: .pullRequest(host, number: pr.number))
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func issues(_ q: String, _ issues: [GitHubIssueSummary]) -> [GlobalSearchResult] {
        let wanted = number(q)
        return issues.compactMap { issue -> GlobalSearchResult? in
            let matched: (String, String)?
            if let wanted {
                matched = issue.number == wanted ? ("Number", "#\(issue.number)") : nil
            } else {
                matched = firstMatch(q, [("Title", issue.title), ("Repository", issue.repository), ("Author", issue.authorLogin)])
            }
            guard let (label, value) = matched else { return nil }
            // The web URL carries the owner the summary does not.
            let link = URL(string: issue.webUrl).flatMap { try? FleetMateLink.parseWeb($0) }
            return GlobalSearchResult(
                category: .issues, id: "issue-\(issue.id)",
                title: issue.title,
                subtitle: ["#\(issue.number)", issue.repository, issue.state].joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                link: link)
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func commits(_ q: String, _ repos: [RepositoryCommits]) -> [GlobalSearchResult] {
        let needle = q.trimmingCharacters(in: .whitespaces).lowercased()
        let looksLikeSHA = needle.count >= 7 && needle.allSatisfy(\.isHexDigit)
        var out: [GlobalSearchResult] = []
        for repo in repos {
            for commit in repo.commits {
                let matched: (String, String)?
                if looksLikeSHA {
                    matched = commit.id.lowercased().hasPrefix(needle) ? ("SHA", String(commit.id.prefix(10))) : nil
                } else {
                    matched = firstMatch(q, [("Message", commit.subject), ("Author", commit.authorName)])
                }
                guard let (label, value) = matched else { continue }
                let host: FleetMateLink.Host = repo.source == .gitHub
                    ? .gitHub(owner: repo.container, repo: repo.repository)
                    : .azureDevOps(project: repo.container, repo: repo.repository)
                out.append(GlobalSearchResult(
                    category: .commits, id: "commit-\(repo.id)-\(commit.id)",
                    title: commit.subject,
                    subtitle: [String(commit.id.prefix(7)), repo.displayName, commit.authorName ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    matchLabel: "\(label): \(value)",
                    link: .commit(host, sha: commit.id)))
                if out.count >= perCategoryLimit { return out }
            }
        }
        return out
    }

    private static func pipelineRuns(_ q: String, _ runs: [PipelineRun]) -> [GlobalSearchResult] {
        let wanted = number(q)
        return runs.compactMap { run -> GlobalSearchResult? in
            let matched: (String, String)?
            if let wanted {
                matched = run.runId == wanted ? ("Run", "\(run.runId)")
                    : (run.runNumber == "\(wanted)" ? ("Run number", run.runNumber) : nil)
            } else {
                matched = firstMatch(q, [
                    ("Pipeline", run.pipelineName), ("Run", run.runNumber),
                    ("Branch", run.branch), ("Repository", run.repository),
                ])
            }
            guard let (label, value) = matched else { return nil }
            let link: FleetMateLink = run.source == .gitHub
                ? .gitHubRun(owner: run.container, repo: run.repository ?? "", runId: run.runId)
                : .azureDevOpsRun(project: run.container, runId: run.runId)
            return GlobalSearchResult(
                category: .pipelines, id: "run-\(run.id)",
                title: "\(run.pipelineName) \(run.runNumber)",
                subtitle: [run.status.displayName, run.container, run.branch ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                matchLabel: "\(label): \(value)",
                link: link)
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func users(_ q: String, _ users: [EntraUser]) -> [GlobalSearchResult] {
        users.compactMap { user -> GlobalSearchResult? in
            guard let (label, value) = firstMatch(q, [
                ("Name", user.displayName),
                ("UPN", user.userPrincipalName)
            ]) else { return nil }
            return GlobalSearchResult(
                category: .users,
                id: "user-\(user.id ?? user.userPrincipalName ?? UUID().uuidString)",
                title: user.displayName ?? user.userPrincipalName ?? "(unnamed)",
                subtitle: user.userPrincipalName ?? "",
                matchLabel: "\(label): \(value)"
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }

    private static func groups(_ q: String, _ groups: [EntraGroup]) -> [GlobalSearchResult] {
        groups.compactMap { group -> GlobalSearchResult? in
            guard let name = group.displayName,
                  name.localizedCaseInsensitiveContains(q) else { return nil }
            return GlobalSearchResult(
                category: .groups,
                id: "group-\(group.id ?? name)",
                title: name,
                subtitle: group.id ?? "",
                matchLabel: "Group name"
            )
        }
        .prefix(perCategoryLimit).map { $0 }
    }
}

// MARK: - Field

/// The dashboard's global search box. `large` is the front-and-center hero
/// variant; the default is compact for toolbar-like placements.
struct GlobalSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var large: Bool = false

    var body: some View {
        HStack(spacing: large ? 8 : 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .appFont(large ? .title3 : .callout)
            TextField("Search everything — serial, hostname, user, ticket…", text: $query)
                .textFieldStyle(.plain)
                .appFont(large ? .title3 : .body)
                .focused(focused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .appFont(large ? .title3 : .body)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, large ? 14 : 10)
        .padding(.vertical, large ? 10 : 6)
        .modifier(SearchFieldChrome(large: large))
        .frame(maxWidth: large ? .infinity : 280)
    }
}

/// Glass on the hero variant (real Liquid Glass on macOS 26, material below),
/// the quiet tinted fill on the compact one.
private struct SearchFieldChrome: ViewModifier {
    let large: Bool

    func body(content: Content) -> some View {
        if large {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
        } else {
            content
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }
}

// MARK: - Results panel

/// Floating grouped results, anchored under the field — MunkiStudio-style:
/// a top-trailing overlay over a tap-to-dismiss backdrop, dismissal is simply
/// clearing the query.
struct GlobalSearchResultsPanel: View {
    let results: [GlobalSearchResult]
    var width: CGFloat = 420
    let onSelect: (GlobalSearchResult) -> Void

    private var grouped: [(GlobalSearchResult.Category, [GlobalSearchResult])] {
        GlobalSearchResult.Category.allCases.compactMap { category in
            let hits = results.filter { $0.category == category }
            return hits.isEmpty ? nil : (category, hits)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(grouped, id: \.0) { category, hits in
                    HStack(spacing: 6) {
                        Image(systemName: category.icon)
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(category.rawValue)
                            .appFont(.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(hits.count)")
                            .appFont(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    ForEach(hits) { hit in
                        resultRow(hit)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(width: width)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private func resultRow(_ hit: GlobalSearchResult) -> some View {
        Button {
            onSelect(hit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title)
                        .appFont(.callout, weight: .medium)
                        .lineLimit(1)
                    Spacer()
                    if !hit.subtitle.isEmpty {
                        Text(hit.subtitle)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(hit.matchLabel)
                    .appFont(.caption2, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
