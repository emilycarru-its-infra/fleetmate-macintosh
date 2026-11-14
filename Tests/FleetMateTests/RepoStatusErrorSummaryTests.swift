import XCTest
@testable import FleetMateCore

final class RepoStatusErrorSummaryTests: XCTestCase {
    func testDubiousOwnershipBecomesOneLine() {
        let error = """
        git status failed: fatal: detected dubious ownership in repository at '/repos/example'
        '/repos/example' is owned by:
            OTHER/account (S-1-5-21-1)
        but the current user is:
            THIS/account (S-1-12-1-2)
        To add an exception for this directory, call:

            git config --global --add safe.directory /repos/example
        """
        XCTAssertEqual(RepoStatus.summarize(error), "Owned by another account. Git won't read it.")
    }

    func testUnknownErrorKeepsFirstLineWithoutPrefixes() {
        XCTAssertEqual(RepoStatus.summarize("git status failed: fatal: bad object HEAD\nmore detail"), "bad object HEAD")
    }

    func testCheckoutMissingIsUnchanged() {
        XCTAssertEqual(RepoStatus.summarize("checkout missing at /repos/gone"), "checkout missing at /repos/gone")
    }
}
