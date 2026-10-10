import XCTest
@testable import FleetMateCore

final class RepoChurnLogParserTests: XCTestCase {

    func testParsesHeadersAndNumstatLines() {
        let output = """
        \u{1e}aaa111\u{1f}Ada Example\u{1f}ada@example.com\u{1f}1767225600

        10\t2\tSources/App/main.swift
        -\t-\tAssets/logo.png
        0\t5\tREADME.md
        \u{1e}bbb222\u{1f}Grace Example\u{1f}grace@example.com\u{1f}1767312000

        3\t0\tdocs/guide with spaces.md

        """
        let commits = GitOutputParser.churnLog(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, "aaa111")
        XCTAssertEqual(commits[0].author, "Ada Example")
        XCTAssertEqual(commits[0].email, "ada@example.com")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(commits[0].files.map(\.path), ["Sources/App/main.swift", "Assets/logo.png", "README.md"])
        XCTAssertEqual(commits[0].added, 10)
        XCTAssertEqual(commits[0].removed, 7)
        XCTAssertTrue(commits[0].files[1].isBinary)
        XCTAssertEqual(commits[1].files.first?.path, "docs/guide with spaces.md")
    }

    func testCommitWithNoFilesStillCounts() {
        let output = "\u{1e}ccc333\u{1f}Ada Example\u{1f}ada@example.com\u{1f}1767225600\n"
        let commits = GitOutputParser.churnLog(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].files.isEmpty)
    }

    func testSkipsMalformedHeadersAndLines() {
        let output = """
        \u{1e}broken header
        1\t1\ta.txt
        \u{1e}ddd444\u{1f}Ada\u{1f}ada@example.com\u{1f}not-a-time
        \u{1e}eee555\u{1f}Ada\u{1f}ada@example.com\u{1f}1767225600
        x\t1\tbad.txt
        4\t1\tgood.txt
        """
        let commits = GitOutputParser.churnLog(output)
        XCTAssertEqual(commits.map(\.sha), ["eee555"])
        XCTAssertEqual(commits[0].files.map(\.path), ["good.txt"])
    }

    func testEmptyOutputIsNoCommits() {
        XCTAssertTrue(GitOutputParser.churnLog("").isEmpty)
    }
}

