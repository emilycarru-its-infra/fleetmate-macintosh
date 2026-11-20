import XCTest
@testable import FleetMateCore

final class AzureDevOpsPullRequestLinkTests: XCTestCase {
    private let matcher = AzureDevOpsPullRequestLink.Matcher(organization: "Contoso",
                                                             serverURL: "https://azure-devops.example.com")

    private func link(_ string: String) -> AzureDevOpsPullRequestLink? {
        matcher.link(for: URL(string: string)!)
    }

    func testServerLinkInTheOrganization() {
        XCTAssertEqual(link("https://azure-devops.example.com/contoso/Platform/_git/api/pullrequest/42"),
                       AzureDevOpsPullRequestLink(project: "Platform", repository: "api", number: 42))
    }

    func testOrganizationIsMatchedWithoutCase() {
        XCTAssertNotNil(link("https://Azure-DevOps.example.com/CONTOSO/Platform/_git/api/pullrequest/42"))
    }

    func testProjectNamesAreDecoded() {
        XCTAssertEqual(link("https://azure-devops.example.com/contoso/Web%20Apps/_git/site/pullrequest/7")?.project,
                       "Web Apps")
    }

    func testVisualStudioSubdomainForm() {
        XCTAssertEqual(link("https://contoso.visualstudio.com/Platform/_git/api/pullrequest/9"),
                       AzureDevOpsPullRequestLink(project: "Platform", repository: "api", number: 9))
    }

    func testAnotherOrganizationIsRefused() {
        XCTAssertNil(link("https://azure-devops.example.com/fabrikam/Platform/_git/api/pullrequest/42"))
        XCTAssertNil(link("https://fabrikam.visualstudio.com/Platform/_git/api/pullrequest/42"))
    }

    func testAnotherHostIsRefused() {
        XCTAssertNil(link("https://elsewhere.example.com/contoso/Platform/_git/api/pullrequest/42"))
        XCTAssertNil(link("https://github.com/contoso/api/pull/42"))
    }

    func testOnlyPlainHTTPSLinks() {
        XCTAssertNil(link("http://azure-devops.example.com/contoso/Platform/_git/api/pullrequest/42"))
        XCTAssertNil(link("https://user@azure-devops.example.com/contoso/Platform/_git/api/pullrequest/42"))
        XCTAssertNil(link("https://azure-devops.example.com:8443/contoso/Platform/_git/api/pullrequest/42"))
    }

    func testOnlyPullRequests() {
        XCTAssertNil(link("https://azure-devops.example.com/contoso/Platform/_git/api/commit/0123456789abcdef0123456789abcdef01234567"))
        XCTAssertNil(link("https://azure-devops.example.com/contoso/Platform/_git/api/pullrequest/abc"))
        XCTAssertNil(link("https://azure-devops.example.com/contoso/Platform/_git/api/pullrequest/0"))
        XCTAssertNil(link("https://azure-devops.example.com/contoso/Platform/_git/api"))
    }

    func testOrganizationSegmentMustBeFirst() {
        // An extra segment in front would put the organization somewhere else.
        XCTAssertNil(link("https://azure-devops.example.com/x/contoso/Platform/_git/api/pullrequest/42"))
        XCTAssertNil(link("https://azure-devops.example.com/Platform/_git/api/pullrequest/42"))
    }

    func testUnsafeNamesAreRefused() {
        XCTAssertNil(link("https://azure-devops.example.com/contoso/..%2F..%2Fother/_git/api/pullrequest/42"))
    }

    func testMatcherFromConfiguration() {
        var config = FleetMateConfig()
        XCTAssertNil(AzureDevOpsPullRequestLink.Matcher(config: config))
        config.devopsOrganization = "contoso"
        config.devopsBaseUrl = "https://azure-devops.example.com/"
        let matcher = AzureDevOpsPullRequestLink.Matcher(config: config)
        XCTAssertEqual(matcher?.serverHost, "azure-devops.example.com")
        XCTAssertNotNil(matcher?.link(for: URL(string: "https://azure-devops.example.com/contoso/P/_git/r/pullrequest/1")!))
    }
}
