import XCTest
@testable import FleetMateCore

final class DevelopmentStatsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func pr(daysOld: Double, state: PullRequestState = .open, conflicts: Bool = false,
                    votes: [PullRequestReviewVote] = []) -> UnifiedPullRequest {
        UnifiedPullRequest(
            source: .gitHub, number: Int.random(in: 1...99_999), title: "t", authorName: "a",
            container: "o", repository: "r", sourceBranch: "s", targetBranch: "main",
            createdAt: now.addingTimeInterval(-daysOld * 86_400), updatedAt: nil, state: state,
            hasConflicts: conflicts,
            reviewers: votes.enumerated().map { PullRequestReviewer(id: "\($0.offset)", displayName: "R", vote: $0.element) },
            webUrl: ""
        )
    }

    private func run(_ status: PipelineRunStatus, name: String = "build", startedHoursAgo: Double = 1, minutes: Double? = 5) -> PipelineRun {
        let start = now.addingTimeInterval(-startedHoursAgo * 3600)
        return PipelineRun(
            source: .azureDevOps, container: "p", repository: "r", pipelineName: name, pipelineId: 1,
            runId: Int.random(in: 1...999_999), runNumber: "1", status: status, branch: nil, commitSha: nil,
            triggeredBy: nil, startedAt: start, finishedAt: minutes.map { start.addingTimeInterval($0 * 60) }, webUrl: ""
        )
    }

    func testPullRequestAgesKeepEveryBucketInOrder() {
        let ages = DevelopmentStats.pullRequestAges([pr(daysOld: 0.5), pr(daysOld: 3), pr(daysOld: 40), pr(daysOld: 41)], now: now)
        XCTAssertEqual(ages.map(\.label), DevelopmentStats.ageBuckets)
        XCTAssertEqual(ages.map(\.value), [1, 1, 0, 2])
    }

    func testReviewStatusTakesTheFirstThatApplies() {
        XCTAssertEqual(DevelopmentStats.reviewStatus(pr(daysOld: 1, state: .draft, conflicts: true)), .draft)
        XCTAssertEqual(DevelopmentStats.reviewStatus(pr(daysOld: 1, conflicts: true, votes: [.approved])), .conflicts)
        XCTAssertEqual(DevelopmentStats.reviewStatus(pr(daysOld: 1, votes: [.approved, .waitingForAuthor])), .changesRequested)
        XCTAssertEqual(DevelopmentStats.reviewStatus(pr(daysOld: 1, votes: [.approvedWithSuggestions])), .approved)
        XCTAssertEqual(DevelopmentStats.reviewStatus(pr(daysOld: 1)), .awaitingReview)
    }

    func testCommitsPerDayIsContinuous() {
        let commits = [
            PullRequestCommit(id: "a", message: "m", authorName: "x", date: now),
            PullRequestCommit(id: "b", message: "m", authorName: "x", date: now.addingTimeInterval(-2 * 86_400)),
        ]
        let days = DevelopmentStats.commitsPerDay(commits, days: 3, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.value), [1, 0, 1])
    }

    func testSuccessRateIgnoresRunsWithoutAVerdict() {
        let runs = [run(.succeeded), run(.succeeded), run(.failed), run(.running, minutes: nil), run(.cancelled)]
        XCTAssertEqual(DevelopmentStats.successRate(runs)!, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertNil(DevelopmentStats.successRate([run(.running, minutes: nil)]))
    }

    func testOutcomesGroupActiveAndSkippedRuns() {
        let outcomes = DevelopmentStats.outcomes([run(.queued), run(.running), run(.skipped), run(.succeeded)])
        XCTAssertEqual(outcomes.map(\.outcome), [.succeeded, .cancelled, .running])
        XCTAssertEqual(outcomes.map(\.count), [1, 1, 2])
    }

    func testMedianDurationsSlowestFirst() {
        let runs = [run(.succeeded, name: "a", minutes: 2), run(.succeeded, name: "a", minutes: 4),
                    run(.failed, name: "b", minutes: 10), run(.running, name: "c", minutes: nil)]
        let medians = DevelopmentStats.medianDurations(runs)
        XCTAssertEqual(medians.map(\.pipeline), ["b", "a"])
        XCTAssertEqual(medians.last?.seconds, 180)
    }

    func testRunsPerDayDropsRunsOutsideTheWindow() {
        let runs = [run(.succeeded, startedHoursAgo: 1), run(.failed, startedHoursAgo: 1), run(.succeeded, startedHoursAgo: 24 * 10)]
        let days = DevelopmentStats.runsPerDay(runs, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(days.reduce(0) { $0 + $1.value }, 2)
    }

    func testWeekdaysFollowTheCalendarsFirstDay() {
        var monday = calendar
        monday.firstWeekday = 2
        let days = DevelopmentStats.weekdays([now], calendar: monday)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.label, monday.shortWeekdaySymbols[1])
        XCTAssertEqual(days.reduce(0) { $0 + $1.value }, 1)
    }

    func testPerWeekIsContinuous() {
        let weeks = DevelopmentStats.perWeek([now, now.addingTimeInterval(-14 * 86_400)], weeks: 4, now: now, calendar: calendar)
        XCTAssertEqual(weeks.map(\.value), [0, 1, 0, 1])
    }
}
