import XCTest
@testable import FleetMateCore

final class TicketNotificationRecipientsTests: XCTestCase {
    func testReportedRecipientsSurviveReplyHydration() throws {
        let decoder = JSONDecoder()
        let entry = try decoder.decode(TdxFeedEntry.self,
            from: Data(#"{"ID":1,"NotifiedList":"reader@example.invalid"}"#.utf8))
        let reply = try decoder.decode(TdxFeedEntry.self,
            from: Data(#"{"ID":2,"NotifiedList":"reviewer@example.invalid"}"#.utf8))

        let hydrated = entry.withReplies([reply])

        XCTAssertEqual(hydrated.notifiedList, "reader@example.invalid")
        XCTAssertEqual(hydrated.replyList.first?.notifiedList, "reviewer@example.invalid")
    }

    func testUnknownRecipientsRemainDistinctFromAnEmptyList() throws {
        let decoder = JSONDecoder()
        let missing = try decoder.decode(TdxFeedEntry.self, from: Data(#"{"ID":1}"#.utf8))
        let unknown = try decoder.decode(TdxFeedEntry.self,
            from: Data(#"{"ID":2,"NotifiedList":null}"#.utf8))
        let nobody = try decoder.decode(TdxFeedEntry.self,
            from: Data(#"{"ID":3,"NotifiedList":""}"#.utf8))

        XCTAssertNil(missing.withReplies([]).notifiedList)
        XCTAssertNil(unknown.withReplies([]).notifiedList)
        XCTAssertEqual(nobody.withReplies([]).notifiedList, "")
    }
}
