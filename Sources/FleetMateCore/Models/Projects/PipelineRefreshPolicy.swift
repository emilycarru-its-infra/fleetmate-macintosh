import Foundation

/// Metadata refresh stays bounded even when pipelines run continuously.
public struct PipelineRefreshPolicy: Sendable {
    public private(set) var checkedAt: Date?
    public private(set) var discoveredAt: Date?
    public private(set) var failures = 0

    public init() {}

    public func isDue(now: Date, visible: Bool, activeRuns: Bool) -> Bool {
        guard let checkedAt else { return true }
        let cadence: TimeInterval = visible && activeRuns ? 15 : 60
        let delay = failures == 0 ? cadence : min(300, cadence * pow(2, Double(failures)))
        return now.timeIntervalSince(checkedAt) >= delay
    }

    public func needsDiscovery(now: Date) -> Bool {
        discoveredAt.map { now.timeIntervalSince($0) >= 900 } ?? true
    }

    public mutating func finish(now: Date, succeeded: Bool, discovery: Bool) {
        checkedAt = now
        failures = succeeded ? 0 : min(failures + 1, 5)
        if succeeded && discovery { discoveredAt = now }
    }

    /// Merge metadata by run identity, preserving failed/unqueried scopes.
    public static func merge(_ existing: [PipelineRun], updates: [PipelineRun], now: Date, limit: Int = 500) -> [PipelineRun] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for run in updates { byID[run.id] = run }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let sorted = byID.values.filter { $0.status.isActive || $0.sortDate >= cutoff }
            .sorted { $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate }
        let active = Array(sorted.filter { $0.status.isActive }.prefix(limit))
        return (active + sorted.filter { !$0.status.isActive }.prefix(max(0, limit - active.count)))
            .sorted { $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate }
    }
}
