import XCTest
@testable import FleetMateCore

final class TicketLoadGateTests: XCTestCase {
    func testNavigationBackToSameTicketRejectsOriginalResponse() {
        var gate = TicketLoadGate()
        let original = gate.begin(ticketId: 1)
        _ = gate.begin(ticketId: 2)
        let latest = gate.begin(ticketId: 1)
        XCTAssertFalse(gate.accepts(original, selectedTicketId: 1))
        XCTAssertTrue(gate.accepts(latest, selectedTicketId: 1))
        XCTAssertFalse(gate.accepts(latest, selectedTicketId: 2))
    }

    func testRefreshAndDeselectionInvalidateEarlierLoads() {
        var gate = TicketLoadGate()
        let original = gate.begin(ticketId: 1)
        let refresh = gate.begin(ticketId: 1)
        XCTAssertFalse(gate.accepts(original, selectedTicketId: 1))
        XCTAssertTrue(gate.accepts(refresh, selectedTicketId: 1))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(refresh, selectedTicketId: 1))
    }

    func testRecipientsSurviveReplyHydrationAndMissingStaysUnknown() throws {
        let entry = try JSONDecoder().decode(TdxFeedEntry.self,
            from: Data(#"{"ID":1,"NotifiedList":"reader@example.invalid"}"#.utf8))
        XCTAssertEqual(entry.withReplies([]).notifiedList, "reader@example.invalid")
        let unknown = try JSONDecoder().decode(TdxFeedEntry.self, from: Data(#"{"ID":2}"#.utf8))
        XCTAssertNil(unknown.notifiedList)
        let nobody = try JSONDecoder().decode(TdxFeedEntry.self, from: Data(#"{"ID":3,"NotifiedList":""}"#.utf8))
        XCTAssertEqual(nobody.notifiedList, "")
    }
}
