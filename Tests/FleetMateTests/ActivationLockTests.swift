import XCTest
@testable import FleetMateCore

final class ActivationLockTests: XCTestCase {
    func testNoAnswerIsUnknownNeverDisabled() {
        let lock = AppleActivationLock(isLocked: nil, lockType: nil)
        XCTAssertEqual(lock, .unknown)
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(lock.detailText, "Unknown")
    }

    func testUnlocked() {
        XCTAssertEqual(AppleActivationLock(isLocked: false, lockType: "NONE"), .disabled)
        XCTAssertEqual(AppleActivationLock(isLocked: false, lockType: nil).detailText, "Disabled")
    }

    func testMdmLock() {
        let lock = AppleActivationLock(isLocked: true, lockType: "MDM")
        XCTAssertEqual(lock, .mdmLock)
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(lock.detailText, "Enabled — MDM lock (bypass code escrowed; clearing doesn't need the owner)")
        XCTAssertEqual(lock.columnText, "Enabled — MDM")
    }

    func testUserLockIsCaseInsensitive() {
        let lock = AppleActivationLock(isLocked: true, lockType: "user")
        XCTAssertEqual(lock, .userLock)
        XCTAssertEqual(lock.detailText, "Enabled — User lock (needs the owner's Apple Account)")
    }

    func testLockedWithoutKindIsPlainEnabled() {
        XCTAssertEqual(AppleActivationLock(isLocked: true, lockType: nil), .enabled)
        XCTAssertEqual(AppleActivationLock(isLocked: true, lockType: "NONE").detailText, "Enabled")
    }
}
