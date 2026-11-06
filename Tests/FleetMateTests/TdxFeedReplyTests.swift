import XCTest
@testable import FleetMateCore

/// Threaded feed replies, added to the TDX Web API in 12.3.
///
/// The shapes come from the Web API's published OpenAPI document (operations
/// `Feed_AddReply` and `Feed_DeleteReply`): the request is `FeedReplyRequest`,
/// a single required `Body` read as rich HTML with `additionalProperties:
/// false`, and the response is `ItemUpdateReply`.
final class TdxFeedReplyTests: XCTestCase {

    private func makeService() -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxTicketingAppId = 115
        config.tdxAppId = 115
        config.tdxAuthMethod = .serviceAccount
        config.tdxBeid = "test-beid"
        config.tdxWebServicesKey = "test-key"
        return TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
    }

    private func stubs(_ extra: [StubURLProtocol.Stub]) -> [StubURLProtocol.Stub] {
        [StubURLProtocol.Stub(pathContains: "/api/auth/loginadmin", body: "\"stub-token\"")] + extra
    }

    // MARK: - Request body

    func testPlainTextIsEscapedIntoHtml() {
        let request = TdxFeedReplyRequest(text: "a < b && c > \"d\" 'e'")
        XCTAssertEqual(request.body, "a &lt; b &amp;&amp; c &gt; &quot;d&quot; &#39;e&#39;")
    }

    func testLineBreaksBecomeBreakTags() {
        XCTAssertEqual(TdxFeedReplyRequest(text: "one\ntwo\r\nthree\rfour").body,
                       "one<br />two<br />three<br />four")
    }

    func testRichHtmlIsSentAsIs() {
        XCTAssertEqual(TdxFeedReplyRequest(text: "<p>Done</p>", isRichHtml: true).body, "<p>Done</p>")
    }

    func testBodyIsTheOnlyEncodedField() throws {
        let data = try JSONEncoder().encode(TdxFeedReplyRequest(text: "Thanks"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["Body"])
        XCTAssertEqual(object["Body"] as? String, "Thanks")
    }

    // MARK: - Post reply

    func testReplyPostsBodyToTheEntrysRepliesRoute() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/feed/700/replies", method: "POST", statusCode: 201, body: """
            {"ID":9001,"Body":"Sounds good<br />Thanks","CreatedFullName":"Sample Person",
             "CreatedUid":"00000000-0000-0000-0000-000000000001","IsRichHtml":true}
            """)
        ]))

        let reply = try await makeService().replyToFeedEntry(entryId: 700, body: "Sounds good\nThanks")

        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(StubURLProtocol.apiCalls.count, 1)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/feed/700/replies")
        XCTAssertEqual(call.headers["Authorization"], "Bearer stub-token")
        XCTAssertEqual(call.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(call.jsonObject)
        XCTAssertEqual(body.keys.sorted(), ["Body"])
        XCTAssertEqual(body["Body"] as? String, "Sounds good<br />Thanks")

        XCTAssertEqual(reply.id, 9001)
        XCTAssertEqual(reply.createdFullName, "Sample Person")
        XCTAssertEqual(reply.createdUid, "00000000-0000-0000-0000-000000000001")
    }

    func testBlankReplyNeverLeavesTheApp() async throws {
        StubURLProtocol.reset(stubs: stubs([]))

        do {
            _ = try await makeService().replyToFeedEntry(entryId: 700, body: "  \n ")
            XCTFail("a blank reply should throw")
        } catch let error as TdxFeedReplyError {
            XCTAssertEqual(error, .emptyBody)
        }
        XCTAssertTrue(StubURLProtocol.apiCalls.isEmpty)
    }

    func testRefusedReplyReportsItsStatus() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/feed/700/replies", method: "POST", statusCode: 403, body: "{}")
        ]))

        do {
            _ = try await makeService().replyToFeedEntry(entryId: 700, body: "Hello")
            XCTFail("a 403 should throw")
        } catch let error as TdxFeedReplyError {
            XCTAssertEqual(error, .requestFailed(403))
        }
    }

    // MARK: - Delete reply

    func testDeleteTargetsTheReplyUnderItsParent() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/feed/700/replies/9001", method: "DELETE", statusCode: 204, body: "")
        ]))

        try await makeService().deleteFeedReply(entryId: 700, replyId: 9001)

        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(StubURLProtocol.apiCalls.count, 1)
        XCTAssertEqual(call.method, "DELETE")
        XCTAssertEqual(call.path, "/TDWebApi/api/feed/700/replies/9001")
    }

    func testFailedDeleteThrows() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/feed/700/replies/9001", method: "DELETE", statusCode: 404, body: "")
        ]))

        do {
            try await makeService().deleteFeedReply(entryId: 700, replyId: 9001)
            XCTFail("a 404 should throw")
        } catch let error as TdxFeedReplyError {
            XCTAssertEqual(error, .requestFailed(404))
        }
    }

    // MARK: - Model

    func testFeedEntryKeepsItsAuthorUidThroughHydration() throws {
        let json = #"{"ID":1,"CreatedUid":"00000000-0000-0000-0000-000000000002","RepliesCount":0}"#
        let entry = try JSONDecoder().decode(TdxFeedEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.withReplies([]).createdUid, "00000000-0000-0000-0000-000000000002")
    }
}
