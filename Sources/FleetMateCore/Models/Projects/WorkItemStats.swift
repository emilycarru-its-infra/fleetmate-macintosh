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
        let week = now.addingTimeInterval(-7 * 86_400)
        let staleCutoff = now.addingTimeInterval(-Double(Self.staleDays) * 86_400)
        for item in items {
            guard let f = item.fields else { continue }
            open += 1
            let state = (f.state ?? "").lowercased()
            if !state.isEmpty, state != "new", state != "to do", state != "proposed" { inProgress += 1 }
            if let created = Self.date(f.createdDate), created >= week { newThisWeek += 1 }
            let changed = Self.date(f.changedDate)
            if let changed, changed >= week { updatedThisWeek += 1 }
            if let changed, changed < staleCutoff { stale += 1 }
            if Self.isBlocked(f) { blocked += 1 }
            if let due = Self.date(f.dueDate), due < now { overdue += 1 }
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
