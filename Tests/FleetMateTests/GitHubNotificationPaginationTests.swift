import XCTest
@testable import FleetMateCore

final class GitHubNotificationPaginationTests: XCTestCase {
    actor Pages {
        var paths: [String] = []
        func fetch(_ path: String) throws -> Data {
            paths.append(path)
            let start = path.contains("page=2") ? 50 : 0
            let count = start == 0 ? 50 : 2
            let rows = (start..<(start + count)).map { ["id": String($0), "reason": "review_requested"] }
            return try JSONSerialization.data(withJSONObject: rows)
        }
    }

    func testUnreadNotificationsContinueOntoSecondPage() async throws {
        let pages = Pages()
        let rows = try await GitHubNotificationService.loadNotifications(includeRead: false, limit: 200) {
            try await pages.fetch($0)
        }
        XCTAssertEqual(rows.count, 52)
        let paths = await pages.paths
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].contains("all=false"))
        XCTAssertTrue(paths[1].hasSuffix("&page=2"))
    }

    func testRepeatedPageStopsAndDoesNotDuplicateNotifications() async throws {
        let data = try JSONSerialization.data(withJSONObject: (0..<50).map { ["id": String($0)] })
        let rows = try await GitHubNotificationService.loadNotifications(includeRead: true, limit: 200) { _ in data }
        XCTAssertEqual(rows.count, 50)
    }

    func testPageFailureIsReportedInsteadOfReturningPartialInbox() async {
        do {
            _ = try await GitHubNotificationService.loadNotifications(includeRead: false, limit: 200) { path in
                if path.hasSuffix("&page=2") { throw URLError(.notConnectedToInternet) }
                return try JSONSerialization.data(withJSONObject: (0..<50).map { ["id": String($0)] })
            }
            XCTFail("Expected a failed refresh")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
