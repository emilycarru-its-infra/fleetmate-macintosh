import XCTest
@testable import FleetMateCore

/// The allow-list for links and images in Handbook and skill text.
final class HandbookLinksTests: XCTestCase {
    private let site = "https://handbook.example.org"

    private lazy var index = HandbookIndex(pages: [
        HandbookIndex.page(relativePath: "devices/enrollment.md", text: "---\ntitle: Enrollment\n---\nbody")!,
        HandbookIndex.page(relativePath: "devices/wifi.md", text: "---\ntitle: Wi-Fi\n---\nbody")!,
    ])

    private var from: HandbookPage { index.pages[0] }

    private func classify(_ link: String, siteURL: String? = "https://handbook.example.org") -> HandbookLinkAction {
        guard let url = URL(string: link) else { return .ignore }
        return HandbookLinks.classify(url, from: from, index: index, siteURL: siteURL)
    }

    func testAnythingButAPageOrAWebLinkIsDropped() {
        for link in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "file:///Applications/Calculator.app",
                     "smb://server/share", "vnc://host", "x-apple.systempreferences:com.apple.preference.security",
                     "data:text/html,hi", "mailto:someone@example.org", "//server/share/run", "#steps"] {
            XCTAssertEqual(classify(link), .ignore, link)
            if let url = URL(string: link) { XCTAssertNil(HandbookLinks.external(url), link) }
        }
    }

    func testBareNamesStayOnTheSite() {
        guard case .openInBrowser(let url) = classify("Calculator.app") else { return XCTFail("expected the site") }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "handbook.example.org")
    }

    func testLinksToAnotherPageOpenInTheReader() {
        for link in ["../wifi/", "/devices/wifi/", "/devices/wifi", "https://handbook.example.org/devices/wifi/"] {
            XCTAssertEqual(classify(link), .openPage(index.pages[1]), link)
        }
        XCTAssertEqual(classify("../wifi/", siteURL: nil), .openPage(index.pages[1]))
        XCTAssertEqual(classify("/nowhere/", siteURL: nil), .ignore)
    }

    func testWebLinksOpenInTheBrowser() {
        XCTAssertEqual(classify("https://learn.example.com/a?b=c"), .openInBrowser(URL(string: "https://learn.example.com/a?b=c")!))
        guard case .openInBrowser(let url) = classify("/not-in-the-copy/") else { return XCTFail("expected the site") }
        XCTAssertEqual(url.host, "handbook.example.org")
    }

    func testSiteAddressesNeverLeaveTheSite() {
        for sitePath in ["javascript:alert(1)", "//evil.example/x/", "/a:b/"] {
            let page = HandbookPage(path: page.path, title: page.title, sections: page.sections, sitePath: sitePath,
                                headings: [], body: "", lastModified: nil, lastModifiedBy: nil)
            let url = HandbookLinks.pageURL(siteURL: site, page: page)
            XCTAssertTrue(url == nil || (url?.host == "handbook.example.org" && url?.scheme == "https"), sitePath)
        }
        XCTAssertEqual(HandbookLinks.pageURL(siteURL: site, page: from)?.absoluteString,
                       "https://handbook.example.org/devices/enrollment/")
        XCTAssertNil(HandbookLinks.pageURL(siteURL: "javascript:alert(1)", page: from))
        XCTAssertNil(HandbookLinks.pageURL(siteURL: "file:///Users/", page: from))
    }

    func testImagesLoadOnlyFromTheSite() {
        XCTAssertTrue(HandbookLinks.allowsImage(URL(string: "https://handbook.example.org/img/a.png"), siteURL: site))
        XCTAssertFalse(HandbookLinks.allowsImage(URL(string: "https://tracker.example.com/p.gif"), siteURL: site))
        XCTAssertFalse(HandbookLinks.allowsImage(URL(string: "file:///etc/hosts"), siteURL: site))
        XCTAssertFalse(HandbookLinks.allowsImage(URL(string: "https://handbook.example.org/a.png"), siteURL: nil))
    }
}
