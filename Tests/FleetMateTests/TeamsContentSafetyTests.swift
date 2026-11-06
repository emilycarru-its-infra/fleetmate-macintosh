import XCTest
@testable import FleetMateCore

final class TeamsContentSafetyTests: XCTestCase {
    private let hosts = TeamsLinkPolicy.hosts(extra: "example.edu")

    func testTeamsAndSharePointLinksOpen() {
        XCTAssertNotNil(TeamsLinkPolicy.safeURL("https://teams.microsoft.com/l/message/19:x/1", allowedHosts: hosts))
        XCTAssertNotNil(TeamsLinkPolicy.safeURL("https://teams.cloud.microsoft/l/message/1", allowedHosts: hosts))
        XCTAssertNotNil(TeamsLinkPolicy.safeURL("https://contoso.sharepoint.com/sites/x/a.docx", allowedHosts: hosts))
    }

    func testConfiguredDomainAndItsSubdomainsOpen() {
        XCTAssertNotNil(TeamsLinkPolicy.safeURL("https://example.edu/page", allowedHosts: hosts))
        XCTAssertNotNil(TeamsLinkPolicy.safeURL("https://wiki.example.edu/page", allowedHosts: hosts))
        XCTAssertNil(TeamsLinkPolicy.safeURL("https://example.edu.evil.test/", allowedHosts: hosts))
        XCTAssertNil(TeamsLinkPolicy.safeURL("https://notexample.edu/", allowedHosts: hosts))
    }

    func testEverythingElseIsRefused() {
        for link in [
            "http://teams.microsoft.com/l/message/1",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "smb://server/share",
            "x-apple.systempreferences:com.apple.preference.security",
            "https://evil.test/",
            "https://teams.microsoft.com.evil.test/",
            "https://sharepoint.com/",
            "https://user:pass@teams.microsoft.com/",
            "not a url",
            "",
        ] {
            XCTAssertNil(TeamsLinkPolicy.safeURL(link, allowedHosts: hosts), link)
        }
        XCTAssertNil(TeamsLinkPolicy.safeURL(nil, allowedHosts: hosts))
        XCTAssertNil(TeamsLinkPolicy.safeURL("https://example.edu/", allowedHosts: TeamsLinkPolicy.hosts(extra: nil)))
    }

    func testNamesLoseControlAndFormatCharacters() {
        XCTAssertEqual(TeamsText.line("Alex\u{202E}txt.exe"), "Alextxt.exe")
        XCTAssertEqual(TeamsText.line("Zero\u{200B}width\u{2060}"), "Zerowidth")
        XCTAssertEqual(TeamsText.line("Two\nlines\u{0007}"), "Two lines")
        XCTAssertEqual(TeamsText.line(nil), "")
    }

    func testBodiesKeepLineBreaksOnly() {
        XCTAssertEqual(TeamsText.body("First\u{202E}\nSecond\u{0000}line"), "First\nSecondline")
        XCTAssertEqual(TeamsText.body("Tab\there"), "Tab\there")
    }
}
