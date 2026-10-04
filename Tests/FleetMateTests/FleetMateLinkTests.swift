import XCTest
@testable import FleetMateCore

final class FleetMateLinkTests: XCTestCase {
    private func parse(_ s: String) throws -> FleetMateLink { try FleetMateLink.parse(URL(string: s)!) }

    func testAzureDevOpsRoutes() throws {
        XCTAssertEqual(try parse("fleetmate://pull/Devices/Munki/15048"),
                       .pullRequest(.azureDevOps(project: "Devices", repo: "Munki"), number: 15048))
        XCTAssertEqual(try parse("fleetmate://workitem/5558"), .workItem(id: 5558))
        XCTAssertEqual(try parse("fleetmate://pipeline/Devices/23249"), .azureDevOpsRun(project: "Devices", runId: 23249))
        XCTAssertEqual(try parse("fleetmate://pipeline/Devices/definition/89"),
                       .azureDevOpsPipeline(project: "Devices", definitionId: 89))
        XCTAssertEqual(try parse("fleetmate://commit/Devices/Cimian/0a1b2c3d4e5f"),
                       .commit(.azureDevOps(project: "Devices", repo: "Cimian"), sha: "0a1b2c3d4e5f"))
    }

    func testGitHubRoutes() throws {
        XCTAssertEqual(try parse("fleetmate://pull/github/octo/tool/7"), .pullRequest(.gitHub(owner: "octo", repo: "tool"), number: 7))
        XCTAssertEqual(try parse("fleetmate://issue/github/octo/tool/12"), .gitHubIssue(owner: "octo", repo: "tool", number: 12))
        XCTAssertEqual(try parse("fleetmate://pipeline/github/octo/tool/999"), .gitHubRun(owner: "octo", repo: "tool", runId: 999))
        XCTAssertEqual(try parse("fleetmate://commit/github/octo/tool/abcdef1"), .commit(.gitHub(owner: "octo", repo: "tool"), sha: "abcdef1"))
    }

    func testOpenWebURLs() throws {
        let base = "https://azure-devops.example.com/org/Devices"
        func open(_ web: String) throws -> FleetMateLink {
            try parse("fleetmate://open?url=" + web.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        }
        XCTAssertEqual(try open("\(base)/_git/Munki/pullrequest/15048"),
                       .pullRequest(.azureDevOps(project: "Devices", repo: "Munki"), number: 15048))
        XCTAssertEqual(try open("\(base)/_git/Cimian/commit/0a1b2c3d4e5f6a7b"),
                       .commit(.azureDevOps(project: "Devices", repo: "Cimian"), sha: "0a1b2c3d4e5f6a7b"))
        XCTAssertEqual(try open("\(base)/_build/results?buildId=23249&view=results"),
                       .azureDevOpsRun(project: "Devices", runId: 23249))
        XCTAssertEqual(try open("\(base)/_build?definitionId=89"), .azureDevOpsPipeline(project: "Devices", definitionId: 89))
        XCTAssertEqual(try open("https://azure-devops.example.com/org/Projects/_workitems/edit/5558"), .workItem(id: 5558))
        XCTAssertEqual(try open("https://github.com/octo/tool/pull/7"), .pullRequest(.gitHub(owner: "octo", repo: "tool"), number: 7))
        XCTAssertEqual(try open("https://github.com/octo/tool/actions/runs/999"), .gitHubRun(owner: "octo", repo: "tool", runId: 999))
    }

    func testRoundTrip() throws {
        let links: [FleetMateLink] = [
            .pullRequest(.azureDevOps(project: "Devices", repo: "Munki"), number: 15048),
            .pullRequest(.gitHub(owner: "octo", repo: "tool"), number: 7),
            .commit(.azureDevOps(project: "Devices", repo: "Cimian"), sha: "abcdef1"),
            .azureDevOpsRun(project: "Devices", runId: 23249),
            .azureDevOpsPipeline(project: "Devices", definitionId: 89),
            .gitHubRun(owner: "octo", repo: "tool", runId: 999),
            .workItem(id: 5558),
            .gitHubIssue(owner: "octo", repo: "tool", number: 12),
        ]
        for link in links { XCTAssertEqual(try FleetMateLink.parse(link.url), link) }
    }

    func testErrorsAreNamed() {
        XCTAssertThrowsError(try parse("fleetmate://nonsense/1")) { error in
            XCTAssertEqual(error as? FleetMateLinkError, .unknownRoute("nonsense"))
        }
        XCTAssertThrowsError(try parse("fleetmate://pull/Devices/Munki"))
        XCTAssertThrowsError(try parse("fleetmate://commit/Devices/Cimian/not-a-sha"))
        XCTAssertThrowsError(try parse("fleetmate://open?url=https://example.com/x"))
    }

    /// Names reach API paths, so a link can't smuggle in path segments.
    func testRejectsPathTricks() {
        XCTAssertThrowsError(try parse("fleetmate://pipeline/github/..%2F..%2Fuser/x/1"))
        XCTAssertThrowsError(try parse("fleetmate://pull/github/../tool/7"))
        XCTAssertThrowsError(try parse("fleetmate://pull/Devices/Munki%3Fx%3D1/15048"))
        XCTAssertNoThrow(try parse("fleetmate://pull/Devices%20Team/Munki.Tools/1"))
    }
}
