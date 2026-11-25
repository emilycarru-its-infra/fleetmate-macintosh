import XCTest
@testable import FleetMateCore

/// A posted comment or reply stays on screen until the TDX feed lists it.
final class TicketFeedPendingTests: XCTestCase {

    private func entry(_ id: Int, _ date: String, replies: [TdxFeedEntry]? = nil) -> TdxFeedEntry {
        TdxFeedEntry(id: id, body: "body \(id)", isPrivate: false, createdDate: date,
                     createdFullName: "Someone", createdEmail: nil, itemType: 9, itemId: 1,
                     replies: replies, repliesCount: replies?.count)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPostedCommentShowsBeforeTheFeedListsIt() {
        var pending = TicketFeedPending()
        pending.addComment(entry(3, "2026-11-24T12:00:00Z"), ticketId: 7, now: now)
        let fetched = [entry(2, "2026-11-24T11:00:00Z"), entry(1, "2026-11-24T10:00:00Z")]
        XCTAssertEqual(pending.merge(fetched, ticketId: 7, now: now).map(\.id), [3, 2, 1])
    }

    func testCommentIsDroppedOnceTheFeedListsIt() {
        var pending = TicketFeedPending()
        pending.addComment(entry(3, "2026-11-24T12:00:00Z"), ticketId: 7, now: now)
        let fetched = [entry(3, "2026-11-24T12:00:00Z"), entry(2, "2026-11-24T11:00:00Z")]
        XCTAssertEqual(pending.merge(fetched, ticketId: 7, now: now).map(\.id), [3, 2])
        XCTAssertTrue(pending.isEmpty)
    }

    func testOtherTicketsAreLeftAlone() {
        var pending = TicketFeedPending()
        pending.addComment(entry(3, "2026-11-24T12:00:00Z"), ticketId: 7, now: now)
        XCTAssertEqual(pending.merge([entry(9, "2026-11-24T09:00:00Z")], ticketId: 8, now: now).map(\.id), [9])
        XCTAssertFalse(pending.isEmpty)
    }

    func testPendingEntriesExpire() {
        var pending = TicketFeedPending()
        pending.addComment(entry(3, "2026-11-24T12:00:00Z"), ticketId: 7, now: now)
        let later = now.addingTimeInterval(TicketFeedPending.lifetime + 1)
        XCTAssertEqual(pending.merge([], ticketId: 7, now: later).map(\.id), [])
        XCTAssertTrue(pending.isEmpty)
    }

    func testPostedReplyJoinsItsThread() {
        var pending = TicketFeedPending()
        pending.addReply(entry(20, "2026-11-24T12:00:00Z"), parentId: 2, ticketId: 7, now: now)
        let fetched = [entry(2, "2026-11-24T11:00:00Z", replies: [entry(10, "2026-11-24T11:30:00Z")])]
        let merged = pending.merge(fetched, ticketId: 7, now: now)
        XCTAssertEqual(merged.first?.replyList.map(\.id), [10, 20])

        // Applying to the feed on screen must not add it twice, nor forget it.
        XCTAssertEqual(pending.apply(to: merged, ticketId: 7).first?.replyList.map(\.id), [10, 20])
        XCTAssertFalse(pending.isEmpty)
    }

    func testDeletedReplyIsForgotten() {
        var pending = TicketFeedPending()
        pending.addReply(entry(20, "2026-11-24T12:00:00Z"), parentId: 2, ticketId: 7, now: now)
        pending.removeReply(id: 20)
        XCTAssertTrue(pending.isEmpty)
    }
}
