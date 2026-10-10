import Foundation

// MARK: - Raw history

/// One file a commit touched, from `git log --numstat`. Binary files report
/// no line counts.
public struct RepoFileChurn: Codable, Sendable, Hashable {
    public let path: String
    public let added: Int
    public let removed: Int
    public let isBinary: Bool

    public init(path: String, added: Int, removed: Int, isBinary: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
    }
}

/// One commit with the lines it changed per file.
public struct RepoChurnCommit: Codable, Sendable, Hashable {
    public let sha: String
    public let author: String
    public let email: String
    public let date: Date
    public let files: [RepoFileChurn]

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    public init(sha: String, author: String, email: String, date: Date, files: [RepoFileChurn]) {
        self.sha = sha
        self.author = author
        self.email = email
        self.date = date
        self.files = files
    }
}

extension GitOutputParser {
    /// Format for `git log --numstat`: a record separator, then sha, author
    /// (mailmap applied), email and Unix time separated by unit separators.
    /// The numstat lines follow each header.
    public static let churnLogFormat = "%x1e%H%x1f%aN%x1f%aE%x1f%at"

    /// Parses `git log --numstat --no-renames --format=<churnLogFormat>`.
    /// A numstat line is `added<TAB>removed<TAB>path`; a binary file has `-`
    /// for both counts. Malformed records are skipped, never guessed at.
    public static func churnLog(_ output: String) -> [RepoChurnCommit] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            var lines = record.split(separator: "\n", omittingEmptySubsequences: true)[...]
            guard let header = lines.popFirst() else { return nil }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty,
                  let seconds = TimeInterval(fields[3].trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            let files: [RepoFileChurn] = lines.compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[2].isEmpty else { return nil }
                if parts[0] == "-" && parts[1] == "-" {
                    return RepoFileChurn(path: String(parts[2]), added: 0, removed: 0, isBinary: true)
                }
                guard let added = Int(parts[0]), let removed = Int(parts[1]) else { return nil }
                return RepoFileChurn(path: String(parts[2]), added: added, removed: removed)
            }
            return RepoChurnCommit(
                sha: String(fields[0]),
                author: String(fields[1]),
                email: String(fields[2]),
                date: Date(timeIntervalSince1970: seconds),
                files: files
            )
        }
    }
}

extension GitWorkingCopy {
    /// Non-merge commits reachable from `ref` (default HEAD) since `since`,
    /// with per-file line counts. Renames are reported as a delete and an add
    /// so every path is a plain path. Read-only: no locks, no pathspecs.
    public func churnLog(since: Date? = nil, until: Date? = nil, ref: String? = nil, limit: Int = 20_000) async throws -> [RepoChurnCommit] {
        var args = [
            "-c", "core.quotepath=off",
            "log", "--no-merges", "--numstat", "--no-renames", "--no-color",
            "--format=\(GitOutputParser.churnLogFormat)",
            "-n", String(max(1, limit)),
        ]
        if let since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        if let until { args.append("--until=@\(Int(until.timeIntervalSince1970))") }
        if let ref {
            guard !ref.hasPrefix("-") else { throw RepoError.invalidArgument("'\(ref)' is not a valid ref.") }
            args.append(ref)
        }
        let result = await git(args, extraEnvironment: ["GIT_OPTIONAL_LOCKS": "0"])
        if !result.succeeded, result.stderr.contains("does not have any commits") { return [] }
        guard result.succeeded else { throw RepoError.gitFailed(command: "log", message: result.stderr.trimmed) }
        return GitOutputParser.churnLog(result.stdout)
    }