final class RepoStatisticsTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private func commit(_ sha: String, _ author: String, _ when: String, _ files: [(String, Int, Int)]) -> RepoChurnCommit {
        RepoChurnCommit(
            sha: sha,
            author: author,
            email: "\(author.lowercased())@example.com",
            date: date(when),
            files: files.map { RepoFileChurn(path: $0.0, added: $0.1, removed: $0.2) }
        )
    }

    private var sample: [RepoChurnCommit] {
        [
            commit("1", "Ada", "2026-01-05T10:00:00Z", [("Sources/a.swift", 10, 0), ("README.md", 1, 1)]),
            commit("2", "Ada", "2026-01-06T15:30:00Z", [("Sources/a.swift", 5, 2), ("Sources/b.swift", 3, 0)]),
            commit("3", "Grace", "2026-01-20T09:00:00Z", [("Tests/aTests.swift", 20, 0)]),
            commit("4", "Grace", "2025-12-01T09:00:00Z", [("old.txt", 1, 0)]),
        ]
    }

    func testTotalsCountOnlyTheRange() {
        let report = RepoStatistics.report(sample, since: date("2026-01-01T00:00:00Z"), until: date("2026-01-31T00:00:00Z"), bucket: .week, calendar: calendar)
        XCTAssertEqual(report.totals.commits, 3)
        XCTAssertEqual(report.totals.authors, 2)
        XCTAssertEqual(report.totals.added, 39)
        XCTAssertEqual(report.totals.removed, 3)
        XCTAssertEqual(report.totals.filesTouched, 4)
        XCTAssertEqual(report.totals.firstCommit, date("2026-01-05T10:00:00Z"))
        XCTAssertEqual(report.totals.lastCommit, date("2026-01-20T09:00:00Z"))
    }

    func testWeeklyTimelineIsZeroFilledAndContiguous() {
        let report = RepoStatistics.report(sample, since: date("2026-01-01T00:00:00Z"), until: date("2026-01-31T00:00:00Z"), bucket: .week, calendar: calendar)
        // Weeks start on Sunday: Dec 28, Jan 4, 11, 18, 25.
        XCTAssertEqual(report.timeline.map(\.start), [
            date("2025-12-28T00:00:00Z"), date("2026-01-04T00:00:00Z"), date("2026-01-11T00:00:00Z"),
            date("2026-01-18T00:00:00Z"), date("2026-01-25T00:00:00Z"),
        ])
        XCTAssertEqual(report.timeline.map(\.commits), [0, 2, 0, 1, 0])
        XCTAssertEqual(report.timeline[1].added, 19)
        XCTAssertEqual(report.timeline[1].removed, 3)
    }

    func testDailyTimelineHasOnePointPerDay() {
        let report = RepoStatistics.report(sample, since: date("2026-01-05T00:00:00Z"), until: date("2026-01-07T12:00:00Z"), bucket: .day, calendar: calendar)
        XCTAssertEqual(report.timeline.map(\.commits), [1, 1, 0])
    }

    func testMonthlyTimeline() {
        let report = RepoStatistics.report(sample, since: nil, until: date("2026-01-31T00:00:00Z"), bucket: .month, calendar: calendar)
        XCTAssertEqual(report.timeline.map(\.start), [date("2025-12-01T00:00:00Z"), date("2026-01-01T00:00:00Z")])
        XCTAssertEqual(report.timeline.map(\.commits), [1, 3])
    }

    func testAutomaticBucketFollowsThePeriodLength() {
        XCTAssertEqual(RepoStatsBucket.automatic(forDays: 14), .day)
        XCTAssertEqual(RepoStatsBucket.automatic(forDays: 90), .week)
        XCTAssertEqual(RepoStatsBucket.automatic(forDays: 365), .week)
        XCTAssertEqual(RepoStatsBucket.automatic(forDays: 900), .month)
        let report = RepoStatistics.report(sample, since: date("2026-01-01T00:00:00Z"), until: date("2026-01-10T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(report.bucket, .day)
    }

    func testContributorsByCommitsThenName() {
        let report = RepoStatistics.report(sample, since: nil, until: date("2026-01-31T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(report.contributors.map(\.name), ["Ada", "Grace"])
        XCTAssertEqual(report.contributors[0].added, 19)
        XCTAssertEqual(report.contributors[1].commits, 2)
        XCTAssertEqual(report.contributors[1].lastCommit, date("2026-01-20T09:00:00Z"))
    }

    func testFilesAndAreasRankByCommitsThenChurn() {
        let report = RepoStatistics.report(sample, since: date("2026-01-01T00:00:00Z"), until: date("2026-01-31T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(report.files.first?.path, "Sources/a.swift")
        XCTAssertEqual(report.files.first?.commits, 2)
        XCTAssertEqual(report.files.first?.churn, 17)
        // Sources/ is touched by two commits; two files in one commit count once.
        XCTAssertEqual(report.areas.map(\.path), ["Sources/", "Tests/", "README.md"])
        XCTAssertEqual(report.areas[0].commits, 2)
        XCTAssertEqual(report.areas[0].added, 18)
    }

    func testTopLimitsFilesAndAreas() {
        let report = RepoStatistics.report(sample, since: nil, until: date("2026-01-31T00:00:00Z"), top: 1, calendar: calendar)
        XCTAssertEqual(report.files.count, 1)
        XCTAssertEqual(report.areas.count, 1)
    }

    func testActivityByWeekdayAndHour() {
        let report = RepoStatistics.report(sample, since: date("2026-01-01T00:00:00Z"), until: date("2026-01-31T00:00:00Z"), calendar: calendar)
        // Jan 5 2026 is a Monday (2), Jan 6 a Tuesday (3), Jan 20 a Tuesday.
        XCTAssertEqual(report.activity.map { [$0.weekday, $0.hour, $0.commits] }, [[2, 10, 1], [3, 9, 1], [3, 15, 1]])
    }

    func testEmptyHistoryGivesAZeroTimeline() {
        let report = RepoStatistics.report([], since: date("2026-01-01T00:00:00Z"), until: date("2026-01-03T00:00:00Z"), bucket: .day, calendar: calendar)
        XCTAssertEqual(report.totals, RepoStatsReport.Totals())
        XCTAssertEqual(report.timeline.map(\.commits), [0, 0, 0])
    }

    func testAreaOfPath() {
        XCTAssertEqual(RepoStatistics.area(of: "Sources/App/main.swift"), "Sources/")
        XCTAssertEqual(RepoStatistics.area(of: "README.md"), "README.md")
    }

    func testSummaryAlignsEachRepositoryWithTheCombinedTimeline() {
        let since = date("2026-01-01T00:00:00Z")
        let until = date("2026-01-31T00:00:00Z")
        let summary = RepoStatsSummary.build(
            [
                (id: "github:example/one", displayName: "example/one", commits: Array(sample.prefix(2)), status: nil, error: nil),
                (id: "github:example/two", displayName: "example/two", commits: [sample[2]], status: nil, error: nil),
                (id: "github:example/empty", displayName: "example/empty", commits: [], status: nil, error: "checkout missing"),
            ],
            since: since, until: until, bucket: .week, calendar: calendar
        )
        XCTAssertEqual(summary.bucketStarts.count, 5)
        XCTAssertEqual(summary.rows.map(\.displayName), ["example/one", "example/two", "example/empty"])
        XCTAssertEqual(summary.rows[0].timeline, [0, 2, 0, 0, 0])
        XCTAssertEqual(summary.rows[1].timeline, [0, 0, 0, 1, 0])
        XCTAssertEqual(summary.rows[2].error, "checkout missing")
        XCTAssertEqual(summary.combined.totals.commits, 3)
    }
}

final class RepoStatsRangeTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = ISO8601DateFormatter().date(from: "2026-03-15T12:00:00Z")!

    func testRelativePeriodsStartAtMidnight() {
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(RepoStatsRange.parseSince("30d", now: now, calendar: calendar), iso.date(from: "2026-02-13T00:00:00Z"))
        XCTAssertEqual(RepoStatsRange.parseSince("2w", now: now, calendar: calendar), iso.date(from: "2026-03-01T00:00:00Z"))
        XCTAssertEqual(RepoStatsRange.parseSince("6M", now: now, calendar: calendar), iso.date(from: "2025-09-15T00:00:00Z"))
        XCTAssertEqual(RepoStatsRange.parseSince("1y", now: now, calendar: calendar), iso.date(from: "2025-03-15T00:00:00Z"))
    }

    func testAbsoluteDate() {
        XCTAssertEqual(RepoStatsRange.parseSince("2026-01-31", now: now, calendar: calendar), ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z"))
    }

    func testRejectsNonsense() {
        XCTAssertNil(RepoStatsRange.parseSince("", now: now, calendar: calendar))
        XCTAssertNil(RepoStatsRange.parseSince("0d", now: now, calendar: calendar))
        XCTAssertNil(RepoStatsRange.parseSince("10x", now: now, calendar: calendar))
        XCTAssertNil(RepoStatsRange.parseSince("yesterday", now: now, calendar: calendar))
    }
}

final class RepoSidebarOrganizerTests: XCTestCase {

    private func record(_ provider: RepoProvider, _ owner: String, _ project: String?, _ name: String) -> RepoRecord {
        let key = RepoKey(provider: provider, owner: owner, project: project, name: name)
        return RepoRecord(key: key, catalog: nil, local: RepoRegistryEntry(key: key, path: "/tmp/checkouts/\(name)", tracked: true))
    }

    private func status(_ record: RepoRecord, behind: Int = 0, changes: Int = 0, last: TimeInterval? = nil) -> RepoStatus {
        let snapshot = GitStatusSnapshot(
            branch: "main",
            behind: behind,
            changes: (0..<changes).map { RepoFileChange(path: "f\($0)", kind: .untracked, indexStatus: "?", worktreeStatus: "?") }
        )
        return RepoStatus(id: record.id, displayName: record.key.displayName, path: "/tmp", snapshot: snapshot, worktrees: [], agentsFile: nil, lastCommitAt: last.map(Date.init(timeIntervalSince1970:)), error: nil)
    }

    private lazy var records = [
        record(.gitHub, "acme", nil, "zeta"),
        record(.azureDevOps, "org", "Devices", "beta"),
        record(.gitHub, "acme", nil, "alpha"),
        record(.azureDevOps, "org", "Apps", "gamma"),
        record(.azureDevOps, "org", "Devices", "alpha"),
        record(.gitHub, "other", nil, "tool"),
    ]

    func testSectionsNestHostThenScope() {
        let sections = RepoSidebarOrganizer.sections(records, statuses: [:], sort: .name)
        XCTAssertEqual(sections.map(\.title), ["Azure DevOps", "GitHub"])
        XCTAssertEqual(sections[0].groups.map(\.scope), ["Apps", "Devices"])
        XCTAssertEqual(sections[0].groups[1].records.map(\.key.name), ["alpha", "beta"])
        XCTAssertEqual(sections[1].groups.map(\.scope), ["acme", "other"])
        XCTAssertEqual(sections[0].repositoryCount, 3)
    }

    func testSortsWithinGroupsByChosenKey() {
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.key.name + ($0.key.project ?? ""), $0) })
        let statuses = [
            byId["alphaDevices"]!.id: status(byId["alphaDevices"]!, behind: 1, changes: 0, last: 100),
            byId["betaDevices"]!.id: status(byId["betaDevices"]!, behind: 5, changes: 3, last: 50),
        ]
        func devices(_ sort: RepoSidebarSort) -> [String] {
            RepoSidebarOrganizer.sections(records, statuses: statuses, sort: sort)[0].groups[1].records.map(\.key.name)
        }
        XCTAssertEqual(devices(.name), ["alpha", "beta"])
        XCTAssertEqual(devices(.recentlyChanged), ["alpha", "beta"])
        XCTAssertEqual(devices(.mostChanges), ["beta", "alpha"])
        XCTAssertEqual(devices(.mostBehind), ["beta", "alpha"])
    }

    func testRepositoriesWithoutStatusFallBackToName() {
        let flat = RepoSidebarOrganizer.flat(records, statuses: [:], sort: .mostBehind)
        XCTAssertEqual(flat.map(\.key.name), ["alpha", "alpha", "beta", "gamma", "tool", "zeta"])
    }

    func testFilterDropsEmptyGroupsAndSections() {
        let sections = RepoSidebarOrganizer.sections(records, statuses: [:], sort: .name, matching: "TOOL")
        XCTAssertEqual(sections.map(\.title), ["GitHub"])
        XCTAssertEqual(sections[0].groups.map(\.scope), ["other"])
    }
}
