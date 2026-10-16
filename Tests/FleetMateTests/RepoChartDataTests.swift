import XCTest
@testable import FleetMateCore

final class RepoChartDataTests: XCTestCase {
    func testCompressionRetainsZeroSignsAndRelativeOrdering() {
        XCTAssertEqual(RepoChurnScale.compressed.position(0), 0)
        XCTAssertEqual(RepoChurnScale.compressed.position(999), 3, accuracy: 0.000001)
        XCTAssertEqual(RepoChurnScale.compressed.position(-999), -3, accuracy: 0.000001)
        XCTAssertLessThan(RepoChurnScale.compressed.position(1_000), RepoChurnScale.compressed.position(2_000_000))
        XCTAssertEqual(RepoChurnScale.linear.position(2_000_000), 2_000_000)
        XCTAssertTrue(RepoChurnScale.compressed.position(Int.min).isFinite)
    }

    func testAutomaticScaleRespondsToCurrentOutliers() {
        func point(_ added: Int, _ removed: Int = 0) -> RepoStatsReport.TimelinePoint {
            .init(start: Date(timeIntervalSince1970: 0), commits: 1, added: added, removed: removed)
        }
        XCTAssertEqual(RepoChurnScale.recommended(for: []), .linear)
        XCTAssertEqual(RepoChurnScale.recommended(for: [point(1), point(9_999)]), .linear)
        XCTAssertEqual(RepoChurnScale.recommended(for: [point(100), point(100), point(10_000)]), .compressed)
        XCTAssertEqual(RepoChurnScale.recommended(for: [point(101), point(101), point(10_000)]), .linear)
        XCTAssertEqual(RepoChurnScale.recommended(for: [point(100), point(200), point(100), point(0, 2_000_000)]), .compressed)
        XCTAssertEqual(RepoChurnScale.recommended(for: [point(10_000), point(20_000)]), .linear)
    }

    func testCompressedAxisLimitsTickCrowding() {
        XCTAssertEqual(RepoChurnScale.tickMagnitudes(peak: 2_000_000), [100, 10_000, 1_000_000])
        XCTAssertEqual(RepoChurnScale.tickMagnitudes(peak: 10_000), [100, 1_000, 10_000])
        XCTAssertEqual(RepoChurnScale.tickMagnitudes(peak: 0), [1])
        XCTAssertLessThanOrEqual(RepoChurnScale.tickMagnitudes(peak: Int.max).count, 3)
    }

    func testActivityGridIncludesAllQuietHoursAndPreservesCounts() {
        let grid = RepoStatsReport.ActivityCell.grid([
            .init(weekday: 1, hour: 0, commits: 2),
            .init(weekday: 7, hour: 23, commits: 5)
        ])
        XCTAssertEqual(grid.count, 168)
        XCTAssertEqual(Set(grid.map(\.id)).count, 168)
        XCTAssertEqual(grid.first?.commits, 2)
        XCTAssertEqual(grid.last?.commits, 5)
        XCTAssertEqual(grid.filter { $0.commits == 0 }.count, 166)
        XCTAssertEqual(grid.reduce(0) { $0 + $1.commits }, 7)
        XCTAssertEqual(RepoStatsReport.ActivityCell.grid([]).filter { $0.commits == 0 }.count, 168)
    }
}
