import XCTest
@testable import FleetMateCore

final class InitiativeStatsTests: XCTestCase {
    private func item(_ id: Int, type: String = "Task", title: String = "Work", parent: Int? = nil) throws -> WorkItem {
        var fields: [String: Any] = ["System.WorkItemType": type, "System.Title": title]
        if let parent { fields["System.Parent"] = parent }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "fields": fields])
        return try JSONDecoder().decode(WorkItem.self, from: data)
    }

    func testNestedWorkUsesInitiativeAncestorWithoutCountingAncestorsAsWork() throws {
        let task = try item(1, parent: 2)
        let feature = try item(2, type: "Feature", parent: 3)
        let initiative = try item(3, type: "Initiative", title: "Improve onboarding")
        let result = WorkItemStats.initiatives([task], ancestors: [feature, initiative])
        XCTAssertEqual(result, [.init(label: "Improve onboarding (#3)", value: 1)])
        XCTAssertEqual(WorkItemStats.initiatives([task, initiative], ancestors: [feature]),
                       [.init(label: "Improve onboarding (#3)", value: 2)])
    }

    func testUnassignedIsDistinctFromMissingParentAndCycle() throws {
        let unassigned = try item(1)
        let missing = try item(2, parent: 99)
        let cyclic = try item(3, parent: 4)
        let parent = try item(4, parent: 3)
        let result = WorkItemStats.initiatives([unassigned, missing, cyclic], ancestors: [parent])
        XCTAssertEqual(result, [.init(label: "Unavailable", value: 2), .init(label: "Unassigned", value: 1)])
    }

    func testSameTitleInitiativesRemainSeparateAndNearestInitiativeWins() throws {
        let first = try item(10, type: "Initiative", title: "Improve", parent: 20)
        let second = try item(20, type: "Initiative", title: "Improve")
        let result = WorkItemStats.initiatives([try item(1, parent: 10), try item(2, parent: 20)], ancestors: [first, second])
        XCTAssertEqual(result, [.init(label: "Improve (#10)", value: 1), .init(label: "Improve (#20)", value: 1)])
    }

    func testExistingParentRelationIsUsedWhenParentFieldIsAbsent() throws {
        let data = Data(#"{"id":1,"fields":{"System.WorkItemType":"Task"},"relations":[{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"https://example.com/_apis/wit/workItems/9"}]}"#.utf8)
        let task = try JSONDecoder().decode(WorkItem.self, from: data)
        let result = WorkItemStats.initiatives([task], ancestors: [try item(9, type: "Initiative", title: "Delivery")])
        XCTAssertEqual(result, [.init(label: "Delivery (#9)", value: 1)])
    }
    func testLoadedSeedHierarchiesStillRespectTheSixteenEdgeLimit() throws {
        let long = try (1...18).map {
            try item($0, type: $0 == 18 ? "Initiative" : "Task", title: "Delivery", parent: $0 < 18 ? $0 + 1 : nil)
        }
        XCTAssertEqual(WorkItemStats.initiatives(long, ancestors: []), [
            .init(label: "Delivery (#18)", value: 17), .init(label: "Unavailable", value: 1),
        ])
        let atLimit = try (1...17).map {
            try item($0, type: $0 == 17 ? "Initiative" : "Task", title: "Delivery", parent: $0 < 17 ? $0 + 1 : nil)
        }
        XCTAssertEqual(WorkItemStats.initiatives(atLimit, ancestors: []), [.init(label: "Delivery (#17)", value: 17)])
    }

}
