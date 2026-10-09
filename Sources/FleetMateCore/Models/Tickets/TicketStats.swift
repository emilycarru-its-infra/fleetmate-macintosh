import Foundation

/// The figures behind the Tickets widgets, computed from whichever tickets the
/// list is showing, so every widget follows the current filters and search.
public struct TicketStats: Equatable, Sendable {
    public struct Count: Equatable, Sendable {
        public let label: String
        public let value: Int
    }

    /// Tickets older than this many days count as aging: the oldest age band.
    public static let agingDays = 30
    /// Responsible people and groups beyond this many are left off the bars.
    public static let topCount = 6
    public static let unassigned = "Unassigned"

    public let total: Int
    public let open: Int
    public let onHold: Int
    public let unassigned: Int
    public let slaViolated: Int
    public let aging: Int
    public let byStatus: [Count]
    public let byPriority: [Count]
    public let byAge: [Count]
    public let byResponsible: [Count]
    public let byGroup: [Count]

    private static let closedStatuses: Set<String> = ["closed", "cancelled", "canceled", "resolved", "completed"]
    private static let priorityOrder = ["Low": 0, "Medium": 1, "High": 2, "Emergency": 3]

    public init(tickets: [TdxTicket]) {
        let active = tickets.filter { !Self.isClosed($0) }
        total = tickets.count
        onHold = active.filter { $0.isOnHold == true }.count
        open = active.count - onHold
        unassigned = active.filter { Self.isBlank($0.responsibleFullName) }.count
        slaViolated = tickets.filter { $0.slaViolated == true }.count
        aging = active.filter { ($0.ageInDays ?? 0) > Self.agingDays }.count

        byStatus = Self.counts(tickets) { $0.statusName ?? "None" }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.label < $1.label }
        byPriority = Self.counts(active) { $0.priorityName ?? "None" }
            .sorted { (Self.priorityOrder[$0.label] ?? 99, $0.label) < (Self.priorityOrder[$1.label] ?? 99, $1.label) }

        byAge = Self.ageBuckets.compactMap { label, _ in
            let n = active.filter { Self.ageBucket(for: $0) == label }.count
            return n > 0 ? Count(label: label, value: n) : nil
        }

        byResponsible = Self.top(Self.counts(active) { Self.isBlank($0.responsibleFullName) ? Self.unassigned : $0.responsibleFullName! })
        byGroup = Self.top(Self.counts(active) { Self.isBlank($0.responsibleGroupName) ? Self.unassigned : $0.responsibleGroupName! })
    }

    /// Age bands, youngest first. The labels double as filter values.
    public static let ageBuckets: [(label: String, days: ClosedRange<Int>)] = [
        ("Today", 0...0), ("1–7 days", 1...7), ("8–30 days", 8...30), ("Over 30 days", 31...Int.max),
    ]

    /// The age band a ticket falls in.
    public static func ageBucket(for ticket: TdxTicket) -> String {
        let days = max(ticket.ageInDays ?? 0, 0)
        return ageBuckets.first { $0.days.contains(days) }?.label ?? ageBuckets[0].label
    }

    private static func isClosed(_ t: TdxTicket) -> Bool {
        guard let s = t.statusName?.lowercased() else { return false }
        return closedStatuses.contains(s)
    }

    private static func isBlank(_ s: String?) -> Bool {
        (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func counts(_ tickets: [TdxTicket], by key: (TdxTicket) -> String) -> [Count] {
        Dictionary(grouping: tickets, by: key).map { Count(label: $0.key, value: $0.value.count) }
    }

    private static func top(_ counts: [Count]) -> [Count] {
        Array(counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.label < $1.label }.prefix(topCount))
    }
}
