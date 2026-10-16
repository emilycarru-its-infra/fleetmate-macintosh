import Foundation

/// Display transforms only; reports and hover values retain the original line counts.
public enum RepoChurnScale: String, CaseIterable, Sendable {
    case automatic, linear, compressed

    public static func recommended(for points: [RepoStatsReport.TimelinePoint]) -> Self {
        let magnitudes = points.flatMap { [$0.added, $0.removed] }.filter { $0 > 0 }.sorted()
        guard let peak = magnitudes.last, peak >= 10_000 else { return .linear }
        let middle = magnitudes.count / 2
        let median = magnitudes.count.isMultiple(of: 2)
            ? (Double(magnitudes[middle - 1]) + Double(magnitudes[middle])) / 2
            : Double(magnitudes[middle])
        return Double(peak) / median >= 100 ? .compressed : .linear
    }

    /// At most three decades per side, spaced away from zero on a tall-range chart.
    public static func tickMagnitudes(peak: Int) -> [Int] {
        let largestExponent = Int(log10(Double(max(peak, 1))).rounded(.down))
        let exponents = Set((1...3).map { Int(ceil(Double(largestExponent) * Double($0) / 3)) })
        return exponents.sorted().map { Int(pow(10, Double($0))) }
    }

    public func position(_ value: Int) -> Double {
        guard self == .compressed else { return Double(value) }
        let magnitude = log10(1 + abs(Double(value)))
        return value < 0 ? -magnitude : magnitude
    }
}

extension RepoStatsReport.ActivityCell {
    /// A complete matrix keeps quiet hours visible and gives hover an exact zero count.
    public static func grid(_ cells: [Self]) -> [Self] {
        let counts = Dictionary(cells.map { ($0.id, $0.commits) }, uniquingKeysWith: +)
        return (1...7).flatMap { weekday in
            (0..<24).map { hour in
                Self(weekday: weekday, hour: hour, commits: counts[weekday * 100 + hour] ?? 0)
            }
        }
    }
}
