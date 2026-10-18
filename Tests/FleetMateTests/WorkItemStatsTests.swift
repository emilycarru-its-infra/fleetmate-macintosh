import XCTest
@testable import FleetMateCore

final class WorkItemStatsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!

    private func item(_ id: Int, _ fields: [String: String]) throws -> WorkItem {
        let json = try JSONSerialization.data(withJSONObject: ["id": id, "fields": fields])
        return try JSONDecoder().decode(WorkItem.self, from: json)
    }

    func testTilesCountFromLoadedItems() throws {
        let items = [
            try item(1, ["System.State": "New", "System.CreatedDate": "2026-10-16T09:00:00.123Z",
                         "System.ChangedDate": "2026-10-17T09:00:00Z"]),
            try item(2, ["System.State": "Active", "System.CreatedDate": "2026-01-01T00:00:00Z",
                         "System.ChangedDate": "2026-08-01T00:00:00Z", "System.Tags": "Infra; Blocked",
                         "Microsoft.VSTS.Scheduling.DueDate": "2026-10-01T00:00:00Z"]),
            try item(3, ["System.State": "In Progress", "System.BoardColumn": "Blocked",
                         "System.ChangedDate": "2026-10-18T08:00:00Z"]),
        ]
        let stats = WorkItemStats(items, now: now)
        XCTAssertEqual(stats.open, 3)
        XCTAssertEqual(stats.inProgress, 2)
        XCTAssertEqual(stats.newThisWeek, 1)
        XCTAssertEqual(stats.updatedThisWeek, 2)
        XCTAssertEqual(stats.blocked, 2)
        XCTAssertEqual(stats.overdue, 1)
        XCTAssertEqual(stats.stale, 1)
    }

    func testRankedByType() throws {
        let items = [
            try item(1, ["System.WorkItemType": "Task"]),
            try item(2, ["System.WorkItemType": "Task"]),
            try item(3, ["System.WorkItemType": "Bug"]),
        ]
        XCTAssertEqual(WorkItemStats.ranked(items) { $0.workItemType }.map(\.label), ["Task", "Bug"])
    }
}
