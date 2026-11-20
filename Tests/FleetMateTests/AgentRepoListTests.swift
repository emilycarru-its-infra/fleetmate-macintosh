import XCTest
@testable import FleetMateCore

final class AgentRepoListTests: XCTestCase {
    let home = "/Users/me"

    func testAddsTrackedCheckoutsAfterTheAgentsOwn() {
        let merged = AgentRepoList.merged(
            agent: ["~/Dev/A", "https://example.com/x.git"],
            tracked: ["/Users/me/Dev/B", "/Users/me/Dev/A/", "/opt/C"],
            home: home)
        XCTAssertEqual(merged, ["~/Dev/A", "https://example.com/x.git", "~/Dev/B", "/opt/C"])
    }

    func testLocalPathsExpandAndSkipURLs() {
        XCTAssertEqual(AgentRepoList.localPaths(["~/Dev/A", "https://example.com/x.git", "/opt/C/"], home: home),
                       ["/Users/me/Dev/A", "/opt/C"])
    }
}
