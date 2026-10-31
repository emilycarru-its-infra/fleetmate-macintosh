import XCTest
@testable import FleetMateCore

final class TicketInboxTests: XCTestCase {
    private let personName = "Pat Example"
    private let personEmail = "pat@example.invalid"

    private func entry(_ id: Int, notified: String?, by author: String = "other@example.invalid",
                       date: String = "2026-10-30T10:00:00Z") -> TdxFeedEntry {
        TdxFeedEntry(id: id, body: "Body \(id)", isPrivate: false, createdDate: date,
                     createdFullName: "Someone", createdEmail: author, itemType: 9, itemId: 1,
                     replies: nil, repliesCount: 0, notifiedList: notified)
    }

    private func ticket(modified: String = "2026-10-30T11:00:00Z") throws -> TdxTicket {
        let json = #"{"ID": 42, "Title": "Laptop", "ModifiedDate": "\#(modified)"}"#
        return try JSONDecoder().decode(TdxTicket.self, from: Data(json.utf8))
    }

    func testAddressedByNameOrEmail() {
        XCTAssertTrue(TicketInbox.isAddressed(notifiedList: "A B <a@example.invalid>, Pat Example <pat@example.invalid>", name: personName, email: personEmail))
        XCTAssertTrue(TicketInbox.isAddressed(notifiedList: "A B , Pat Example", name: personName, email: nil))
        XCTAssertFalse(TicketInbox.isAddressed(notifiedList: "Pat Examples", name: personName, email: nil))
        XCTAssertFalse(TicketInbox.isAddressed(notifiedList: nil, name: personName, email: personEmail))
        XCTAssertFalse(TicketInbox.isAddressed(notifiedList: "", name: personName, email: personEmail))
    }

    func testMergeKeepsOnlyNotifiedEntriesFromOthersInsideWindow() throws {
        var inbox = TicketInbox(personUid: "u1")
        let cutoff = TdxTicket.parseDate("2026-08-01T00:00:00Z")!
        inbox.merge(feed: [
            entry(1, notified: "Pat Example <pat@example.invalid>"),
            entry(2, notified: "Someone Else"),
            entry(3, notified: "Pat Example", by: personEmail),
            entry(4, notified: "Pat Example", date: "2026-07-01T00:00:00Z"),
        ], ticket: try ticket(), name: personName, email: personEmail, cutoff: cutoff)

        XCTAssertEqual(inbox.items.map(\.id), [1])
        XCTAssertEqual(inbox.ticketModified[42], "2026-10-30T11:00:00Z")
        XCTAssertEqual(inbox.unreadCount(readIds: []), 1)
        XCTAssertEqual(inbox.unreadCount(readIds: [1]), 0)
    }

    func testMergeTwiceDoesNotDuplicateAndPruneDropsOldItems() throws {
        var inbox = TicketInbox(personUid: "u1")
        let cutoff = TdxTicket.parseDate("2026-08-01T00:00:00Z")!
        let feed = [entry(1, notified: "Pat Example")]
        inbox.merge(feed: feed, ticket: try ticket(), name: personName, email: personEmail, cutoff: cutoff)
        inbox.merge(feed: feed, ticket: try ticket(), name: personName, email: personEmail, cutoff: cutoff)
        XCTAssertEqual(inbox.items.count, 1)

        inbox.prune(before: TdxTicket.parseDate("2026-11-01T00:00:00Z")!)
        XCTAssertTrue(inbox.items.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var inbox = TicketInbox(personUid: "u1")
        inbox.ticketModified = [42: "2026-10-30T11:00:00Z"]
        try inbox.save(root: root)
        XCTAssertEqual(TicketInbox.load(personUid: "u1", root: root).ticketModified[42], "2026-10-30T11:00:00Z")
        XCTAssertTrue(TicketInbox.load(personUid: "u2", root: root).ticketModified.isEmpty)

        try TicketInboxReadState(readIds: [7]).save(personUid: "u1", root: root)
        XCTAssertEqual(TicketInboxReadState.load(personUid: "u1", root: root).readIds, [7])
    }

    func testScanLockIsExclusive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: TicketInboxScanLock? = TicketInboxScanLock(personUid: "u1", root: root)
        XCTAssertNotNil(first)
        XCTAssertNil(TicketInboxScanLock(personUid: "u1", root: root))
        first = nil
        XCTAssertNotNil(TicketInboxScanLock(personUid: "u1", root: root))
    }
}

final class TdxSessionCacheTests: XCTestCase {
    private func cache(expiry: Date = Date().addingTimeInterval(7200)) -> TdxSessionCache {
        TdxSessionCache(token: "t", expiry: expiry, userId: "pat@example.invalid", userName: "Pat",
                        cookies: [], me: TdxPerson(uid: "u1", fullName: "Pat", primaryEmail: "other@example.invalid"),
                        confirmedUpn: "Pat@Example.invalid", baseUrl: "https://tdx.example.invalid")
    }

    func testMatchesOnlySameAccountAndTenant() {
        let c = cache()
        XCTAssertTrue(c.matches(expectedUpn: "pat@example.invalid", baseUrl: "https://tdx.example.invalid"))
        XCTAssertFalse(c.matches(expectedUpn: "someone@example.invalid", baseUrl: "https://tdx.example.invalid"))
        XCTAssertFalse(c.matches(expectedUpn: nil, baseUrl: "https://tdx.example.invalid"))
        XCTAssertFalse(c.matches(expectedUpn: "pat@example.invalid", baseUrl: "https://other.example.invalid"))
        XCTAssertFalse(cache(expiry: Date().addingTimeInterval(600))
            .matches(expectedUpn: "pat@example.invalid", baseUrl: "https://tdx.example.invalid"))
    }

    func testMeIsDroppedWhenItIsNotTheConfirmedPerson() {
        XCTAssertNil(cache().confirmedMe)
    }
}
