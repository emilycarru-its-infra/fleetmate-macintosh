import XCTest
@testable import FleetMateCore

/// Feed entry HTML split into text, links and images, how image sources
/// resolve, and which image requests may carry the TDX session.
final class TdxFeedBodyTests: XCTestCase {

    private let webRoot = URL(string: "https://tdx.example.edu")!
    private let apiBase = URL(string: "https://tdx.example.edu/TDWebApi")!

    // MARK: - Parsing

    /// The shape TDX's own image uploader writes: a thumbnail in `src`, the
    /// original in `data-image-url`, entities in the query string.
    func testUploaderImageUsesFullSizeAndKeepsThumbnailAsFallback() {
        let html = #"<img alt="Uploaded image" data-image-url="https://tdx.example.edu/TDPortal/Images/Viewer?fileName=00000000-aaaa.jpg&amp;beidInt=1" src="https://tdx.example.edu/TDPortal/Images/Viewer?fileName=00000000-aaaa-thumb.jpg&amp;beidInt=1" referrerpolicy="no-referrer" class="img-responsive" title="Click to View Full Image">"#
        let body = TdxFeedBody.parse(html, webRoot: webRoot)

        XCTAssertEqual(body.segments.count, 1)
        let image = try! XCTUnwrap(body.images.first)
        XCTAssertEqual(image.source, .remote(URL(string: "https://tdx.example.edu/TDPortal/Images/Viewer?fileName=00000000-aaaa.jpg&beidInt=1")!))
        XCTAssertEqual(image.fallback, .remote(URL(string: "https://tdx.example.edu/TDPortal/Images/Viewer?fileName=00000000-aaaa-thumb.jpg&beidInt=1")!))
        XCTAssertEqual(image.alt, "Uploaded image")
        XCTAssertEqual(image.suggestedFileName, "00000000-aaaa.jpg")
    }

    func testImageOnlyBodyIsNotEmpty() {
        let body = TdxFeedBody.parse(#"<p><img src="https://tdx.example.edu/x.png"></p>"#, webRoot: webRoot)
        XCTAssertFalse(body.isEmpty)
        XCTAssertEqual(body.images.count, 1)
        XCTAssertEqual(body.plainText, "")
    }

    func testTextAroundAnImageSplitsIntoThreeSegments() {
        let body = TdxFeedBody.parse(#"<p>Before</p><img src="/a.png" alt=""><p>After</p>"#, webRoot: webRoot)
        XCTAssertEqual(body.segments, [
            .text([TdxTextRun("Before")]),
            .image(TdxBodyImage(source: .remote(URL(string: "https://tdx.example.edu/a.png")!), alt: nil)),
            .text([TdxTextRun("After")]),
        ])
    }

    func testLineBreaksAndEntities() {
        let body = TdxFeedBody.parse("One<br>Two&nbsp;&amp;&nbsp;three<br/><br/><br/>Four &amp;lt;tag&amp;gt; &#8217; &#x2014;", webRoot: webRoot)
        XCTAssertEqual(body.plainText, "One\nTwo & three\n\n\nFour &lt;tag&gt; ’ —".replacingOccurrences(of: "\n\n\n", with: "\n\n"))
    }

    func testAnchorKeepsItsTarget() {
        let body = TdxFeedBody.parse(#"See <a href="https://docs.example.org/guide" target="_blank">the guide</a> first."#, webRoot: webRoot)
        XCTAssertEqual(body.segments, [.text([
            TdxTextRun("See "),
            TdxTextRun("the guide", link: URL(string: "https://docs.example.org/guide")!),
            TdxTextRun(" first."),
        ])])
    }

    func testBareUrlAndEmailBecomeLinks() {
        let body = TdxFeedBody.parse("Mail someone@example.org or visit https://example.org/help today", webRoot: webRoot)
        guard case .text(let runs) = body.segments.first else { return XCTFail("expected text") }
        let links = runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "mailto:someone@example.org")!, URL(string: "https://example.org/help")!])
        XCTAssertEqual(runs.map(\.text).joined(), "Mail someone@example.org or visit https://example.org/help today")
    }

