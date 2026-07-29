import XCTest
@testable import FleetMateCore

final class TicketHierarchyTests: XCTestCase {

    private func ticket(_ id: Int, parent: Int? = nil, title: String = "T") throws -> TdxTicket {
        var fields: [String: Any] = ["ID": id, "Title": title]
        // TDX sends 0 rather than null for "no parent", so model that exactly.
        fields["ParentID"] = parent ?? 0
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(TdxTicket.self, from: data)
    }

    func testAgePrefersTheServerCountAndStaysInDays() throws {
        let data = try JSONSerialization.data(withJSONObject: ["ID": 1, "DaysOld": 412])
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: data)

        XCTAssertEqual(ticket.ageInDays, 412)
        // Never "1 yr" — a queue is read in days.
        XCTAssertEqual(ticket.ageLabel, "412d")
    }

    func testAgeFallsBackToCreatedDateWhenDaysOldIsAbsent() throws {
        let created = Calendar.current.date(byAdding: .day, value: -16, to: Date())!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let data = try JSONSerialization.data(withJSONObject: [
            "ID": 1, "CreatedDate": formatter.string(from: created)
        ])
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: data)

        XCTAssertEqual(ticket.ageInDays, 16)
        XCTAssertEqual(ticket.ageLabel, "16d")
    }

    func testLastActivityMeasuresFromTheModifiedDateNotCreation() throws {
        // The board card shows this, not age: an old ticket touched today is
        // healthy, a young one untouched for three weeks is not.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modified = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let data = try JSONSerialization.data(withJSONObject: [
            "ID": 1, "DaysOld": 400, "ModifiedDate": formatter.string(from: modified)
        ])
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: data)

        XCTAssertEqual(ticket.ageInDays, 400)
        XCTAssertEqual(ticket.daysSinceLastActivity, 3)
        XCTAssertEqual(ticket.lastActivityLabel, "3d")
    }

    func testLastActivityFallsBackToAgeWhenNeverModified() throws {
        let data = try JSONSerialization.data(withJSONObject: ["ID": 1, "DaysOld": 12])
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: data)

        XCTAssertEqual(ticket.daysSinceLastActivity, 12)
    }

    func testAgeIsBlankWhenNothingSaysWhenItOpened() throws {
        let data = try JSONSerialization.data(withJSONObject: ["ID": 1])
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: data)

        XCTAssertNil(ticket.ageInDays)
        XCTAssertEqual(ticket.ageLabel, "-")
    }

    func testParentIdOfZeroMeansNoParent() throws {
        XCTAssertNil(try ticket(1).parentTicketId)
        XCTAssertEqual(try ticket(2, parent: 1).parentTicketId, 1)
    }

    func testChildrenNestUnderTheirParent() throws {
        let tickets = [
            try ticket(100, title: "Parent"),
            try ticket(101, parent: 100),
            try ticket(102, parent: 100),
            try ticket(200, title: "Standalone"),
        ]

        let tree = TicketHierarchy.build(from: tickets)

        XCTAssertEqual(tree.map(\.id), [100, 200])
        XCTAssertEqual(tree[0].children.map(\.id), [101, 102])
        XCTAssertTrue(tree[1].children.isEmpty)
    }

    func testOrphanedChildStaysVisibleAsARoot() throws {
        // The parent is filtered out of the current view (closed, out of range,
        // another group). Dropping its children would hide real work.
        let tickets = [try ticket(101, parent: 999), try ticket(102, parent: 999)]

        let tree = TicketHierarchy.build(from: tickets)

        XCTAssertEqual(tree.map(\.id), [101, 102])
    }

    func testGrandchildrenNestRecursively() throws {
        let tickets = [
            try ticket(1),
            try ticket(2, parent: 1),
            try ticket(3, parent: 2),
        ]

        let tree = TicketHierarchy.build(from: tickets)

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].children.first?.children.first?.id, 3)
        XCTAssertEqual(tree[0].descendantCount, 2)
    }

    func testSelfParentingTicketDoesNotRecurseForever() throws {
        let tree = TicketHierarchy.build(from: [try ticket(7, parent: 7)])

        XCTAssertEqual(tree.map(\.id), [7])
        XCTAssertTrue(tree[0].children.isEmpty)
    }

    func testParentCycleDoesNotRecurseForever() throws {
        // Neither ticket is a root by the parent test, so both fall out as
        // roots only if the cycle is broken; what matters is that this returns.
        let tickets = [try ticket(1, parent: 2), try ticket(2, parent: 1)]

        let tree = TicketHierarchy.build(from: tickets)

        XCTAssertLessThanOrEqual(tree.count, 2)
        XCTAssertLessThanOrEqual(TicketHierarchy.flatten(tree, collapsed: []).count, 4)
    }

    func testEverythingIsExpandedWhenNothingIsCollapsed() throws {
        let tickets = [try ticket(1), try ticket(2, parent: 1), try ticket(3, parent: 1)]

        let rows = TicketHierarchy.flatten(TicketHierarchy.build(from: tickets), collapsed: [])

        XCTAssertEqual(rows.map(\.id), [1, 2, 3])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(rows[0].childCount, 2)
        XCTAssertTrue(rows[0].isExpanded)
    }

    func testCollapsingAParentHidesItsWholeSubtree() throws {
        let tickets = [
            try ticket(1),
            try ticket(2, parent: 1),
            try ticket(3, parent: 2),
            try ticket(4),
        ]

        let rows = TicketHierarchy.flatten(TicketHierarchy.build(from: tickets), collapsed: [1])

        XCTAssertEqual(rows.map(\.id), [1, 4])
        XCTAssertFalse(rows[0].isExpanded)
        XCTAssertTrue(rows[0].hasChildren)
    }

    func testFoldableIdsCollectsEveryRowWithChildren() throws {
        let tickets = [
            try ticket(1),
            try ticket(2, parent: 1),
            try ticket(3, parent: 2),
            try ticket(4),
        ]

        XCTAssertEqual(TicketHierarchy.foldableIds(in: tickets), [1, 2])
    }

    func testFoldableIdsIgnoresParentsThatAreNotLoaded() throws {
        // Nothing folds here — the named parent isn't on screen, so both rows
        // render as roots and neither gets a disclosure triangle.
        let tickets = [try ticket(11, parent: 999), try ticket(12)]

        XCTAssertTrue(TicketHierarchy.foldableIds(in: tickets).isEmpty)
    }

    func testFoldableIdsMatchesTheBuiltOutline() throws {
        let tickets = [
            try ticket(1),
            try ticket(2, parent: 1),
            try ticket(3, parent: 2),
            try ticket(4, parent: 999),
        ]

        // The cheap path the toolbar uses must agree with the tree the table
        // draws, or Collapse All would leave rows expanded.
        let fromOutline = Set(
            TicketHierarchy.flatten(TicketHierarchy.build(from: tickets), collapsed: [])
                .filter(\.hasChildren)
                .map(\.id)
        )
        XCTAssertEqual(TicketHierarchy.foldableIds(in: tickets), fromOutline)
    }

    func testInputOrderIsPreserved() throws {
        // The view sorts before building the tree, so the tree must not reorder.
        let tickets = [
            try ticket(30, title: "C"),
            try ticket(10, title: "A"),
            try ticket(31, parent: 30),
            try ticket(20, title: "B"),
        ]

        let rows = TicketHierarchy.flatten(TicketHierarchy.build(from: tickets), collapsed: [])

        XCTAssertEqual(rows.map(\.id), [30, 31, 10, 20])
    }
}
