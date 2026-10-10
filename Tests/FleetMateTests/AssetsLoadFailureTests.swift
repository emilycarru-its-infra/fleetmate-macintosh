import XCTest
@testable import FleetMateCore

/// A failed asset load reads as a failure in the Inventory widgets, not as an
/// empty inventory.
final class AssetsLoadFailureTests: XCTestCase {
    func testNoFailureKeepsTheEmptyState() {
        XCTAssertEqual(AssetsLoadFailure.headline(nil), "No asset data")
    }

    func testATokenThatCannotBeHadIsASignInFailure() {
        let reason = AssetsLoadFailure.reason(AzTokenError.acquisitionFailed("api://snipe", "Please run 'az login' to setup account."))
        XCTAssertTrue(reason.hasPrefix("Sign-in failed:"))
        XCTAssertEqual(AssetsLoadFailure.headline(reason), "Sign-in failed")
    }

    func testARefusedRequestIsASignInFailure() {
        XCTAssertEqual(AssetsLoadFailure.headline("Response status code was unacceptable: 401."), "Sign-in failed")
        XCTAssertEqual(AssetsLoadFailure.headline("Response status code was unacceptable: 403."), "Sign-in failed")
    }

    func testAnythingElseSaysTheAssetsDidNotLoad() {
        XCTAssertEqual(AssetsLoadFailure.headline("Response status code was unacceptable: 500."), "Could not load assets")
        XCTAssertEqual(AssetsLoadFailure.headline("The data couldn’t be read because it is missing."), "Could not load assets")
    }
}
