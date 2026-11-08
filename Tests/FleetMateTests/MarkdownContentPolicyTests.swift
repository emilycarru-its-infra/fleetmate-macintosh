import XCTest
@testable import FleetMateCore

final class MarkdownContentPolicyTests: XCTestCase {
    private let tdx = URL(string: "https://example.teamdynamix.com/TDWebApi")

    func testLinksOpenOnlyInTheBrowserOrMail() {
        XCTAssertTrue(MarkdownContentPolicy.allowsLink(URL(string: "https://example.org/a")!))
        XCTAssertTrue(MarkdownContentPolicy.allowsLink(URL(string: "http://example.org/a")!))
        XCTAssertTrue(MarkdownContentPolicy.allowsLink(URL(string: "mailto:help@example.org")!))
        XCTAssertFalse(MarkdownContentPolicy.allowsLink(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(MarkdownContentPolicy.allowsLink(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(MarkdownContentPolicy.allowsLink(URL(string: "x-apple.systempreferences:")!))
        XCTAssertFalse(MarkdownContentPolicy.allowsLink(URL(string: "ssh://host")!))
    }

    func testImagesLoadFromTeamDynamixByDefault() {
        XCTAssertTrue(MarkdownContentPolicy.allowsImage(URL(string: "https://example.teamdynamix.com/TDPortal/img.png"), tdxBase: tdx, site: nil, allowExternal: false))
        XCTAssertFalse(MarkdownContentPolicy.allowsImage(URL(string: "https://tracker.example/pixel.gif"), tdxBase: tdx, site: nil, allowExternal: false))
        XCTAssertFalse(MarkdownContentPolicy.allowsImage(URL(string: "http://example.teamdynamix.com/img.png"), tdxBase: tdx, site: nil, allowExternal: true))
        XCTAssertFalse(MarkdownContentPolicy.allowsImage(nil, tdxBase: tdx, site: nil, allowExternal: true))
    }

    func testImageSiteAndTheExternalSwitch() {
        let url = URL(string: "https://docs.example.org/a.png")
        XCTAssertTrue(MarkdownContentPolicy.allowsImage(url, tdxBase: tdx, site: "https://docs.example.org", allowExternal: false))
        XCTAssertTrue(MarkdownContentPolicy.allowsImage(url, tdxBase: tdx, site: nil, allowExternal: true))
        XCTAssertFalse(MarkdownContentPolicy.allowsImage(url, tdxBase: tdx, site: "https://other.example.org", allowExternal: false))
    }
}
