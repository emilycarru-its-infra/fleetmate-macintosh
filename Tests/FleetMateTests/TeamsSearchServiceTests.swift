import XCTest
@testable import FleetMateCore

/// The Teams search client against a stubbed transport: what it puts on the
/// wire, how it decodes the API's JSON, and how each refusal surfaces.
final class TeamsSearchServiceTests: XCTestCase {

    private let base = "https://search.example.org/api/"
    private let scope = "api://example-search/.default"

    /// Records every token request so a test can see the scope and refreshes.
    private final class TokenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(scope: String, refresh: Bool)] = []
        var calls: [(scope: String, refresh: Bool)] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ scope: String, _ refresh: Bool) { lock.lock(); _calls.append((scope, refresh)); lock.unlock() }
    }

    private func service(_ log: TokenLog = TokenLog()) -> TeamsSearchService {
        TeamsSearchService(baseUrl: base, scope: scope,
                           sessionConfiguration: StubURLProtocol.sessionConfiguration(),
                           tokenProvider: { scope, refresh in
                               log.record(scope, refresh)
                               return refresh ? "fresh-token" : "cached-token"
                           })
    }

    private let searchBody = """
    {"query":"printer","as_of":"2026-11-04T12:00:00Z","total":42,"results":[
      {"thread_id":"1730000000000","team_id":"team-1","team_name":"Service Desk","channel_id":"19:abc@thread.tacv2",
       "channel_name":"General","subject":null,"snippet":"The printer on level 2 is jammed",
       "author_display_name":"Alex Example","created_at":"2026-11-01T17:30:00.123Z",
       "last_activity_at":"2026-11-02T09:00:00Z","reply_count":3,"participants":["Alex Example","Sam Example"],
       "score":12.5,"web_url":"https://teams.example.org/l/message/1"}
    ]}
    """

    // MARK: Configuration

    func testUnconfiguredServiceRefusesWithoutARequest() async throws {
        StubURLProtocol.reset(stubs: [])
        for svc in [TeamsSearchService(baseUrl: nil, scope: scope), TeamsSearchService(baseUrl: base, scope: "  ")] {
            XCTAssertFalse(svc.isConfigured)
            do {
                _ = try await svc.channels()
                XCTFail("an unconfigured service must refuse")
            } catch let error as TeamsSearchError {
                XCTAssertEqual(error, .notConfigured)
            }
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    // MARK: URL building

    func testSearchURLCarriesEveryFilterEncoded() throws {
        let url = try service().searchURL(TeamsSearchQuery(
            text: "  C++ & \"wifi\" #help ", team: "team-1", channel: "19:abc@thread.tacv2",
            author: "Alex", since: "2026-10-01", until: "2026-11-01", limit: 50))
        XCTAssertEqual(url.absoluteString,
                       "https://search.example.org/api/v1/teams/search?q=C%2B%2B%20%26%20%22wifi%22%20%23help"
                       + "&team=team-1&channel=19%3Aabc%40thread.tacv2&author=Alex&since=2026-10-01&until=2026-11-01&limit=50")
    }

    func testSearchURLOmitsUnsetFilters() throws {
        let url = try service().searchURL(TeamsSearchQuery(text: "vpn", team: "", author: nil))
        XCTAssertEqual(url.absoluteString, "https://search.example.org/api/v1/teams/search?q=vpn")
    }

    func testSearchRejectsBadArguments() {
        let svc = service()
        XCTAssertThrowsError(try svc.searchURL(TeamsSearchQuery(text: "   ")))
        XCTAssertThrowsError(try svc.searchURL(TeamsSearchQuery(text: "x", limit: 0)))
        XCTAssertThrowsError(try svc.searchURL(TeamsSearchQuery(text: "x", limit: 101)))
        XCTAssertThrowsError(try svc.searchURL(TeamsSearchQuery(text: "x", since: "2026-13-01")))
        XCTAssertThrowsError(try svc.searchURL(TeamsSearchQuery(text: "x", until: "yesterday")))
        XCTAssertNoThrow(try svc.searchURL(TeamsSearchQuery(text: "x", limit: 100)))
    }

    func testThreadURLEncodesIdAndRequiresChannel() throws {
        let svc = service()
        XCTAssertEqual(try svc.threadURL(id: "17/30", channel: "19:abc@thread.tacv2").absoluteString,
                       "https://search.example.org/api/v1/teams/threads/17%2F30?channel=19%3Aabc%40thread.tacv2")
        XCTAssertThrowsError(try svc.threadURL(id: "1", channel: " "))
        XCTAssertThrowsError(try svc.threadURL(id: "", channel: "c"))
    }

    // MARK: Requests

    func testSearchSendsBearerForConfiguredScopeAndDecodes() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/search", body: searchBody)])
        let log = TokenLog()

        let payload = try await service(log).search(TeamsSearchQuery(text: "printer", limit: 5))

        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v1/teams/search")
        XCTAssertEqual(request.headers["Authorization"], "Bearer cached-token")
        XCTAssertEqual(log.calls.map(\.scope), [scope])

        let response = payload.value
        XCTAssertEqual(response.total, 42)
        XCTAssertEqual(response.asOf, "2026-11-04T12:00:00Z")
        let hit = try XCTUnwrap(response.results.first)
        XCTAssertEqual(hit.threadId, "1730000000000")
        XCTAssertEqual(hit.channelName, "General")
        XCTAssertNil(hit.subject)
        XCTAssertEqual(hit.replyCount, 3)
        XCTAssertEqual(hit.participants.count, 2)
        XCTAssertEqual(hit.webUrl, "https://teams.example.org/l/message/1")
        XCTAssertEqual(payload.raw, Data(searchBody.utf8), "--json passes the API's bytes through")
    }

    func testThreadDecodesMessagesOldestFirst() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/threads/", body: """
        {"thread_id":"t1","team_id":"team-1","team_name":"Service Desk","channel_id":"c1","channel_name":"General",
         "subject":"Printer","web_url":null,"messages":[
          {"message_id":"t1","reply_to_id":null,"author_display_name":"Alex Example","created_at":"2026-11-01T17:30:00Z",
           "edited_at":null,"text":"Jammed again","attachments":[],"web_url":null},
          {"message_id":"m2","reply_to_id":"t1","author_display_name":null,"created_at":"2026-11-01T18:00:00Z",
           "edited_at":"2026-11-01T18:05:00Z","text":"Fixed","attachments":[{"name":"photo.jpg","url":null}],"web_url":null}
        ]}
        """)])

        let thread = try await service().thread(id: "t1", channel: "c1").value

        XCTAssertEqual(StubURLProtocol.recorded.first?.query, "channel=c1")
        XCTAssertEqual(thread.subject, "Printer")
        XCTAssertEqual(thread.messages.map(\.messageId), ["t1", "m2"])
        XCTAssertEqual(thread.messages[1].replyToId, "t1")
        XCTAssertNil(thread.messages[1].authorDisplayName)
        XCTAssertEqual(thread.messages[1].attachments, [TeamsAttachment(name: "photo.jpg", url: nil)])
    }

    func testChannelsDecode() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/channels", body: """
        {"as_of":null,"channels":[{"team_id":"team-1","team_name":"Service Desk","channel_id":"c1","channel_name":"General",
          "membership_type":"standard","threads":120,"last_activity_at":null},
         {"team_id":"team-2","team_name":"Projects","channel_id":"c2","channel_name":"Shared work",
          "membership_type":"shared","threads":4,"last_activity_at":"2026-11-03T08:00:00Z"}]}
        """)])

        let response = try await service().channels().value

        XCTAssertEqual(StubURLProtocol.recorded.first?.path, "/api/v1/teams/channels")
        XCTAssertNil(response.asOf)
        XCTAssertEqual(response.channels.map(\.membershipType), ["standard", "shared"])
        XCTAssertEqual(response.channels[0].threads, 120)
    }

    // MARK: Errors

    func testUnauthorizedRetriesOnceWithAFreshToken() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/channels", statusCode: 401, body: #"{"detail":"expired"}"#)])
        let log = TokenLog()

        await assertError(.unauthorized) { _ = try await self.service(log).channels() }

        XCTAssertEqual(log.calls.map(\.refresh), [false, true])
        XCTAssertEqual(StubURLProtocol.recorded.map { $0.headers["Authorization"] },
                       ["Bearer cached-token", "Bearer fresh-token"])
    }

    func testForbiddenAndIndexNotReadyAndNotFoundMapToTheirOwnErrors() async throws {
        for (status, expected) in [(403, TeamsSearchError.forbidden), (503, .indexNotReady), (404, .notFound)] {
            StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/", statusCode: status, body: #"{"detail":"no"}"#)])
            await assertError(expected) { _ = try await self.service().channels() }
            XCTAssertEqual(StubURLProtocol.recorded.count, 1, "only a 401 is retried")
        }
        XCTAssertTrue(TeamsSearchError.forbidden.description.contains("not authorized"))
    }

    func testOtherFailuresCarrySanitisedDetail() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/search", statusCode: 422,
                                            body: #"{"detail":"bad \u001b[31mlimit"}"#)])
        await assertError(.http(422, "bad [31mlimit")) {
            _ = try await self.service().search(TeamsSearchQuery(text: "x"))
        }
    }

    func testMalformedBodyIsAnInvalidResponse() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/v1/teams/channels", body: #"{"channels":"nope"}"#)])
        do {
            _ = try await service().channels()
            XCTFail("expected a decode failure")
        } catch let error as TeamsSearchError {
            guard case .invalidResponse = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: Display helpers

    func testTerminalSafeStripsEscapesAndBidiButKeepsNewlines() {
        let hostile = "ok\u{1B}]0;title\u{07}\r\nline2\u{202E}txt\tend"
        XCTAssertEqual(TeamsText.terminalSafe(hostile), "ok]0;title\nline2txt\tend")
        XCTAssertEqual(TeamsText.oneLine("a\n\n  b\tc"), "a b c")
    }

    func testLocalTimeParsesApiTimestamps() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TeamsText.localTime("2026-11-01T17:30:00.123Z", timeZone: utc), "2026-11-01 17:30")
        XCTAssertEqual(TeamsText.localTime("2026-11-01T17:30:00+00:00", timeZone: utc), "2026-11-01 17:30")
        XCTAssertEqual(TeamsText.localTime("2026-11-01T17:30:00", timeZone: utc), "2026-11-01 17:30")
        XCTAssertEqual(TeamsText.localTime("2026-11-01T17:30:00Z", timeZone: TimeZone(secondsFromGMT: -7 * 3600)!), "2026-11-01 10:30")
        XCTAssertEqual(TeamsText.localTime(nil), "-")
        XCTAssertEqual(TeamsText.localTime("soon"), "soon")
    }

    // MARK: Helpers

    private func assertError(_ expected: TeamsSearchError, file: StaticString = #filePath, line: UInt = #line,
                             _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as TeamsSearchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