    func testUnsafeAnchorSchemesStayText() {
        let body = TdxFeedBody.parse(#"<a href="javascript:alert(1)">click</a>"#, webRoot: webRoot)
        XCTAssertEqual(body.segments, [.text([TdxTextRun("click")])])
    }

    func testRelativeAnchorResolvesAgainstWebRoot() {
        let body = TdxFeedBody.parse(#"<a href="/TDNext/Home">home</a>"#, webRoot: webRoot)
        guard case .text(let runs) = body.segments.first else { return XCTFail("expected text") }
        XCTAssertEqual(runs.first?.link, URL(string: "https://tdx.example.edu/TDNext/Home")!)
    }

    func testScriptAndStyleContentIsDropped() {
        let body = TdxFeedBody.parse("<style>p{color:red}</style><script>var x = '<img src=\"https://evil.example/x.png\">';</script>Hi", webRoot: webRoot)
        XCTAssertEqual(body.plainText, "Hi")
        XCTAssertTrue(body.images.isEmpty)
    }

    func testListItemsGetBullets() {
        let body = TdxFeedBody.parse("<ul><li>one</li><li>two</li></ul>", webRoot: webRoot)
        XCTAssertEqual(body.plainText, "• one\n• two")
    }

    func testDataSrcAttributeIsNotMistakenForSrc() {
        let body = TdxFeedBody.parse(#"<img data-src="https://tdx.example.edu/lazy.png" src="https://tdx.example.edu/real.png">"#, webRoot: webRoot)
        XCTAssertEqual(body.images.first?.source, .remote(URL(string: "https://tdx.example.edu/real.png")!))
    }

    func testSingleQuotedAndUnquotedAttributes() {
        XCTAssertEqual(TdxFeedBody.attribute("src", in: "img src='a.png' alt=x"), "a.png")
        XCTAssertEqual(TdxFeedBody.attribute("alt", in: "img src='a.png' alt=x"), "x")
    }

    // MARK: - Source resolution

    func testDataUriDecodes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let src = "data:image/png;base64,\(png.base64EncodedString())"
        XCTAssertEqual(TdxBodyImageResolver.resolve(src, webRoot: webRoot), .inline(data: png, mimeType: "image/png"))
    }

    func testDataUriWithNonImageTypeIsRefused() {
        XCTAssertNil(TdxBodyImageResolver.resolve("data:text/html;base64,PGgxPmhpPC9oMT4=", webRoot: webRoot))
    }

    func testDataUriImageInBodyIsAnInlineSegment() {
        let gif = Data("GIF89a".utf8)
        let body = TdxFeedBody.parse(#"<img src="data:image/gif;base64,\#(gif.base64EncodedString())">"#, webRoot: webRoot)
        XCTAssertEqual(body.images.first?.source, .inline(data: gif, mimeType: "image/gif"))
        XCTAssertEqual(body.images.first?.suggestedFileName, "image.gif")
    }

    func testRootRelativePathResolvesToWebRoot() {
        XCTAssertEqual(
            TdxBodyImageResolver.resolve("/TDNext/Apps/1/Tickets/Image?id=5", webRoot: URL(string: "https://tdx.example.edu/")!),
            .remote(URL(string: "https://tdx.example.edu/TDNext/Apps/1/Tickets/Image?id=5")!)
        )
    }

    func testProtocolRelativeBecomesHttps() {
        XCTAssertEqual(TdxBodyImageResolver.resolve("//cdn.example.org/x.png", webRoot: webRoot),
                       .remote(URL(string: "https://cdn.example.org/x.png")!))
    }

    func testUnloadableSchemesResolveToNothing() {
        XCTAssertNil(TdxBodyImageResolver.resolve("cid:image001.png@01D", webRoot: webRoot))
        XCTAssertNil(TdxBodyImageResolver.resolve("file:///etc/passwd", webRoot: webRoot))
        XCTAssertNil(TdxBodyImageResolver.resolve("javascript:alert(1)", webRoot: webRoot))
        XCTAssertNil(TdxBodyImageResolver.resolve("", webRoot: webRoot))
        XCTAssertNil(TdxBodyImageResolver.resolve("relative.png", webRoot: nil))
    }

    func testWebRootDropsApiSuffix() {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi/"
        XCTAssertEqual(config.tdxWebRootUrl, URL(string: "https://tdx.example.edu")!)
        config.tdxBaseUrl = nil
        XCTAssertNil(config.tdxWebRootUrl)
    }

    // MARK: - Credentials

    func testCredentialsGoOnlyToTheTdxHostOverHttps() {
        XCTAssertTrue(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://tdx.example.edu/TDPortal/Images/Viewer?fileName=a.jpg")!, tdxBase: apiBase))
        XCTAssertTrue(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://TDX.EXAMPLE.EDU:443/a.png")!, tdxBase: apiBase))

        XCTAssertFalse(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "http://tdx.example.edu/a.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://images.example.org/a.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://tdx.example.edu.attacker.example/a.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://sub.tdx.example.edu/a.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://tdx.example.edu:8443/a.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.sendsTdxCredentials(
            to: URL(string: "https://tdx.example.edu/a.png")!, tdxBase: nil))
    }

    func testOnlyHttpsImagesLoad() {
        XCTAssertTrue(TdxImageAuthPolicy.mayLoad(URL(string: "https://images.example.org/a.png")!))
        XCTAssertFalse(TdxImageAuthPolicy.mayLoad(URL(string: "http://images.example.org/a.png")!))
        XCTAssertFalse(TdxImageAuthPolicy.mayLoad(URL(string: "ftp://images.example.org/a.png")!))
    }

    func testCredentialedRedirectMustStayOnHost() {
        XCTAssertTrue(TdxImageAuthPolicy.mayFollowRedirect(to: URL(string: "https://tdx.example.edu/other.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.mayFollowRedirect(to: URL(string: "https://login.example.com/sso")!, tdxBase: apiBase))
    }

    func testImageSniffing() {
        XCTAssertTrue(TdxImageAuthPolicy.looksLikeImage(Data([0xFF, 0xD8, 0xFF, 0xE0]), contentType: "application/octet-stream"))
        XCTAssertTrue(TdxImageAuthPolicy.looksLikeImage(Data("GIF89a".utf8), contentType: nil))
        XCTAssertTrue(TdxImageAuthPolicy.looksLikeImage(Data([1, 2, 3]), contentType: "image/jpeg"))
        XCTAssertFalse(TdxImageAuthPolicy.looksLikeImage(Data("<html>sign in</html>".utf8), contentType: "text/html; charset=utf-8"))
        XCTAssertFalse(TdxImageAuthPolicy.looksLikeImage(Data("{}".utf8), contentType: "application/json"))
        XCTAssertFalse(TdxImageAuthPolicy.looksLikeImage(Data(), contentType: "image/png"))
    }

    // MARK: - Requests on the wire

    private func makeService() -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxTicketingAppId = 900
        config.tdxAppId = 900
        config.tdxAuthMethod = .browserSSO
        let service = TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
        service.setSsoToken("eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.sig", expiry: Date().addingTimeInterval(3600))
        return service
    }

    func testTdxHostImageCarriesTheBearerToken() async throws {
        StubURLProtocol.reset(stubs: [StubURLProtocol.Stub(pathContains: "/TDPortal/Images/Viewer", body: "GIF89a-stub")])
        let service = makeService()

        let data = try await service.fetchBodyImage(URL(string: "https://tdx.example.edu/TDPortal/Images/Viewer?fileName=a.jpg")!)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "GIF89a-stub")
        let request = try XCTUnwrap(StubURLProtocol.recorded.last)
        XCTAssertEqual(request.headers["Authorization"], "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.sig")
    }

    func testOtherHostImageLoadsWithoutCredentials() async throws {
        StubURLProtocol.reset(stubs: [StubURLProtocol.Stub(pathContains: "/meme.gif", body: "GIF89a-elsewhere")])
        let service = makeService()

        _ = try await service.fetchBodyImage(URL(string: "https://images.example.org/meme.gif")!)

        let request = try XCTUnwrap(StubURLProtocol.recorded.last)
        XCTAssertEqual(request.url.host, "images.example.org")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.headers["Cookie"])
    }

    func testHttpImageIsRefusedWithoutARequest() async {
        StubURLProtocol.reset(stubs: [])
        let service = makeService()
        do {
            _ = try await service.fetchBodyImage(URL(string: "http://images.example.org/a.png")!)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
        }
    }

    func testNonImageResponseIsAnError() async {
        StubURLProtocol.reset(stubs: [StubURLProtocol.Stub(pathContains: "/login", body: "{\"error\":\"sign in\"}")])
        let service = makeService()
        do {
            _ = try await service.fetchBodyImage(URL(string: "https://tdx.example.edu/login")!)
            XCTFail("expected notAnImage")
        } catch let error as TdxBodyImageError {
            if case .notAnImage = error {} else { XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
