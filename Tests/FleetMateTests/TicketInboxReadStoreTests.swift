import XCTest
@testable import FleetMateCore

final class TicketInboxReadStoreTests: XCTestCase {
    private func scope(_ endpoint: String = "https://helpdesk.example.invalid/TDWebApi/api/7/tickets", person: String = "person-one") -> TicketInboxScope {
        TicketInboxScope(ticketEndpoint: endpoint, personUid: person)!
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testCanonicalServiceAndActorIsolation() {
        XCTAssertEqual(scope(), scope("HTTPS://HELPDESK.EXAMPLE.INVALID:443/tdwebapi/api/7/tickets/", person: "PERSON-ONE"))
        XCTAssertNotEqual(scope(), scope(person: "person-two"))
        XCTAssertNotEqual(scope(), scope("https://helpdesk.example.invalid/TDWebApi/api/8/tickets"))
        XCTAssertNotEqual(scope(), scope("https://other.example.invalid/TDWebApi/api/7/tickets"))
        XCTAssertNil(TicketInboxScope(ticketEndpoint: "https://user:pass@example.invalid/tickets", personUid: "one"))
        XCTAssertNil(TicketInboxScope(ticketEndpoint: "https://example.invalid/tickets?token=value", personUid: "one"))
        XCTAssertNil(TicketInboxScope(ticketEndpoint: "https://example.invalid/tickets", personUid: "../one"))
    }

    func testTwoEditionsMergeMutationsInsteadOfReplacingStaleSnapshots() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = TicketInboxReadStore(scope: scope(), root: root, edition: .fleetMate)
        let second = TicketInboxReadStore(scope: scope(), root: root, edition: .ticketsMate)
        XCTAssertEqual(first.fileURL, second.fileURL)
        _ = try first.update(.read([1]))
        _ = try second.update(.read([2]))
        _ = try first.update(.unread([1]))
        XCTAssertEqual(try second.update().readIds, [2])
        _ = try first.update(.read([3, 4]))
        XCTAssertEqual(try second.update().readIds, [2, 3, 4])
        XCTAssertTrue(try TicketInboxReadStore(scope: scope(person: "other"), root: root).update().readIds.isEmpty)
    }

    func testConcurrentIndependentWritersKeepEveryReadMark() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        DispatchQueue.concurrentPerform(iterations: 40) { id in
            do { _ = try TicketInboxReadStore(scope: scope(), root: root).update(.read([id])) }
            catch { XCTFail("Concurrent write failed: \(error)") }
        }
        XCTAssertEqual(try TicketInboxReadStore(scope: scope(), root: root).update().readIds, Set(0..<40))
    }

    func testDeclaredLegacyImportPreservesUnreadAndRunsOncePerEdition() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("TicketsMate/Inbox/person-one.read.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(TicketInboxReadState(readIds: [1, 2]))
        try bytes.write(to: legacy)
        let first = TicketInboxReadStore(scope: scope(), root: root, edition: .fleetMate)
        _ = try first.update(.unread([1]))
        let second = TicketInboxReadStore(scope: scope(), root: root, edition: .ticketsMate, legacyServiceKey: scope().serviceKey)
        XCTAssertEqual(try second.update().readIds, [2])
        _ = try second.update(.unread([2]))
        XCTAssertTrue(try second.update().readIds.isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testUnboundOrWrongServiceLegacyReadStateIsNotImported() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try TicketInboxReadState(readIds: [9]).save(personUid: "person-one", root: root)
        XCTAssertTrue(try TicketInboxReadStore(scope: scope(), root: root).update().readIds.isEmpty)
        XCTAssertTrue(try TicketInboxReadStore(scope: scope(), root: root, legacyServiceKey: "wrong").update().readIds.isEmpty)
        XCTAssertEqual(TicketInboxReadState.load(personUid: "person-one", root: root).readIds, [9])
    }

    func testCorruptAndFutureSharedStateArePreserved() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TicketInboxReadStore(scope: scope(), root: root)
        _ = try store.update(.read([1]))
        for bytes in [Data("{".utf8), Data(#"{"version":2,"marks":{},"importedEditions":[]}"#.utf8)] {
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.update(.read([2])))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        }
    }

    func testScopedContentRequiresBindingToAdoptOwnLegacyCache() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var old = TicketInbox(personUid: "person-one")
        old.scannedThrough = Date()
        old.ticketModified = [42: "revision"]
        try old.save(root: root)
        XCTAssertNil(TicketInbox.load(scope: scope(), root: root).scannedThrough)
        let adopted = TicketInbox.load(scope: scope(), legacyServiceKey: scope().serviceKey, root: root)
        XCTAssertEqual(adopted.ticketModified[42], "revision")
        try adopted.save(scope: scope(), root: root)
        XCTAssertEqual(TicketInbox.load(scope: scope(), root: root).ticketModified[42], "revision")
        XCTAssertNil(TicketInbox.load(scope: scope(person: "other"), legacyServiceKey: scope().serviceKey, root: root).scannedThrough)
        XCTAssertNil(TicketInbox.load(scope: scope("https://other.example.invalid/tickets"), root: root).scannedThrough)
        XCTAssertEqual(TicketInbox.load(personUid: "person-one", root: root).ticketModified[42], "revision")
    }
}
