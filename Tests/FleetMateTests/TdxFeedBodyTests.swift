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
        XCTAssertEqual(image.fileName(for: Data([0xFF, 0xD8, 0xFF, 0xE0])), "00000000-aaaa.jpg")
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
        XCTAssertEqual(body.images.first?.fileName(for: gif), "image.gif")
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
        // The server's word is not enough: the bytes decide.
        XCTAssertFalse(TdxImageAuthPolicy.looksLikeImage(Data([1, 2, 3]), contentType: "image/jpeg"))
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

    // MARK: - File names (path traversal)

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    func testSanitizedBaseNameRefusesTraversalAndOddNames() {
        XCTAssertEqual(TdxImageFileNaming.sanitizedBaseName("screenshot.png"), "screenshot")
        XCTAssertEqual(TdxImageFileNaming.sanitizedBaseName("a/b/c.png"), "c")
        XCTAssertEqual(TdxImageFileNaming.sanitizedBaseName("..%2F..%2Fetc%2Fpasswd"), "passwd")
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName(".."))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName("%2E%2E"))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName(".hidden"))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName("a:b.png"))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName("bad\u{0}name.png"))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName("line%0Abreak.png"))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName("a..b.png"))
        XCTAssertNil(TdxImageFileNaming.sanitizedBaseName(""))
        XCTAssertEqual(TdxImageFileNaming.sanitizedBaseName("%252F..%252Fx.png"), "x")
    }

    func testFileNameFallsBackToImageWhenUrlNameIsUnsafe() {
        let image = TdxBodyImage(source: .remote(URL(string: "https://tdx.example.edu/Viewer?fileName=..%2F..%2F.ssh")!), alt: nil)
        XCTAssertEqual(image.fileName(for: png), "image.png")
    }

    func testExtensionComesFromBytesNotUrl() {
        let image = TdxBodyImage(source: .remote(URL(string: "https://images.example.org/payload.command")!), alt: nil)
        XCTAssertEqual(image.fileName(for: png), "payload.png")
        let viewer = TdxBodyImage(source: .remote(URL(string: "https://tdx.example.edu/Viewer?fileName=shot.html")!), alt: nil)
        XCTAssertEqual(viewer.fileName(for: jpeg), "shot.jpg")
        XCTAssertNil(image.fileName(for: Data("<html></html>".utf8)))
    }

    func testImageTypeSniffing() {
        XCTAssertEqual(TdxImageType.sniff(png), .png)
        XCTAssertEqual(TdxImageType.sniff(jpeg), .jpeg)
        XCTAssertEqual(TdxImageType.sniff(Data("GIF87a".utf8)), .gif)
        XCTAssertEqual(TdxImageType.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), .webp)
        XCTAssertEqual(TdxImageType.sniff(Data([0x4D, 0x4D, 0x00, 0x2A])), .tiff)
        XCTAssertEqual(TdxImageType.sniff(Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8)), .heic)
        XCTAssertNil(TdxImageType.sniff(Data([0, 0, 0, 0x18]) + Data("ftypmp42".utf8)))
        XCTAssertNil(TdxImageType.sniff(Data("BM".utf8)))
        XCTAssertNil(TdxImageType.sniff(Data("<svg/>".utf8)))
    }

    // MARK: - Staging

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TdxFeedBodyTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testStageWritesInsideDirectoryAndQuarantines() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TdxImageStaging.stage(png, fileName: "shot.png", in: dir)
        XCTAssertEqual(url.lastPathComponent, "shot.png")
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertTrue(TdxImageStaging.quarantineValue(url)?.hasPrefix("0081;") == true)
    }

    func testStageRefusesNamesThatEscapeTheDirectory() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["../escape.png", "../../escape.png", "sub/escape.png", "..", "."] {
            XCTAssertThrowsError(try TdxImageStaging.stage(png, fileName: name, in: dir), name) { error in
                XCTAssertEqual(error as? TdxImageStaging.StagingError, .outsideDirectory, name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.png").path))
    }

    func testStageRefusesNonImageBytes() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try TdxImageStaging.stage(Data("#!/bin/sh".utf8), fileName: "x.png", in: dir)) { error in
            XCTAssertEqual(error as? TdxImageStaging.StagingError, .notAnImage)
        }
    }

    // MARK: - Size limit

    func testDeclaredContentLengthOverLimitIsRefused() async {
        StubURLProtocol.reset(stubs: [StubURLProtocol.Stub(
            pathContains: "/big.gif", body: "GIF89a", headers: ["Content-Length": "999999999", "Content-Type": "image/gif"])])
        let service = makeService()
        do {
            _ = try await service.fetchBodyImage(URL(string: "https://tdx.example.edu/big.gif")!)
            XCTFail("expected tooLarge")
        } catch let error as TdxBodyImageError {
            guard case .tooLarge = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStreamedBodyOverLimitIsAbandoned() async {
        StubURLProtocol.reset(stubs: [StubURLProtocol.Stub(
            pathContains: "/stream.gif", body: "GIF89a" + String(repeating: "x", count: 4096))])
        let service = makeService()
        service.bodyImageByteLimit = 1024
        do {
            _ = try await service.fetchBodyImage(URL(string: "https://tdx.example.edu/stream.gif")!)
            XCTFail("expected tooLarge")
        } catch let error as TdxBodyImageError {
            guard case .tooLarge = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBodyUnderLimitLoads() async throws {
        StubURLProtocol.reset(stubs: [StubURLProtocol.Stub(pathContains: "/small.gif", body: "GIF89a-small")])
        let service = makeService()
        service.bodyImageByteLimit = 1024
        let data = try await service.fetchBodyImage(URL(string: "https://tdx.example.edu/small.gif")!)
        XCTAssertEqual(data.count, 12)
    }

    // MARK: - External hosts

    func testTdxHostIsNotExternal() {
        XCTAssertTrue(TdxImageAuthPolicy.isTdxHost(URL(string: "https://tdx.example.edu/a.png")!, tdxBase: apiBase))
        XCTAssertFalse(TdxImageAuthPolicy.isTdxHost(URL(string: "https://images.example.org/a.png")!, tdxBase: apiBase))
    }

    func testLocalAndPrivateHostsAreRefusedForExternalImages() {
        let refused = [
            "https://127.0.0.1/a.png", "https://127.1/a.png", "https://2130706433/a.png", "https://0x7f.1/a.png",
            "https://10.1.2.3/a.png", "https://172.16.0.1/a.png", "https://172.31.255.255/a.png",
            "https://192.168.1.1/a.png", "https://169.254.169.254/latest/meta-data", "https://100.64.0.1/a.png",
            "https://0.0.0.0/a.png", "https://224.0.0.1/a.png",
            "https://[::1]/a.png", "https://[fe80::1]/a.png", "https://[fd00::1]/a.png",
            "https://[::ffff:192.168.0.1]/a.png", "https://[::ffff:7f00:1]/a.png",
            "https://localhost/a.png", "https://printer.local/a.png", "https://intranet/a.png",
            "https://app.localhost/a.png",
        ]
        for string in refused {
            XCTAssertFalse(TdxImageAuthPolicy.mayLoadExternal(URL(string: string)!), string)
        }
        let allowed = [
            "https://images.example.org/a.png", "https://93.184.216.34/a.png",
            "https://172.32.0.1/a.png", "https://[2606:4700::1111]/a.png",
        ]
        for string in allowed {
            XCTAssertTrue(TdxImageAuthPolicy.mayLoadExternal(URL(string: string)!), string)
        }
        XCTAssertFalse(TdxImageAuthPolicy.mayLoadExternal(URL(string: "http://images.example.org/a.png")!))
    }

    func testServiceRefusesPrivateAddressWithoutARequest() async {
        StubURLProtocol.reset(stubs: [])
        let service = makeService()
        do {
            _ = try await service.fetchBodyImage(URL(string: "https://169.254.169.254/a.png")!)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
        }
    }
}
