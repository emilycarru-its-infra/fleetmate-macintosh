import XCTest
@testable import FleetMateCore

final class WorkItemAttachmentTests: XCTestCase {
    func testTitleCopyKeepsPlainTextAndEscapesRichAnchor() throws {
        let value = try XCTUnwrap(TitleLinkCopy(title: "Fix <layout> & \"links\"", link: "https://example.invalid/items/12?a=1&b=2"))
        XCTAssertEqual(value.text, "Fix <layout> & \"links\"\nhttps://example.invalid/items/12?a=1&b=2")
        XCTAssertEqual(value.html, "<a href=\"https://example.invalid/items/12?a=1&amp;b=2\">Fix &lt;layout&gt; &amp; &quot;links&quot;</a>")
        XCTAssertNil(TitleLinkCopy(title: "Unsafe", link: "javascript:alert(1)"))
        XCTAssertNil(TitleLinkCopy(title: "Credential", link: "https://user:password@example.invalid/item"))
    }

    func testGitHubDiscoveryIncludesMarkdownAndHTMLWithoutOrdinaryLinks() {
        let source = """
        ![screenshot](https://github.com/user-attachments/assets/11111111-2222-3333-4444-555555555555)
        [report.pdf](https://github.com/example/project/files/123/report.pdf)
        <img src="https://private-user-images.githubusercontent.com/1/asset.png?x=1&amp;y=2">
        [again](https://github.com/example/project/files/123/report.pdf)
        [ordinary](https://example.invalid/file.pdf)
        """
        let found = WorkItemAttachment.github(in: source)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.last?.url.query, "x=1&y=2")
        XCTAssertEqual(found[1].name, "report.pdf")
    }

    func testAttachmentPolicyDoesNotForwardAuthorizationOutsideProvider() throws {
        let ado = AttachmentAccess.azureDevOps(organization: try XCTUnwrap(URL(string: "https://ado.example.invalid/example")))
        XCTAssertTrue(ado.mayAuthorize(try XCTUnwrap(URL(string: "https://ado.example.invalid/example/project/_apis/wit/attachments/uuid"))))
        for value in ["https://ado.example.invalid/other/_apis/wit/attachments/uuid", "https://ado.example.invalid/example-evil/_apis/wit/attachments/uuid", "https://ado.example.invalid@example.invalid/example/_apis/wit/attachments/uuid", "http://ado.example.invalid/example/_apis/wit/attachments/uuid", "https://ado.example.invalid:8443/example/_apis/wit/attachments/uuid", "https://example.invalid/example/_apis/wit/attachments/uuid"] {
            XCTAssertFalse(ado.allows(try XCTUnwrap(URL(string: value))))
        }
        let github = AttachmentAccess.github
        XCTAssertTrue(github.mayAuthorize(try XCTUnwrap(URL(string: "https://github.com/user-attachments/assets/id"))))
        let asset = try XCTUnwrap(URL(string: "https://private-user-images.githubusercontent.com/123/asset.png?signature=example"))
        XCTAssertTrue(github.allows(asset))
        XCTAssertFalse(github.mayAuthorize(asset))
        for value in ["https://github.com/login", "https://github.com.evil.invalid/user-attachments/assets/id", "https://github-production-user-asset-example.s3.amazonaws.com.evil.invalid/asset.png", "file:///tmp/private.png"] {
            XCTAssertFalse(github.allows(try XCTUnwrap(URL(string: value))))
        }
    }

    func testCancelledDownloadNeverStartsOrReturnsAFile() async throws {
        let loader = try AttachmentDownload(access: .github, name: "../image.png")
        loader.cancel()
        do {
            _ = try await loader.download(try XCTUnwrap(URL(string: "https://github.com/user-attachments/assets/id")), token: nil)
            XCTFail("Cancelled download succeeded")
        } catch is CancellationError { }
    }
}
