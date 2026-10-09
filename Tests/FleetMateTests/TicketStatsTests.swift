import XCTest
@testable import FleetMateCore

final class TicketStatsTests: XCTestCase {
    private func ticket(_ id: Int, status: String, priority: String = "Medium", responsible: String? = nil,
                        group: String? = nil, days: Int = 0, onHold: Bool = false, sla: Bool = false) throws -> TdxTicket {
        var fields: [String: Any] = ["ID": id, "StatusName": status, "PriorityName": priority,
                                     "DaysOld": days, "IsOnHold": onHold, "SlaViolated": sla]
        if let responsible { fields["ResponsibleFullName"] = responsible }
        if let group { fields["ResponsibleGroupName"] = group }
        return try JSONDecoder().decode(TdxTicket.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testCountsFollowTheTicketsGiven() throws {
        let stats = TicketStats(tickets: [
            try ticket(1, status: "New", priority: "High", responsible: "A", group: "Desk", days: 0),
            try ticket(2, status: "In Process", responsible: "A", group: "Desk", days: 20, sla: true),
            try ticket(3, status: "On Hold", priority: "Low", days: 40, onHold: true),
            try ticket(4, status: "Closed", responsible: "B", days: 3),
        ])
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.open, 2)
        XCTAssertEqual(stats.onHold, 1)
        XCTAssertEqual(stats.unassigned, 1)
        XCTAssertEqual(stats.slaViolated, 1)
        XCTAssertEqual(stats.aging, 2)
        XCTAssertEqual(stats.byPriority.map(\.label), ["Low", "Medium", "High"])
        XCTAssertEqual(stats.byResponsible.first, .init(label: "A", value: 2))
        XCTAssertTrue(stats.byResponsible.contains(.init(label: TicketStats.unassigned, value: 1)))
        XCTAssertFalse(stats.byResponsible.contains { $0.label == "B" }, "closed tickets leave the workload bars")
        XCTAssertEqual(stats.byAge.map(\.label), ["Today", "8–30 days", "Over 30 days"])
    }

    func testNoTicketsGivesEmptyFigures() {
        let stats = TicketStats(tickets: [])
        XCTAssertEqual(stats.total, 0)
        XCTAssertTrue(stats.byStatus.isEmpty)
        XCTAssertTrue(stats.byAge.isEmpty)
    }
}
