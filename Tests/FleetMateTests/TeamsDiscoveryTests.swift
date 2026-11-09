import XCTest
@testable import FleetMateCore

final class TeamsDiscoveryTests: XCTestCase {
    private func hit() throws -> TeamsSearchHit {
        try JSONDecoder().decode(TeamsSearchHit.self, from: Data("""
        {"threadId":"thread-a","teamId":"team-a","teamName":"Example Team","channelId":"channel-a","channelName":"General","subject":"A useful post","snippet":"BODY_SHOULD_NOT_BE_STORED","createdAt":"2026-11-01T10:00:00Z","lastActivityAt":"2026-11-02T10:00:00Z","replyCount":1,"participants":[],"score":0,"webUrl":"https://teams.microsoft.com/l/message/example"}
        """.utf8))
    }

    private func token(person: String, tenant: String = "tenant-a", name: String = "Example") throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["oid": person, "tid": tenant, "name": name])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    func testBrowseUsesScopedPagingWithoutAQuery() throws {
        let service = TeamsSearchService(baseUrl: "https://search.example.org", scope: "api://example/.default")
        let url = try service.browseURL(channel: "19:example@thread", author: "Example", since: "2026-11-01", limit: 30, offset: 60)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.path, "/v1/teams/threads")
        XCTAssertFalse(items.contains { $0.name == "q" })
        XCTAssertEqual(items.first { $0.name == "channel" }?.value, "19:example@thread")
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "60")
        XCTAssertThrowsError(try service.browseURL())
        XCTAssertThrowsError(try service.browseURL(channel: " "))
        XCTAssertThrowsError(try service.browseURL(team: "a", limit: 101))
        XCTAssertThrowsError(try service.browseURL(team: "a", offset: -1))
        XCTAssertThrowsError(try service.browseURL(team: "a", since: "yesterday"))
        XCTAssertThrowsError(try service.browseURL(team: "a", since: "2026-11-03", until: "2026-11-01"))
    }

    func testBrowseDecodesSnapshotAndNextPageThroughAuthorizedTransport() async throws {
        TeamsStub.reset(stubs: [.init(pathContains: "/v1/teams/threads", body: """
        {"as_of":"2026-11-01","index_version":"build-a","total":2,"results":[],"next_offset":1}
        """)])
        let service = TeamsSearchService(baseUrl: "https://search.example.org", scope: "api://example/.default",
                                        sessionConfiguration: StubURLProtocol.sessionConfiguration(),
                                        tokenProvider: { _, _ in "user-token" })
        let page = try await service.browse(channel: "channel-a", limit: 1).value
        XCTAssertEqual(page.indexVersion, "build-a")
        XCTAssertEqual(page.nextOffset, 1)
        XCTAssertEqual(StubURLProtocol.recorded.first?.headers["Authorization"], "Bearer user-token")
        XCTAssertEqual(StubURLProtocol.recorded.first?.headers[TeamsSearchService.purposeHeader], TeamsSearchService.defaultPurpose)
    }

    func testBookmarkScopeSeparatesAccountsAndEndpointsAndSurvivesDisplayNameChanges() throws {
        let endpoint = "https://search.example.org"
        let original = TeamsBookmarkScope.key(endpoint: endpoint, token: try token(person: "person-a"))
        XCTAssertNotNil(original)
        XCTAssertEqual(original, TeamsBookmarkScope.key(endpoint: endpoint + "/", token: try token(person: "person-a", name: "Renamed")))
        XCTAssertNotEqual(original, TeamsBookmarkScope.key(endpoint: endpoint, token: try token(person: "person-b")))
        XCTAssertNotEqual(original, TeamsBookmarkScope.key(endpoint: endpoint, token: try token(person: "person-a", tenant: "tenant-b")))
        XCTAssertNotEqual(original, TeamsBookmarkScope.key(endpoint: "https://other.example.org", token: try token(person: "person-a")))
        XCTAssertNil(TeamsBookmarkScope.key(endpoint: endpoint, token: "not-a-user-token"))
    }

    func testBookmarkPersistenceStoresReferencesAndPreservesCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeamsBookmarkStore(directory: directory, accountKey: String(repeating: "a", count: 64))
        let bookmark = TeamsBookmark(hit: try hit(), title: "Useful reference", collection: "Troubleshooting")
        try store.save([bookmark])
        XCTAssertEqual(try store.load(), [bookmark])
        XCTAssertEqual(bookmark.reference.snippet, "")
        XCTAssertEqual(bookmark.reference.channelId, "channel-a")
        let serialized = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains("BODY_SHOULD_NOT_BE_STORED"))
        XCTAssertFalse(serialized.contains("participants"))
        let other = try TeamsBookmarkStore(directory: directory, accountKey: String(repeating: "b", count: 64))
        XCTAssertTrue(try other.load().isEmpty)
        XCTAssertThrowsError(try TeamsBookmarkStore(directory: directory, accountKey: "../other"))
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testCopyIncludesEveryReplyAndOnlyAllowedReferenceLinks() throws {
        let thread = try JSONDecoder().decode(TeamsThread.self, from: Data("""
        {"threadId":"a","teamId":"a","teamName":"Example Team","channelId":"c","channelName":"General","subject":"Useful answer","webUrl":"https://teams.microsoft.com/l/message/example","messages":[{"messageId":"a","authorDisplayName":"Example Author","createdAt":"2026-11-01T10:00:00Z","text":"Root body [click](javascript:bad) <script>","attachments":[{"name":"Unsafe attachment","url":"javascript:bad"}]},{"messageId":"b","replyToId":"a","authorDisplayName":"Example Reply","createdAt":"2026-11-01T11:00:00Z","text":"The complete reply","attachments":[]}]}
        """.utf8))
        let hosts = TeamsLinkPolicy.defaultHosts
        let plain = TeamsThreadCopy.thread(thread, allowedHosts: hosts)
        XCTAssertTrue(plain.contains("The complete reply"))
        XCTAssertTrue(plain.contains("Example Author"))
        XCTAssertTrue(plain.contains("Source: https://teams.microsoft.com/"))
        XCTAssertFalse(plain.contains("Unsafe attachment: javascript"))
        let markdown = TeamsThreadCopy.thread(thread, allowedHosts: hosts, markdown: true)
        XCTAssertTrue(markdown.contains("# Useful answer"))
        XCTAssertTrue(markdown.contains("\\[click\\]"))
        XCTAssertTrue(markdown.contains("&lt;script&gt;"))
        XCTAssertFalse(markdown.contains("[click](javascript:"))
    }

    func testFollowingPreferencesPreserveBookmarksAndOldFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TeamsBookmarkStore(directory: directory, accountKey: String(repeating: "c", count: 64))
        let bookmark = TeamsBookmark(hit: try hit(), title: "Reference", collection: "Work")
        try store.save([bookmark])
        XCTAssertEqual(try store.loadFollowing(), [])
        try store.saveFollowing(["channel-b", "channel-a", "channel-a"])
        XCTAssertEqual(try store.loadFollowing(), ["channel-a", "channel-b"])
        XCTAssertEqual(try store.load(), [bookmark])
        try store.save([])
        XCTAssertEqual(try store.loadFollowing(), ["channel-a", "channel-b"])
        XCTAssertThrowsError(try store.saveFollowing([" "]))
        XCTAssertEqual(try store.loadFollowing(), ["channel-a", "channel-b"])
        let other = try TeamsBookmarkStore(directory: directory, accountKey: String(repeating: "d", count: 64))
        XCTAssertEqual(try other.loadFollowing(), [])
    }

    func testFollowingSearchSendsFullChannelSetToServerBeforePagination() async throws {
        TeamsStub.reset(stubs: [.init(pathContains: "/v1/teams/feed", method: "POST", body: """
        {"as_of":null,"index_version":"v1","total":9,"results":[],"next_offset":5}
        """)])
        let service = TeamsSearchService(baseUrl: "https://search.example.org", scope: "api://example/.default",
                                        sessionConfiguration: StubURLProtocol.sessionConfiguration(),
                                        tokenProvider: { _, _ in "delegated-token" })
        let response = try await service.followedFeed(channels: ["a", "b"], query: "printer", author: "Example",
                                                      since: "2026-11-01", limit: 5, offset: 0).value
        XCTAssertEqual(response.nextOffset, 5)
        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.jsonObject?["channels"] as? [String], ["a", "b"])
        XCTAssertEqual(request.jsonObject?["q"] as? String, "printer")
        XCTAssertEqual(request.jsonObject?["author"] as? String, "Example")
        XCTAssertEqual(request.headers[TeamsSearchService.purposeHeader], TeamsSearchService.defaultPurpose)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }

    func testFollowingRetryKeepsTheEntireReadRequestBody() async throws {
        TeamsStub.reset(stubs: [.init(pathContains: "/v1/teams/feed", statusCode: 401, body: "{}")])
        let service = TeamsSearchService(baseUrl: "https://search.example.org", scope: "api://example/.default",
                                        sessionConfiguration: StubURLProtocol.sessionConfiguration(),
                                        tokenProvider: { _, refresh in refresh ? "new-token" : "old-token" })
        do {
            _ = try await service.followedFeed(channels: ["a", "b"], query: "printer", limit: 5, offset: 5)
            XCTFail("Expected a rejected sign-in")
        } catch let error as TeamsSearchError { XCTAssertEqual(error, .unauthorized) }
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertEqual(StubURLProtocol.recorded.first?.body, StubURLProtocol.recorded.last?.body)
        XCTAssertEqual(StubURLProtocol.recorded.last?.headers["Authorization"], "Bearer new-token")
    }

}
