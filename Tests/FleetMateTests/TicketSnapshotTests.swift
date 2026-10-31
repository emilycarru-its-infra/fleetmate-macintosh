import XCTest
@testable import FleetMateCore

final class TicketSnapshotTests: XCTestCase {
    func testRoundTripKeepsTicketFields() throws {
        let json = #"[{"ID": 42, "Title": "Laptop", "StatusName": "Open", "ModifiedDate": "2026-10-30T11:00:00Z"}]"#
        let tickets = try JSONDecoder().decode([TdxTicket].self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(tickets)
        let back = try JSONDecoder().decode([TdxTicket].self, from: data)
        XCTAssertEqual(back, tickets)
        XCTAssertEqual(back.first?.title, "Laptop")
    }

    func testMissingSnapshotLoadsEmpty() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(TicketSnapshot.load(root: root).isEmpty)
    }
}