    /// When HEAD was last committed, or nil for an empty repository.
    public func lastCommitDate() async -> Date? {
        let result = await git(["log", "-1", "--format=%ct"], extraEnvironment: ["GIT_OPTIONAL_LOCKS": "0"])
        guard result.succeeded, let seconds = TimeInterval(result.stdout.trimmed) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Range

/// How finely a timeline is divided.
public enum RepoStatsBucket: String, Codable, Sendable, CaseIterable {
    case day, week, month

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// A bucket that gives a readable number of bars for a span of `days`.
    public static func automatic(forDays days: Int) -> RepoStatsBucket {
        switch days {
        case ..<45: .day
        case ..<400: .week
        default: .month
        }
    }
}

public enum RepoStatsRange {
    /// Parses a `--since` value: `30d`, `12w`, `6m`, `1y`, or an ISO date
    /// (`2026-01-31`). Relative values count back from `now`.
    public static func parseSince(_ value: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        if let unit = text.last, let count = Int(text.dropLast()), count > 0 {
            let component: Calendar.Component? = switch unit {
            case "d": .day
            case "w": .weekOfYear
            case "m": .month
            case "y": .year
            default: nil
            }
            if let component {
                return calendar.date(byAdding: component, value: -count, to: now).map { calendar.startOfDay(for: $0) }
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

// MARK: - Report

/// Statistics for one repository over a period: what agents read through
/// `fleetmate repos stats --json` and what the Insights view charts.
public struct RepoStatsReport: Codable, Sendable {
    public struct Totals: Codable, Sendable, Equatable {
        public var commits = 0
        public var authors = 0
        public var added = 0
        public var removed = 0
        public var filesTouched = 0
        public var firstCommit: Date?
        public var lastCommit: Date?
    }

    public struct TimelinePoint: Codable, Sendable, Hashable, Identifiable {
        /// Start of the bucket.
        public let start: Date
        public var commits: Int
        public var added: Int
        public var removed: Int
        public var id: Date { start }
    }

    public struct Contributor: Codable, Sendable, Hashable, Identifiable {
        public let name: String
        public var commits: Int
        public var added: Int
        public var removed: Int
        public var lastCommit: Date?
        public var id: String { name }
    }

    public struct PathActivity: Codable, Sendable, Hashable, Identifiable {
        public let path: String
        /// Commits that touched it.
        public var commits: Int
        public var added: Int
        public var removed: Int
        public var churn: Int { added + removed }
        public var id: String { path }
    }

    /// Commits by weekday (1 = Sunday, as `Calendar` numbers them) and hour.
    public struct ActivityCell: Codable, Sendable, Hashable, Identifiable {
        public let weekday: Int
        public let hour: Int
        public var commits: Int
        public var id: Int { weekday * 100 + hour }
    }

    public let since: Date?
    public let until: Date
    public let bucket: RepoStatsBucket
    public var totals: Totals
    public var timeline: [TimelinePoint]
    public var contributors: [Contributor]
    public var files: [PathActivity]
    /// Top-level folders (or root files) by activity.
    public var areas: [PathActivity]
    public var activity: [ActivityCell]
}

public enum RepoStatistics {
    /// Aggregates `commits` into a report. Commits outside `since...until`
    /// are ignored. The timeline has one point per bucket from the first
    /// bucket (of `since`, or the oldest commit) to the bucket of `until`,
    /// zero-filled so a quiet week shows as a gap, not a missing bar.
    public static func report(
        _ commits: [RepoChurnCommit],
        since: Date?,
        until: Date = Date(),
        bucket: RepoStatsBucket? = nil,
        top: Int = 15,
        calendar: Calendar = .current
    ) -> RepoStatsReport {
        let kept = commits.filter { commit in
            commit.date <= until && (since.map { commit.date >= $0 } ?? true)
        }
        let start = since ?? kept.map(\.date).min() ?? until
        let days = max(1, calendar.dateComponents([.day], from: start, to: until).day ?? 1)
        let bucket = bucket ?? .automatic(forDays: days)

        var totals = RepoStatsReport.Totals()
        var byBucket: [Date: RepoStatsReport.TimelinePoint] = [:]
        var byAuthor: [String: RepoStatsReport.Contributor] = [:]
        var byFile: [String: RepoStatsReport.PathActivity] = [:]
        var byArea: [String: RepoStatsReport.PathActivity] = [:]
        var byCell: [Int: RepoStatsReport.ActivityCell] = [:]

        for commit in kept {
            let added = commit.added
            let removed = commit.removed
            totals.commits += 1
            totals.added += added
            totals.removed += removed
            totals.firstCommit = min(totals.firstCommit ?? commit.date, commit.date)
            totals.lastCommit = max(totals.lastCommit ?? commit.date, commit.date)

            let key = bucketStart(commit.date, bucket, calendar)
            var point = byBucket[key] ?? .init(start: key, commits: 0, added: 0, removed: 0)
            point.commits += 1
            point.added += added
            point.removed += removed
            byBucket[key] = point

            let name = commit.author.isEmpty ? commit.email : commit.author
            var person = byAuthor[name] ?? .init(name: name, commits: 0, added: 0, removed: 0, lastCommit: nil)
            person.commits += 1
            person.added += added
            person.removed += removed
            person.lastCommit = max(person.lastCommit ?? commit.date, commit.date)
            byAuthor[name] = person

            var areasThisCommit = Set<String>()
            for file in commit.files {
                var entry = byFile[file.path] ?? .init(path: file.path, commits: 0, added: 0, removed: 0)
                entry.commits += 1
                entry.added += file.added
                entry.removed += file.removed
                byFile[file.path] = entry

                let area = self.area(of: file.path)
                var areaEntry = byArea[area] ?? .init(path: area, commits: 0, added: 0, removed: 0)
                if areasThisCommit.insert(area).inserted { areaEntry.commits += 1 }
                areaEntry.added += file.added
                areaEntry.removed += file.removed
                byArea[area] = areaEntry
            }

            let parts = calendar.dateComponents([.weekday, .hour], from: commit.date)
            let weekday = parts.weekday ?? 1
            let hour = parts.hour ?? 0
            var cell = byCell[weekday * 100 + hour] ?? .init(weekday: weekday, hour: hour, commits: 0)
            cell.commits += 1
            byCell[cell.id] = cell
        }
        totals.authors = byAuthor.count
        totals.filesTouched = byFile.count

        var timeline: [RepoStatsReport.TimelinePoint] = []
        var cursor = bucketStart(start, bucket, calendar)
        let last = bucketStart(until, bucket, calendar)
        // A guard against a pathological range: ten years of days.
        while cursor <= last, timeline.count < 3700 {
            timeline.append(byBucket[cursor] ?? .init(start: cursor, commits: 0, added: 0, removed: 0))
            guard let next = calendar.date(byAdding: bucket.component, value: 1, to: cursor) else { break }
            cursor = next
        }

        let byActivity: (RepoStatsReport.PathActivity, RepoStatsReport.PathActivity) -> Bool = {
            $0.commits != $1.commits ? $0.commits > $1.commits
                : $0.churn != $1.churn ? $0.churn > $1.churn
                : $0.path < $1.path
        }
        return RepoStatsReport(
            since: since,
            until: until,
            bucket: bucket,
            totals: totals,
            timeline: timeline,
            contributors: byAuthor.values.sorted {
                $0.commits != $1.commits ? $0.commits > $1.commits : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            files: Array(byFile.values.sorted(by: byActivity).prefix(top)),
            areas: Array(byArea.values.sorted(by: byActivity).prefix(top)),
            activity: byCell.values.sorted { $0.id < $1.id }
        )
    }

    /// The top-level folder a path belongs to; a file at the root is its own area.
    public static func area(of path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return path }
        return String(path[..<slash]) + "/"
    }

    static func bucketStart(_ date: Date, _ bucket: RepoStatsBucket, _ calendar: Calendar) -> Date {
        switch bucket {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}

// MARK: - Across repositories

/// One repository's line in the cross-repository summary.
public struct RepoStatsSummaryRow: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let commits: Int
    public let authors: Int
    public let added: Int
    public let removed: Int
    public let lastCommit: Date?
    public let branch: String?
    public let ahead: Int
    public let behind: Int
    /// Staged, unstaged and untracked paths.
    public let openChanges: Int
    public let error: String?
    /// Commits per bucket, aligned with the summary's `bucketStarts`.
    public let timeline: [Int]
}

/// Every tracked repository over one period, for `fleetmate repos stats`
/// with no repository named and for the Insights view's All Repositories scope.
public struct RepoStatsSummary: Codable, Sendable {
    public let since: Date?
    public let until: Date
    public let bucket: RepoStatsBucket
    public let bucketStarts: [Date]
    public let rows: [RepoStatsSummaryRow]
    public let combined: RepoStatsReport

    /// Builds the summary from each repository's commits and status. Rows are
    /// ordered by commits in the period, then name.
    public static func build(
        _ inputs: [(id: String, displayName: String, commits: [RepoChurnCommit], status: RepoStatus?, error: String?)],
        since: Date?,
        until: Date = Date(),
        bucket: RepoStatsBucket? = nil,
        top: Int = 15,
        calendar: Calendar = .current
    ) -> RepoStatsSummary {
        let combined = RepoStatistics.report(inputs.flatMap(\.commits), since: since, until: until, bucket: bucket, top: top, calendar: calendar)
        let starts = combined.timeline.map(\.start)
        let index = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($1, $0) })
        let rows = inputs.map { input -> RepoStatsSummaryRow in
            let report = RepoStatistics.report(input.commits, since: combined.since ?? starts.first, until: until, bucket: combined.bucket, top: 0, calendar: calendar)
            var counts = Array(repeating: 0, count: starts.count)
            for point in report.timeline {
                if let i = index[point.start] { counts[i] = point.commits }
            }
            let status = input.status
            return RepoStatsSummaryRow(
                id: input.id,
                displayName: input.displayName,
                commits: report.totals.commits,
                authors: report.totals.authors,
                added: report.totals.added,
                removed: report.totals.removed,
                lastCommit: input.commits.map(\.date).max() ?? status?.lastCommitAt,
                branch: status?.branch,
                ahead: status?.ahead ?? 0,
                behind: status?.behind ?? 0,
                openChanges: (status?.staged ?? 0) + (status?.unstaged ?? 0) + (status?.untracked ?? 0),
                error: input.error ?? status?.error,
                timeline: counts
            )
        }
        .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return RepoStatsSummary(since: since, until: until, bucket: combined.bucket, bucketStarts: starts, rows: rows, combined: combined)
    }
}

extension RepoManager {
    /// One repository's statistics over a period.
    public func stats(for record: RepoRecord, since: Date?, until: Date = Date(), bucket: RepoStatsBucket? = nil, top: Int = 15) async throws -> RepoStatsReport {
        let commits = try await workingCopy(for: record).churnLog(since: since, until: until)
        return RepoStatistics.report(commits, since: since, until: until, bucket: bucket, top: top)
    }

    /// Statistics across `records`, `settings.concurrency` at a time. A
    /// repository that fails to read becomes a row with its error; it never
    /// hides the others.
    public func statsSummary(for records: [RepoRecord], since: Date?, until: Date = Date(), bucket: RepoStatsBucket? = nil, top: Int = 15) async -> RepoStatsSummary {
        let limit = (try? settings().concurrency) ?? RepoSettings.default.concurrency
        let manager = self
        struct Loaded: Sendable {
            let id: String
            let name: String
            let commits: [RepoChurnCommit]
            let status: RepoStatus
            let error: String?
        }
        let loaded = await boundedMap(records, limit: limit) { record -> Loaded in
            let status = await manager.status(for: record)
            do {
                let commits = try await manager.workingCopy(for: record).churnLog(since: since, until: until)
                return Loaded(id: record.id, name: record.key.displayName, commits: commits, status: status, error: nil)
            } catch {
                return Loaded(id: record.id, name: record.key.displayName, commits: [], status: status, error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        return RepoStatsSummary.build(
            loaded.map { (id: $0.id, displayName: $0.name, commits: $0.commits, status: $0.status, error: $0.error) },
            since: since, until: until, bucket: bucket, top: top
        )
    }
}
