import XCTest
@testable import FleetMateCore

/// The multipart body a comment's attachment goes up in, and the requests that
/// carry it and the Reassign search.
final class TdxAttachmentUploadTests: XCTestCase {

    private let appId = 900

    private func makeService() -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxTicketingAppId = appId
        config.tdxAppId = appId
        config.tdxAuthMethod = .serviceAccount
        config.tdxBeid = "test-beid"
        config.tdxWebServicesKey = "test-key"
        return TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
    }

    private func stubs(_ extra: [StubURLProtocol.Stub]) -> [StubURLProtocol.Stub] {
        [StubURLProtocol.Stub(pathContains: "/api/auth/loginadmin", body: "\"stub-token\"")] + extra
    }

    // MARK: - Multipart body

    func testBodyIsOneFilePartBetweenBoundaries() {
        let payload = Data("hello, ticket".utf8)
        let form = TdxMultipartForm(fileName: "notes.txt", data: payload, boundary: "XYZ")

        let expected = "--XYZ\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\n"
            + "Content-Type: text/plain\r\n\r\n"
            + "hello, ticket"
            + "\r\n--XYZ--\r\n"
        XCTAssertEqual(String(data: form.body, encoding: .utf8), expected)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=XYZ")
    }

    func testBinaryPayloadIsCopiedByteForByte() {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0D, 0x0A])
        let form = TdxMultipartForm(fileName: "image.png", data: payload, boundary: "B")

        let header = Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        let footer = Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(form.body, header + payload + footer)
    }

    func testMimeTypeFollowsExtension() {
        XCTAssertEqual(TdxMultipartForm.mimeType(forFileName: "a.pdf"), "application/pdf")
        XCTAssertEqual(TdxMultipartForm.mimeType(forFileName: "a.PNG"), "image/png")
        XCTAssertEqual(TdxMultipartForm.mimeType(forFileName: "a.jpeg"), "image/jpeg")
        XCTAssertEqual(TdxMultipartForm.mimeType(forFileName: "no-extension"), "application/octet-stream")
        XCTAssertEqual(TdxMultipartForm.mimeType(forFileName: "a.unknownext123"), "application/octet-stream")
    }

    func testExplicitMimeTypeWins() {
        let form = TdxMultipartForm(fileName: "a.log", data: Data(), mimeType: "text/x-log", boundary: "B")
        XCTAssertTrue(String(decoding: form.body, as: UTF8.self).contains("Content-Type: text/x-log\r\n"))
    }

    func testQuotesAndPathsCannotBreakTheHeader() {
        let form = TdxMultipartForm(fileName: "/tmp/dir/say \"hi\".txt", data: Data(), boundary: "B")
        let text = String(decoding: form.body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"filename="say \"hi\".txt""#), text)
        XCTAssertFalse(text.contains("/tmp/dir"))
    }

    func testLineBreaksInNameAreDropped() {
        let form = TdxMultipartForm(fileName: "evil\r\nX-Injected: 1.txt", data: Data(), boundary: "B")
        let text = String(decoding: form.body, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nX-Injected"))
        XCTAssertTrue(text.contains(#"filename="evilX-Injected: 1.txt""#), text)
    }

    func testNonAsciiNameGetsRfc5987Parameter() {
        let form = TdxMultipartForm(fileName: "café.txt", data: Data(), boundary: "B")
        let text = String(decoding: form.body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"filename="caf_.txt"; filename*=UTF-8''caf%C3%A9.txt"#), text)
    }

    func testEmptyNameFallsBack() {
        let form = TdxMultipartForm(fileName: "  ", data: Data(), boundary: "B")
        XCTAssertTrue(String(decoding: form.body, as: UTF8.self).contains(#"filename="attachment""#))
    }

    func testDefaultBoundaryIsUniquePerForm() {
        let a = TdxMultipartForm(fileName: "a.txt", data: Data())
        let b = TdxMultipartForm(fileName: "a.txt", data: Data())
        XCTAssertNotEqual(a.boundary, b.boundary)
    }

    // MARK: - Upload request

    func testUploadPostsMultipartToTicketAttachments() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/42/attachments", method: "POST",
                                 body: #"{"ID":"att-1","Name":"report.pdf","Size":3}"#)
        ]))

        let attachment = try await makeService().uploadAttachment(
            ticketId: 42, fileName: "report.pdf", data: Data("pdf".utf8), isPrivate: true)

        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/42/attachments")
        XCTAssertEqual(call.query, "isPrivate=true")
        let contentType = try XCTUnwrap(call.headers["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        XCTAssertEqual(call.headers["Authorization"], "Bearer stub-token")

        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = String(decoding: try XCTUnwrap(call.body), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(body.contains(#"name="file"; filename="report.pdf""#))
        XCTAssertTrue(body.contains("Content-Type: application/pdf\r\n\r\npdf\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))

        XCTAssertEqual(attachment?.id, "att-1")
    }

    func testUploadFailureNamesTheFileAndReason() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/attachments", method: "POST", statusCode: 413, body: "")
        ]))

        do {
            try await makeService().uploadAttachment(ticketId: 42, fileName: "huge.mov", data: Data("x".utf8))
            XCTFail("expected a failure")
        } catch let error as TdxUploadError {
            XCTAssertEqual(error.statusCode, 413)
            XCTAssertEqual(error.localizedDescription, "huge.mov: the file is larger than TeamDynamix accepts")
        }
    }

    // MARK: - Eligible responsibles

    func testEligibleResponsiblesSearchTheTicketingAppResources() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/resources", body: """
            [{"Name":"Pat Example","Value":"00000000-0000-0000-0000-000000000001","Email":"pat@example.edu","IsUser":true},
             {"Name":"Example Group","Value":"77","Email":null,"IsUser":false}]
            """)
        ]))
        let service = makeService()

        let found = try await service.searchEligibleResponsibles(searchText: "  Ex&ample ")

        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/resources")
        XCTAssertEqual(call.query, "searchText=ex%26ample")

        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found[0].isUser)
        XCTAssertEqual(found[0].email, "pat@example.edu")
        XCTAssertNil(found[0].groupId)
        XCTAssertFalse(found[1].isUser)
        XCTAssertEqual(found[1].groupId, 77)
        XCTAssertNotEqual(found[0].id, found[1].id)

        // A repeat search is served from the cache.
        _ = try await service.searchEligibleResponsibles(searchText: "ex&ample")
        XCTAssertEqual(StubURLProtocol.apiCalls.filter { $0.path.hasSuffix("/tickets/resources") }.count, 1)
    }
}
