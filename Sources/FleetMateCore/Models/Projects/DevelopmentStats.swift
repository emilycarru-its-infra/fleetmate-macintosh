import Foundation

/// The figures behind the Development tab's per-segment graphs, computed from
/// what each segment has already loaded. Pure functions, so the app's charts
/// and the tests agree on every bucket.
public enum DevelopmentStats {
    public struct Count: Equatable, Sendable {
        public let label: String
        public let value: Int
        public init(label: String, value: Int) {
            self.label = label
            self.value = value
        }
    }

    /// Counts by key, most first, ties by name.
    public static func ranked<T>(_ items: [T], key: (T) -> String?) -> [Count] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let k = key(item), !k.isEmpty else { continue }
            counts[k, default: 0] += 1
        }
        return counts.map { Count(label: $0.key, value: $0.value) }
            .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    // MARK: Pull requests

    public static let ageBuckets = ["Today", "1–7 days", "8–30 days", "Over 30 days"]

    /// Open pull requests by how long ago they were opened. Every bucket is
    /// returned, empty ones included, so the bars keep their order.
    public static func pullRequestAges(_ pullRequests: [UnifiedPullRequest], now: Date = Date()) -> [Count] {
        var counts = Array(repeating: 0, count: ageBuckets.count)
        for pr in pullRequests {
            guard let created = pr.createdAt else { continue }
            let days = now.timeIntervalSince(created) / 86_400
            let index = days < 1 ? 0 : days <= 7 ? 1 : days <= 30 ? 2 : 3
            counts[index] += 1
        }
        return zip(ageBuckets, counts).map { Count(label: $0, value: $1) }
    }

    public enum ReviewStatus: String, CaseIterable, Sendable {
        case draft = "Draft"
        case conflicts = "Conflicts"
        case changesRequested = "Changes Requested"
        case approved = "Approved"
        case awaitingReview = "Awaiting Review"
    }

    /// One status per pull request, the first that applies in case order.
    public static func reviewStatus(_ pr: UnifiedPullRequest) -> ReviewStatus {
        if pr.state == .draft { return .draft }
        if pr.hasConflicts { return .conflicts }
        if pr.reviewers.contains(where: { $0.vote == .rejected || $0.vote == .waitingForAuthor }) { return .changesRequested }
        if pr.reviewers.contains(where: { $0.vote == .approved || $0.vote == .approvedWithSuggestions }) { return .approved }
        return .awaitingReview
    }

    public static func reviewStatuses(_ pullRequests: [UnifiedPullRequest]) -> [(status: ReviewStatus, count: Int)] {
        let statuses = pullRequests.map(reviewStatus)
        return ReviewStatus.allCases.compactMap { status in
            let n = statuses.filter { $0 == status }.count
            return n > 0 ? (status, n) : nil
        }
    }

    // MARK: Commits

    public struct DayCount: Equatable, Sendable {
        public let day: Date
        public let value: Int
    }

    /// One entry per calendar day for the last `days` days, oldest first,
    /// zero days included so the axis is continuous.
    public static func commitsPerDay(_ commits: [PullRequestCommit], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DayCount] {
        let today = calendar.startOfDay(for: now)
        var counts: [Date: Int] = [:]
        for commit in commits {
            guard let date = commit.date else { continue }
            counts[calendar.startOfDay(for: date), default: 0] += 1
        }
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DayCount(day: $0, value: counts[$0] ?? 0) }
        }
    }

    /// Counts by weekday, in the calendar's week order (Monday first where
    /// the week starts on Monday), every day present.
    public static func weekdays(_ dates: [Date], calendar: Calendar = .current) -> [Count] {
        var counts = Array(repeating: 0, count: 7)
        for date in dates { counts[calendar.component(.weekday, from: date) - 1] += 1 }
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { offset in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return Count(label: symbols[index], value: counts[index])
        }
    }

    /// One entry per week for the last `weeks` weeks, oldest first, keyed by
    /// the week's first day; empty weeks included.
    public static func perWeek(_ dates: [Date], weeks: Int, now: Date = Date(), calendar: Calendar = .current) -> [DayCount] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var counts: [Date: Int] = [:]
        for date in dates {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
            counts[start, default: 0] += 1
        }
        return (0..<weeks).reversed().compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek).map { DayCount(day: $0, value: counts[$0] ?? 0) }
        }
    }

    // MARK: Pipelines

    /// A run's result as the graphs group it: queued and running together,
    /// skipped and unknown with cancelled.
    public enum Outcome: String, CaseIterable, Sendable {
        case succeeded = "Succeeded"
        case failed = "Failed"
        case partial = "Partially succeeded"
        case cancelled = "Cancelled"
        case running = "Running"

        public init(_ status: PipelineRunStatus) {
            switch status {
            case .succeeded: self = .succeeded
            case .failed: self = .failed
            case .partial: self = .partial
            case .queued, .running: self = .running
            case .cancelled, .skipped, .unknown: self = .cancelled
            }
        }

        /// The list filter this outcome maps onto.
        public var filterStatus: PipelineRunStatus {
            switch self {
            case .succeeded: .succeeded
            case .failed: .failed
            case .partial: .partial
            case .cancelled: .cancelled
            case .running: .running
            }
        }
    }

    public static func outcomes(_ runs: [PipelineRun]) -> [(outcome: Outcome, count: Int)] {
        let all = runs.map { Outcome($0.status) }
        return Outcome.allCases.compactMap { outcome in
            let n = all.filter { $0 == outcome }.count
            return n > 0 ? (outcome, n) : nil
        }
    }

    /// Succeeded over every run that reached a verdict (succeeded, failed or
    /// partially succeeded); nil until one has.
    public static func successRate(_ runs: [PipelineRun]) -> Double? {
        let decided = runs.filter { [.succeeded, .failed, .partial].contains($0.status) }
        guard !decided.isEmpty else { return nil }
        return Double(decided.filter { $0.status == .succeeded }.count) / Double(decided.count)
    }

    public struct DayOutcome: Equatable, Sendable {
        public let day: Date
        public let outcome: Outcome
        public let value: Int
    }

    /// Runs started per day by outcome, oldest first; empty cells left out.
    public static func runsPerDay(_ runs: [PipelineRun], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DayOutcome] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var counts: [Date: [Outcome: Int]] = [:]
        for run in runs {
            guard let started = run.startedAt else { continue }
            let day = calendar.startOfDay(for: started)
            guard day >= first else { continue }
            counts[day, default: [:]][Outcome(run.status), default: 0] += 1
        }
        return counts.keys.sorted().flatMap { day in
            Outcome.allCases.compactMap { outcome in
                counts[day]?[outcome].map { DayOutcome(day: day, outcome: outcome, value: $0) }
            }
        }
    }

    /// Median wall-clock length of each pipeline's finished runs, slowest
    /// first.
    public static func medianDurations(_ runs: [PipelineRun]) -> [(pipeline: String, seconds: TimeInterval)] {
        var byName: [String: [TimeInterval]] = [:]
        for run in runs where run.finishedAt != nil && !run.status.isActive {
            guard let d = run.duration, d >= 0 else { continue }
            byName[run.pipelineName, default: []].append(d)
        }
        return byName.map { name, values in
            let sorted = values.sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            return (name, median)
        }
        .sorted { $0.seconds == $1.seconds ? $0.pipeline < $1.pipeline : $0.seconds > $1.seconds }
    }
}
