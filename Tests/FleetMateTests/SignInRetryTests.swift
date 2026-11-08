import XCTest
@testable import FleetMateCore

final class SignInRetryTests: XCTestCase {
    func testFailureBeforeSignInFinishesWaits() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .signingIn), .waitForSignIn)
    }

    func testFailureAfterSignInFailedStillWaitsForALaterSignIn() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .failed), .waitForSignIn)
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: true, status: .failed), .waitForSignIn)
    }

    func testSignInLandingMidRequestRetriesAtOnce() {
        // The sign-in change that would re-run the request already fired.
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .signedIn), .retryNow)
    }

    func testFailureWhileSignedInIsReal() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: true, status: .signedIn), .showError)
    }

    func testUnconfiguredServiceNeverWaits() {
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: false, status: .notConfigured), .showError)
        XCTAssertEqual(SignInRetry.afterFailure(startedSignedIn: true, status: .notConfigured), .showError)
    }

    func testRetrySignsInFirstWhenSignInFailed() {
        XCTAssertEqual(SignInRetryTap.decide(status: .failed), .signInThenReload)
    }

    func testRetryWaitsWhileSignInIsRunning() {
        XCTAssertEqual(SignInRetryTap.decide(status: .signingIn), .waitForSignIn)
    }

    func testRetryReloadsWhenSignInIsNotTheProblem() {
        XCTAssertEqual(SignInRetryTap.decide(status: .signedIn), .reload)
        XCTAssertEqual(SignInRetryTap.decide(status: .notConfigured), .reload)
    }

    #if !TICKETSMATE
    func testAzureDevOpsLinksWaitForAzureDevOpsSignIn() throws {
        let waits = [
            "fleetmate://workitem/12",
            "fleetmate://pull/Platform/Fleet/3",
            "fleetmate://commit/Platform/Agent/0a1b2c3d",
            "fleetmate://pipeline/Platform/42",
            "fleetmate://pipeline/Platform/definition/7",
        ]
        for s in waits {
            XCTAssertTrue(try FleetMateLink.parse(URL(string: s)!).needsAzureDevOps, s)
        }
        let doesNot = [
            "fleetmate://pull/github/octo/tool/7",
            "fleetmate://commit/github/octo/tool/0a1b2c3d",
            "fleetmate://issue/github/octo/tool/12",
            "fleetmate://pipeline/github/octo/tool/99",
            "fleetmate://ticket/5",
            "fleetmate://asset/5",
        ]
        for s in doesNot {
            XCTAssertFalse(try FleetMateLink.parse(URL(string: s)!).needsAzureDevOps, s)
        }
    }
    #endif
}
