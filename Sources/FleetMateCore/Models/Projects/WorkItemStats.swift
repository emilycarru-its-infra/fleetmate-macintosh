import Foundation

/// The figures behind the Projects strip's tiles, from the signed-in user's
/// open work items as already loaded — no queries of their own.
public struct WorkItemStats: Equatable, Sendable {
    public var open = 0
    /// In a state other than New (Active, In Progress, Committed, …).
    public var inProgress = 0
    public var newThisWeek = 0
    public var updatedThisWeek = 0
    /// Tagged or on a board column named Blocked, or in a Blocked state.
    public var blocked = 0
    public var overdue = 0
    /// No change in 30 days.
    public var stale = 0

    public static let staleDays = 30

    public init(_ items: [WorkItem], now: Date = Date()) {
        for item in items {
            guard item.fields != nil else { continue }
            open += 1
            if WorkItemTile.inProgress.matches(item, now: now) { inProgress += 1 }
            if WorkItemTile.newThisWeek.matches(item, now: now) { newThisWeek += 1 }
            if WorkItemTile.updatedThisWeek.matches(item, now: now) { updatedThisWeek += 1 }
            if WorkItemTile.stale.matches(item, now: now) { stale += 1 }
            if WorkItemTile.blocked.matches(item, now: now) { blocked += 1 }
            if WorkItemTile.overdue.matches(item, now: now) { overdue += 1 }
        }
    }

    public static func isBlocked(_ f: WorkItemFields) -> Bool {
        let tags = (f.tags ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return tags.contains("blocked")
            || (f.state ?? "").lowercased().contains("blocked")
            || (f.boardColumn ?? "").lowercased().contains("blocked")
    }

    /// Counts by a field, most first; items without the field are left out.
    public static func ranked(_ items: [WorkItem], by key: (WorkItemFields) -> String?) -> [DevelopmentStats.Count] {
        DevelopmentStats.ranked(items) { $0.fields.flatMap(key) }
    }

    /// Azure DevOps dates come with and without fractional seconds.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// One of the Projects strip's tiles, as a filter: the set of the signed-in
/// user's work items the tile counts. The tile figure and the filtered list
/// use the same test, so they always agree.
public enum WorkItemTile: String, CaseIterable, Sendable, Identifiable {
    case assignedToMe, inProgress, newThisWeek, updatedThisWeek, blocked, overdue, stale, gitHubIssues

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .assignedToMe: "Assigned to Me"
        case .inProgress: "In Progress"
        case .newThisWeek: "New This Week"
        case .updatedThisWeek: "Updated This Week"
        case .blocked: "Blocked"
        case .overdue: "Overdue"
        case .stale: "No Change in \(WorkItemStats.staleDays) Days"
        case .gitHubIssues: "GitHub Issues"
        }
    }

    /// Whether the work item is in this tile's set. GitHub issues are not
    /// work items, so that tile matches none.
    public func matches(_ item: WorkItem, now: Date = Date()) -> Bool {
        guard let f = item.fields else { return false }
        let week = now.addingTimeInterval(-7 * 86_400)
        switch self {
        case .assignedToMe:
            return true
        case .inProgress:
            let state = (f.state ?? "").lowercased()
            return !state.isEmpty && state != "new" && state != "to do" && state != "proposed"
        case .newThisWeek:
            return WorkItemStats.date(f.createdDate).map { $0 >= week } ?? false
        case .updatedThisWeek:
            return WorkItemStats.date(f.changedDate).map { $0 >= week } ?? false
        case .stale:
            let cutoff = now.addingTimeInterval(-Double(WorkItemStats.staleDays) * 86_400)
            return WorkItemStats.date(f.changedDate).map { $0 < cutoff } ?? false
        case .blocked:
            return WorkItemStats.isBlocked(f)
        case .overdue:
            return WorkItemStats.date(f.dueDate).map { $0 < now } ?? false
        case .gitHubIssues:
            return false
        }
    }
}
