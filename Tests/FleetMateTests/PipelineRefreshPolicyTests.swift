import XCTest
@testable import FleetMateCore

final class PipelineRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testWatchingActiveRunsChecksSoonerThanBackgroundAndFailuresBackOff() {
        var policy = PipelineRefreshPolicy()
        policy.finish(now: now, succeeded: true, discovery: true)
        XCTAssertFalse(policy.isDue(now: now.addingTimeInterval(14), visible: true, activeRuns: true))
        XCTAssertTrue(policy.isDue(now: now.addingTimeInterval(15), visible: true, activeRuns: true))
        XCTAssertFalse(policy.isDue(now: now.addingTimeInterval(59), visible: false, activeRuns: true))
        XCTAssertTrue(policy.isDue(now: now.addingTimeInterval(60), visible: false, activeRuns: true))
        for _ in 0..<8 { policy.finish(now: now, succeeded: false, discovery: true) }
        XCTAssertFalse(policy.isDue(now: now.addingTimeInterval(299), visible: true, activeRuns: true))
        XCTAssertTrue(policy.isDue(now: now.addingTimeInterval(300), visible: true, activeRuns: true))
        policy.finish(now: now, succeeded: true, discovery: false)
        XCTAssertTrue(policy.isDue(now: now.addingTimeInterval(15), visible: true, activeRuns: true))
    }

    func testFailedDiscoveryDoesNotPostponeFullDiscovery() {
        var policy = PipelineRefreshPolicy()
        XCTAssertTrue(policy.needsDiscovery(now: now))
        policy.finish(now: now, succeeded: false, discovery: true)
        XCTAssertTrue(policy.needsDiscovery(now: now.addingTimeInterval(300)))
        policy.finish(now: now, succeeded: true, discovery: true)
        XCTAssertFalse(policy.needsDiscovery(now: now.addingTimeInterval(899)))
        policy.finish(now: now.addingTimeInterval(899), succeeded: true, discovery: false)
        XCTAssertTrue(policy.needsDiscovery(now: now.addingTimeInterval(900)))
    }

    func testPartialMetadataKeepsUnqueriedRunsAndUpdatesCompletion() {
        let active = run(1, status: .running)
        let otherSource = run(2, status: .failed, source: .azureDevOps)
        let complete = run(1, status: .succeeded)
        let result = PipelineRefreshPolicy.merge([active, otherSource], updates: [complete], now: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.id == complete.id }?.status, .succeeded)
        XCTAssertTrue(result.contains(otherSource))
        XCTAssertEqual(PipelineRefreshPolicy.merge(result, updates: [], now: now), result)
    }

    func testHistoryBoundKeepsOldActiveRunsButDropsExpiredCompletions() {
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let active = run(1, status: .running, date: old)
        let expired = run(2, status: .succeeded, date: old)
        let recent = (3...8).map { run($0, status: .succeeded) }
        let result = PipelineRefreshPolicy.merge([active, expired] + recent, updates: [], now: now, limit: 4)
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.contains(active))
        XCTAssertFalse(result.contains(expired))
    }

    private func run(_ id: Int, status: PipelineRunStatus, source: PullRequestSource = .gitHub, date: Date? = nil) -> PipelineRun {
        PipelineRun(source: source, container: "example", repository: "project", pipelineName: "Build", pipelineId: 1,
                    runId: id, runNumber: String(id), status: status, branch: nil, commitSha: nil, triggeredBy: nil,
                    startedAt: date ?? now, finishedAt: status.isActive ? nil : now, webUrl: "https://example.com/runs/\(id)")
    }
}
