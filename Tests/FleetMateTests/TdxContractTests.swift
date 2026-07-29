import XCTest
@testable import FleetMateCore

/// Pins every TDX action the Tickets tab can trigger to the request it must send.
///
/// The failures these guard against are the ones that look fine in the UI: a
/// button wired to a URL that 404s, a payload in the wrong shape, a flag that
/// TDX only reads from the query string. Each expectation below was checked
/// against the live ECU TeamDynamix instance before being written down — if one
/// starts failing, the app changed, not the test's guess.
final class TdxContractTests: XCTestCase {

    private let appId = 115

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

    /// The auth handshake every call makes first, plus whatever the test needs.
    private func stubs(_ extra: [StubURLProtocol.Stub]) -> [StubURLProtocol.Stub] {
        [StubURLProtocol.Stub(pathContains: "/api/auth/loginadmin", body: "\"stub-token\"")] + extra
    }

    private func onlyApiCall() throws -> StubURLProtocol.RecordedRequest {
        let calls = StubURLProtocol.apiCalls
        guard let call = calls.first else {
            XCTFail("no API request was made")
            throw XCTSkip("no request")
        }
        return call
    }

    // MARK: - Reads

    func testSearchTicketsPostsToAppScopedSearch() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/search", body: "[]")
        ]))

        _ = try await makeService().searchTickets(
            search: TicketSearchRequest(searchText: "printer"),
            maxResults: 25
        )

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/search")
        XCTAssertEqual(call.jsonObject?["SearchText"] as? String, "printer")
        XCTAssertEqual(call.jsonObject?["MaxResults"] as? Int, 25)
    }

    func testGetTicketUsesAppScopedPath() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/", body: #"{"ID":42}"#)
        ]))

        let ticket = try await makeService().getTicket(id: 42)

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/42")
        XCTAssertEqual(ticket?.id, 42)
    }

    // MARK: - Ticket writes

    func testUpdateTicketSendsRfc6902PatchDocument() async throws {
        // TDX's PATCH is an ASP.NET Core JsonPatchDocument. Sending the fields
        // as a flat object is answered with "The JsonPatchDocument was malformed
        // and could not be parsed."
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/77", body: #"{"ID":77}"#)
        ]))

        _ = try await makeService().updateTicket(
            id: 77,
            updates: ["Title": "Renamed", "StatusID": 1054]
        )

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "PATCH")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/77")

        let operations = try XCTUnwrap(call.jsonArray, "PATCH body must be a JSON array of operations")
        XCTAssertEqual(operations.count, 2)
        XCTAssertTrue(operations.allSatisfy { $0["op"] as? String == "replace" })
        XCTAssertEqual(operations.map { $0["path"] as? String }, ["/StatusID", "/Title"])
        XCTAssertEqual(operations.first { $0["path"] as? String == "/Title" }?["value"] as? String, "Renamed")
    }

    func testUpdateTicketAddsNotifyFlagAsQueryParameter() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/77", body: #"{"ID":77}"#)
        ]))

        _ = try await makeService().updateTicket(
            id: 77,
            updates: ["ResponsibleUid": "abc"],
            notifyNewResponsible: true
        )

        let call = try onlyApiCall()
        XCTAssertEqual(call.query, "notifyNewResponsible=true")
    }

    func testUpdateTicketUnwrapsOptionalsRatherThanEncodingThemAsStrings() async throws {
        // Changed fields arrive as `Int?` boxed into `Any`; without unwrapping,
        // JSONSerialization sees "Optional(1054)" and rejects the whole body.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/77", body: #"{"ID":77}"#)
        ]))

        let statusId: Int? = 1054
        let clearedGroup: Int? = nil
        _ = try await makeService().updateTicket(
            id: 77,
            updates: ["StatusID": statusId as Any, "ResponsibleGroupID": clearedGroup as Any]
        )

        let operations = try XCTUnwrap(try onlyApiCall().jsonArray)
        XCTAssertEqual(operations.first { $0["path"] as? String == "/StatusID" }?["value"] as? Int, 1054)
        XCTAssertTrue(operations.first { $0["path"] as? String == "/ResponsibleGroupID" }?["value"] is NSNull)
    }

    func testCreateTicketPostsNotifyChoicesAsQueryParameters() async throws {
        // TDX reads NotifyRequestor/NotifyResponsible from the query string;
        // putting them in the body notifies nobody and reports success.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets", method: "POST", body: #"{"ID":900}"#)
        ]))

        let request = CreateTicketRequest(
            typeId: 1780,
            title: "New laptop",
            classification: TdxClassification.serviceRequest.rawValue,
            requestorUid: "requestor-uid",
            responsibleUid: "responsible-uid"
        )
        let created = try await makeService().createTicket(
            request: request,
            notifyRequestor: true,
            notifyResponsible: false
        )

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets")
        let query = try XCTUnwrap(call.query)
        XCTAssertTrue(query.contains("NotifyRequestor=true"), query)
        XCTAssertTrue(query.contains("NotifyResponsible=false"), query)

        let body = try XCTUnwrap(call.jsonObject)
        XCTAssertEqual(body["Title"] as? String, "New laptop")
        XCTAssertEqual(body["TypeID"] as? Int, 1780)
        XCTAssertEqual(body["Classification"] as? Int, 46)
        XCTAssertEqual(body["RequestorUid"] as? String, "requestor-uid")
        XCTAssertEqual(created?.id, 900)
    }

    func testSetParentPostsFullTicketWithParentId() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/500", body: #"{"ID":500}"#)
        ]))

        let existing = try decodeTicket(#"{"ID":500,"TypeID":1780,"Title":"Child","StatusID":1054}"#)
        _ = try await makeService().updateTicket(
            id: 500,
            request: TicketUpdateRequest(from: existing, parentId: 400)
        )

        let call = try onlyApiCall()
        // A full replace, so POST rather than the JSON Patch route.
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/500")
        let body = try XCTUnwrap(call.jsonObject)
        XCTAssertEqual(body["ParentID"] as? Int, 400)
        // Everything else must be echoed back or TDX nulls it.
        XCTAssertEqual(body["Title"] as? String, "Child")
        XCTAssertEqual(body["TypeID"] as? Int, 1780)
        XCTAssertEqual(body["IsRichHtml"] as? Bool, true)
    }

    // MARK: - Feed

    func testAddCommentPostsToTicketFeed() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/12/feed", body: #"{"ID":555}"#)
        ]))

        let entry = try await makeService().addComment(
            ticketId: 12,
            comment: "On it",
            isPrivate: true,
            notify: ["uid-1"]
        )

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/\(appId)/tickets/12/feed")
        let body = try XCTUnwrap(call.jsonObject)
        XCTAssertEqual(body["Comments"] as? String, "On it")
        XCTAssertEqual(body["IsPrivate"] as? Bool, true)
        XCTAssertEqual(body["Notify"] as? [String], ["uid-1"])
        XCTAssertEqual(entry?.id, 555)
    }

    func testFeedLoadsRepliesThatTheTicketFeedOnlyCounts() async throws {
        // The ticket feed collection reports RepliesCount but always sends
        // `Replies: []`; only GET /api/feed/{id} carries the bodies. Trusting
        // the collection is why no thread ever appeared in the Activity pane.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/9/feed", body: """
            [{"ID":100,"Body":"Question","RepliesCount":2,"Replies":[]},
             {"ID":101,"Body":"Unrelated","RepliesCount":0,"Replies":[]}]
            """),
            StubURLProtocol.Stub(pathContains: "/feed/100", body: """
            {"ID":100,"Body":"Question","RepliesCount":2,
             "Replies":[{"ID":1,"Body":"First"},{"ID":2,"Body":"Second"}]}
            """)
        ]))

        let feed = try await makeService().getTicketFeed(ticketId: 9)

        XCTAssertEqual(feed.count, 2)
        XCTAssertEqual(feed[0].replyList.map(\.body), ["First", "Second"])
        XCTAssertFalse(feed[0].hasUnloadedReplies)

        // Entries without replies must not cost an extra round trip.
        let paths = StubURLProtocol.apiCalls.map(\.path)
        XCTAssertEqual(paths.filter { $0.contains("/api/feed/") }, ["/TDWebApi/api/feed/100"])
    }

    func testFeedCanSkipReplyHydration() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/9/feed",
                                 body: #"[{"ID":100,"Body":"Question","RepliesCount":2,"Replies":[]}]"#)
        ]))

        let feed = try await makeService().getTicketFeed(ticketId: 9, includeReplies: false)

        XCTAssertTrue(feed[0].hasUnloadedReplies)
        XCTAssertEqual(StubURLProtocol.apiCalls.count, 1)
    }

    func testFeedEntryIsReadFromTheTenantFeedEndpoint() async throws {
        // Threads are readable per-entry even though they cannot be written to:
        // OPTIONS /api/feed/{id} answers `Allow: GET,DELETE`.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/feed/", body: #"{"ID":29652860,"RepliesCount":0}"#)
        ]))

        let entry = try await makeService().getFeedEntry(id: 29652860)

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/TDWebApi/api/feed/29652860")
        XCTAssertEqual(entry?.id, 29652860)
    }

    // MARK: - Attachments

    func testAttachmentsArriveInlineOnTheTicket() async throws {
        // There is no GET /tickets/{id}/attachments — that route is POST-only,
        // for uploads. The files come back on the ticket itself.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/", body: """
            {"ID":7,"Attachments":[
              {"ID":"a-1","Name":"old.png","Size":100,"CreatedDate":"2026-07-17T18:29:36.653Z",
               "ContentUri":"api/attachments/a-1/content"},
              {"ID":"a-2","Name":"new.png","Size":200,"CreatedDate":"2026-07-28T23:11:34.193Z",
               "ContentUri":"api/attachments/a-2/content"}]}
            """)
        ]))

        let ticket = try await makeService().getTicket(id: 7)

        // Newest first, matching how the web UI lists them.
        XCTAssertEqual(ticket?.attachmentList.map(\.displayName), ["new.png", "old.png"])
        XCTAssertEqual(ticket?.attachmentList.first?.sizeLabel.isEmpty, false)
    }

    func testAttachmentDownloadHitsTheTenantContentRoute() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/attachments/", body: "binary-bytes")
        ]))

        let data = try await makeService().downloadAttachment(id: "a-1")

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/TDWebApi/api/attachments/a-1/content")
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "binary-bytes")
    }

    // MARK: - Acting identity

    func testAValidUserJwtIsPreferredOverTheServiceAccount() async throws {
        // The whole point of SSO here: writes must be attributed to the person,
        // not to the API service account.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/tickets/1", body: #"{"ID":1}"#)
        ]))

        let service = makeService()
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJyb2QifQ.signature"
        service.setSsoToken(jwt, expiry: Date().addingTimeInterval(3600), userName: "Rod")
        XCTAssertTrue(service.hasUserJwt)
        XCTAssertTrue(service.actingIdentityIsUser)

        _ = try await service.getTicket(id: 1)

        let call = try onlyApiCall()
        XCTAssertEqual(call.headers["Authorization"], "Bearer \(jwt)")
        // No service-account handshake should have happened at all.
        XCTAssertTrue(StubURLProtocol.recorded.allSatisfy { !$0.path.contains("loginadmin") })
    }

    func testAScrapedSessionMarkerIsNotTreatedAsAUserJwt() async throws {
        // "cookie-auth" and other non-JWT values are web-session leftovers; the
        // API rejects them as Bearer credentials, so they must not suppress the
        // service-account path.
        let service = makeService()
        service.setSsoToken("cookie-auth", expiry: Date().addingTimeInterval(3600))

        XCTAssertFalse(service.hasUserJwt)
        XCTAssertFalse(service.actingIdentityIsUser)
    }

    // MARK: - Lookups

    func testFindPersonMatchesOnExactEmail() async throws {
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/people/lookup", body: """
            [{"UID":"uid-other","FullName":"Alex Doe Jr","PrimaryEmail":"adoe2@example.edu"},
             {"UID":"uid-me","FullName":"Alex Doe","PrimaryEmail":"adoe@example.edu"}]
            """)
        ]))

        let person = try await makeService().findPerson(email: "adoe@example.edu")

        // A prefix match would have picked the first, wrong, record.
        XCTAssertEqual(person?.uid, "uid-me")
        XCTAssertTrue(try onlyApiCall().path.hasSuffix("/api/people/lookup"))
    }

    func testReferenceLookupsUseTheCorrectScope() async throws {
        // Accounts, groups, and services are tenant-level; sources are
        // app-scoped. Getting the scope wrong 404s the picker into being empty.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/accounts/search", body: #"[{"ID":1,"Name":"ITS"}]"#),
            StubURLProtocol.Stub(pathContains: "/groups/search", body: #"[{"ID":2,"Name":"Devices"}]"#),
            StubURLProtocol.Stub(pathContains: "/services", body: #"[{"ID":3,"Name":"Access","CompositeName":"Facilities / Access"}]"#),
            StubURLProtocol.Stub(pathContains: "/tickets/sources", body: #"[{"ID":4,"Name":"Staff Created"}]"#)
        ]))

        let service = makeService()
        let accounts = try await service.getAccounts()
        let groups = try await service.getGroups()
        let services = try await service.getServices()
        let sources = try await service.getSources()

        XCTAssertEqual(accounts.first?.name, "ITS")
        XCTAssertEqual(groups.first?.name, "Devices")
        XCTAssertEqual(services.first?.name, "Facilities / Access")
        XCTAssertEqual(sources.first?.name, "Staff Created")

        let paths = StubURLProtocol.apiCalls.map(\.path)
        XCTAssertTrue(paths.contains("/TDWebApi/api/accounts/search"), "\(paths)")
        XCTAssertTrue(paths.contains("/TDWebApi/api/groups/search"), "\(paths)")
        XCTAssertTrue(paths.contains("/TDWebApi/api/services"), "\(paths)")
        XCTAssertTrue(paths.contains("/TDWebApi/api/\(appId)/tickets/sources"), "\(paths)")
    }

    func testTicketReferenceDataUsesTheTicketingAppNotTheAssetsApp() async throws {
        // `tdxAppId` is the Assets app at ECU; asking it for ticket statuses or
        // priorities is a 400, which left both pickers silently empty.
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxTicketingAppId = 115
        config.tdxAppId = 116
        config.tdxAuthMethod = .serviceAccount
        config.tdxBeid = "test-beid"
        config.tdxWebServicesKey = "test-key"
        let service = TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())

        StubURLProtocol.reset(stubs: stubs([
            // StatusClass is numeric in TDX's payload — decoding it as a string
            // failed the whole list, so the shape is pinned here.
            StubURLProtocol.Stub(pathContains: "/tickets/statuses", body: #"[{"ID":1054,"Name":"New","StatusClass":1}]"#),
            StubURLProtocol.Stub(pathContains: "/tickets/priorities", body: #"[{"ID":292,"Name":"Medium"}]"#),
            StubURLProtocol.Stub(pathContains: "/tickets/types", body: #"[{"ID":1780,"Name":"IT Support"}]"#)
        ]))

        let statuses = try await service.getStatuses()
        _ = try await service.getPriorities()
        _ = try await service.getTypes()

        XCTAssertEqual(statuses[1054], "New")

        for path in StubURLProtocol.apiCalls.map(\.path) {
            XCTAssertTrue(path.hasPrefix("/TDWebApi/api/115/"), "\(path) is not scoped to the ticketing app")
        }
    }

    // MARK: - Helpers

    private func decodeTicket(_ json: String) throws -> TdxTicket {
        try JSONDecoder().decode(TdxTicket.self, from: Data(json.utf8))
    }
}
