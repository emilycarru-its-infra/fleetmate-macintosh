import XCTest
@testable import FleetMateCore

final class FleetMateLinkTests: XCTestCase {
    private func parse(_ s: String) throws -> FleetMateLink { try FleetMateLink.parse(URL(string: s)!) }

    func testAzureDevOpsRoutes() throws {
        XCTAssertEqual(try parse("fleetmate://pull/Platform/Fleet/27391"),
                       .pullRequest(.azureDevOps(project: "Platform", repo: "Fleet"), number: 27391))
        XCTAssertEqual(try parse("fleetmate://workitem/1234"), .workItem(id: 1234))
        XCTAssertEqual(try parse("fleetmate://pipeline/Platform/4242"), .azureDevOpsRun(project: "Platform", runId: 4242))
        XCTAssertEqual(try parse("fleetmate://pipeline/Platform/definition/7"),
                       .azureDevOpsPipeline(project: "Platform", definitionId: 7))
        XCTAssertEqual(try parse("fleetmate://commit/Platform/Agent/0a1b2c3d4e5f"),
                       .commit(.azureDevOps(project: "Platform", repo: "Agent"), sha: "0a1b2c3d4e5f"))
    }

    func testGitHubRoutes() throws {
        XCTAssertEqual(try parse("fleetmate://pull/github/octo/tool/7"), .pullRequest(.gitHub(owner: "octo", repo: "tool"), number: 7))
        XCTAssertEqual(try parse("fleetmate://issue/github/octo/tool/12"), .gitHubIssue(owner: "octo", repo: "tool", number: 12))
        XCTAssertEqual(try parse("fleetmate://pipeline/github/octo/tool/999"), .gitHubRun(owner: "octo", repo: "tool", runId: 999))
        XCTAssertEqual(try parse("fleetmate://commit/github/octo/tool/abcdef1"), .commit(.gitHub(owner: "octo", repo: "tool"), sha: "abcdef1"))
    }

    func testReportingRoutes() throws {
        XCTAssertEqual(try parse("fleetmate://reporting/device/SAMPLE1?tab=installs"),
                       .reporting(URL(string: "reportmate://device/SAMPLE1?tab=installs")!))
        XCTAssertEqual(try parse("fleetmate://reporting"), .reporting(URL(string: "reportmate://dashboard")!))
        XCTAssertEqual(try parse("fleetmate://reporting/applications/usage/Visual%20Studio%20Code"),
                       .reporting(URL(string: "reportmate://applications/usage/Visual%20Studio%20Code")!))
        let link = try parse("fleetmate://reporting/events/failures?platform=mac")
        XCTAssertEqual(link.url.absoluteString, "fleetmate://reporting/events/failures?platform=mac")
    }

    func testOpenWebURLs() throws {
        let base = "https://azure-devops.example.com/org/Platform"
        func open(_ web: String) throws -> FleetMateLink {
            try parse("fleetmate://open?url=" + web.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        }
        XCTAssertEqual(try open("\(base)/_git/Fleet/pullrequest/27391"),
                       .pullRequest(.azureDevOps(project: "Platform", repo: "Fleet"), number: 27391))
        XCTAssertEqual(try open("\(base)/_git/Agent/commit/0a1b2c3d4e5f6a7b"),
                       .commit(.azureDevOps(project: "Platform", repo: "Agent"), sha: "0a1b2c3d4e5f6a7b"))
        XCTAssertEqual(try open("\(base)/_build/results?buildId=4242&view=results"),
                       .azureDevOpsRun(project: "Platform", runId: 4242))
        XCTAssertEqual(try open("\(base)/_build?definitionId=7"), .azureDevOpsPipeline(project: "Platform", definitionId: 7))
        XCTAssertEqual(try open("https://azure-devops.example.com/org/Projects/_workitems/edit/1234"), .workItem(id: 1234))
        XCTAssertEqual(try open("https://github.com/octo/tool/pull/7"), .pullRequest(.gitHub(owner: "octo", repo: "tool"), number: 7))
        XCTAssertEqual(try open("https://github.com/octo/tool/actions/runs/999"), .gitHubRun(owner: "octo", repo: "tool", runId: 999))
    }

    func testRoundTrip() throws {
        let links: [FleetMateLink] = [
            .pullRequest(.azureDevOps(project: "Platform", repo: "Fleet"), number: 27391),
            .pullRequest(.gitHub(owner: "octo", repo: "tool"), number: 7),
            .commit(.azureDevOps(project: "Platform", repo: "Agent"), sha: "abcdef1"),
            .azureDevOpsRun(project: "Platform", runId: 4242),
            .azureDevOpsPipeline(project: "Platform", definitionId: 7),
            .gitHubRun(owner: "octo", repo: "tool", runId: 999),
            .workItem(id: 1234),
            .gitHubIssue(owner: "octo", repo: "tool", number: 12),
        ]
        for link in links { XCTAssertEqual(try FleetMateLink.parse(link.url), link) }
    }

    func testErrorsAreNamed() {
        XCTAssertThrowsError(try parse("fleetmate://nonsense/1")) { error in
            XCTAssertEqual(error as? FleetMateLinkError, .unknownRoute("nonsense"))
        }
        XCTAssertThrowsError(try parse("fleetmate://pull/Platform/Fleet"))
        XCTAssertThrowsError(try parse("fleetmate://commit/Platform/Agent/not-a-sha"))
        XCTAssertThrowsError(try parse("fleetmate://open?url=https://example.com/x"))
    }

    func testItemRoutes() throws {
        XCTAssertEqual(try parse("fleetmate://device/1f2e3d4c-0000-4abc-9def-1234567890ab"),
                       .device(id: "1f2e3d4c-0000-4abc-9def-1234567890ab"))
        XCTAssertEqual(try parse("fleetmate://asset/3302"), .asset(id: 3302))
        XCTAssertEqual(try parse("fleetmate://ticket/1234567"), .ticket(id: 1234567))
        XCTAssertEqual(try parse("fleetmate://user/someone@example.com"), .user(id: "someone@example.com"))
        XCTAssertThrowsError(try parse("fleetmate://asset/abc"))
        XCTAssertThrowsError(try parse("fleetmate://device/..%2Fx"))
    }

    /// Names reach API paths, so a link can't smuggle in path segments.
    func testRejectsPathTricks() {
        XCTAssertThrowsError(try parse("fleetmate://pipeline/github/..%2F..%2Fuser/x/1"))
        XCTAssertThrowsError(try parse("fleetmate://pull/github/../tool/7"))
        XCTAssertThrowsError(try parse("fleetmate://pull/Platform/Fleet%3Fx%3D1/27391"))
        XCTAssertNoThrow(try parse("fleetmate://pull/Platform%20Team/Fleet.Tools/1"))
    }
}
