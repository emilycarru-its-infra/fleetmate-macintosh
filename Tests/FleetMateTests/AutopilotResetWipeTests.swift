import Foundation
import XCTest
@testable import FleetMateCore

final class AutopilotResetWipeTests: XCTestCase {
    func testAutopilotResetKeepsEnrollmentAndRemovesUserData() {
        let body = WipeOptions.autopilotReset.requestBody(for: .windows)
        XCTAssertEqual(body["keepEnrollmentData"] as? Bool, true)
        XCTAssertEqual(body["keepUserData"] as? Bool, false)
        XCTAssertNil(body["useProtectedWipe"])
        XCTAssertEqual(body.count, 2)
    }
}
