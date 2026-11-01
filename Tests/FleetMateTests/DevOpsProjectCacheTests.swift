import Foundation
import XCTest
@testable import FleetMateCore

final class DevOpsProjectCacheTests: XCTestCase {
    func testSnapshotsKeepTheirProjectsAfterReplacementAndClear() {
        let cache = DevOpsProjectCache()
        let now = Date(timeIntervalSince1970: 1_000)
        cache.store([Self.project(1)], now: now)
        let snapshot = cache.snapshot()
        cache.store([Self.project(2)], now: now.addingTimeInterval(1))
        cache.clear()

        XCTAssertEqual(snapshot.projects?.first?.id, "1")
        XCTAssertEqual(snapshot.expiresAt, now.addingTimeInterval(600))
        XCTAssertNil(cache.snapshot().projects)
        XCTAssertEqual(cache.snapshot().retryAfter, .distantPast)
    }

    func testFailureKeepsStaleProjectsAndLogsOnceUntilRecovery() {
        let cache = DevOpsProjectCache()
        let now = Date(timeIntervalSince1970: 1_000)
        cache.store([Self.project(1)], now: now)
        XCTAssertTrue(cache.recordFailure(now: now).shouldLog)
        XCTAssertFalse(cache.recordFailure(now: now).shouldLog)
        XCTAssertEqual(cache.snapshot().retryAfter, now.addingTimeInterval(300))
        XCTAssertEqual(cache.snapshot().projects?.first?.id, "1")

        cache.resetBackoff()
        XCTAssertEqual(cache.snapshot().retryAfter, .distantPast)
        cache.store([Self.project(2)], now: now)
        XCTAssertTrue(cache.recordFailure(now: now).shouldLog)
    }

    func testConcurrentReplacementReadFailureAndInvalidation() {
        let cache = DevOpsProjectCache()
        DispatchQueue.concurrentPerform(iterations: 20_000) { index in
            let now = Date(timeIntervalSince1970: Double(index))
            switch index % 4 {
            case 0:
                cache.store([Self.project(index)], now: now)
            case 1:
                _ = cache.recordFailure(now: now)
            case 2:
                cache.resetBackoff()
            default:
                cache.clear()
            }
            let snapshot = cache.snapshot()
            if let project = snapshot.projects?.first, let id = Int(project.id) {
                XCTAssertEqual(snapshot.expiresAt.timeIntervalSince1970, Double(id + 600))
                XCTAssertEqual(project.name, "Project \(id) " + String(repeating: "x", count: 128))
            }
        }
    }

    private static func project(_ id: Int) -> DevOpsProject {
        DevOpsProject(id: String(id), name: "Project \(id) " + String(repeating: "x", count: 128), state: "wellFormed")
    }
}
