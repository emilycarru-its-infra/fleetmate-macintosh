import XCTest
@testable import FleetMateCore

final class BrowserLinkTests: XCTestCase {
    func testAzureDevOpsPagesCarryTheOptOut() {
        let url = URL(string: "https://devops.example.invalid/example-org/Project/_git/Repo/pullrequest/12?_a=files")!
        let marked = BrowserLink.forBrowser(url)
        XCTAssertEqual(marked.absoluteString, url.absoluteString + "&fleetmate=browser")
        XCTAssertEqual(BrowserLink.forBrowser(marked), marked)
        XCTAssertEqual(BrowserLink.forBrowser(URL(string: "https://example-org.devops.example.invalid/P/_workitems/edit/3")!).query,
                       "fleetmate=browser")
    }

    func testOtherPagesAreUntouched() {
        for text in ["https://github.com/owner/repo/pull/1", "http://devops.example.invalid/example-org/P/_workitems/edit/3",
                     "https://example.com/docs/page"] {
            let url = URL(string: text)!
            XCTAssertEqual(BrowserLink.forBrowser(url), url)
        }
    }
}
