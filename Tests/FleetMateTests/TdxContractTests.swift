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

    func testReplyGoesToTheTenantFeedEndpointNotTheTicketFeed() async throws {
        // The ticket-scoped `/tickets/{id}/feed/{entryId}` route does not exist
        // in TDX and answers 404; replies live under `/api/feed/{id}/comment`,
        // which is the address every feed entry publishes in its own `Uri`.
        StubURLProtocol.reset(stubs: stubs([
            StubURLProtocol.Stub(pathContains: "/feed/", body: #"{"ID":556}"#)
        ]))

        _ = try await makeService().replyToFeedEntry(feedEntryId: 29652860, comment: "Following up")

        let call = try onlyApiCall()
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/feed/29652860/comment")
        XCTAssertFalse(call.path.contains("/tickets/"), "replies must not be posted under a ticket path")
        XCTAssertEqual(call.jsonObject?["Comments"] as? String, "Following up")
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
