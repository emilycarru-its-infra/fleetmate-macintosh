import XCTest
@testable import FleetMateCore

final class QueryListOrderTests: XCTestCase {
    private let keys = [
        QueryOrderKey(name: "Bravo", resultCount: 5, lastChanged: Date(timeIntervalSince1970: 300), position: 0),
        QueryOrderKey(name: "alpha", resultCount: 40, lastChanged: Date(timeIntervalSince1970: 100), position: 1),
        QueryOrderKey(name: "Charlie", resultCount: 5, lastChanged: Date(timeIntervalSince1970: 200), position: 2),
    ]

    private func names(_ order: QueryListOrder, ascending: Bool) -> [String] {
        order.sorted(keys, ascending: ascending) { $0 }.map(\.name)
    }

    func testDefaultIsNewestFirst() {
        XCTAssertEqual(QueryListOrder.default, .lastChanged)
        XCTAssertFalse(QueryListOrder.default.defaultAscending)
        XCTAssertEqual(names(.lastChanged, ascending: false), ["Bravo", "Charlie", "alpha"])
    }

    func testNameIgnoresCase() {
        XCTAssertEqual(names(.name, ascending: true), ["alpha", "Bravo", "Charlie"])
        XCTAssertEqual(names(.name, ascending: false), ["Charlie", "Bravo", "alpha"])
    }

    func testResultCountTiesFallBackToName() {
        XCTAssertEqual(names(.resultCount, ascending: false), ["alpha", "Bravo", "Charlie"])
        XCTAssertEqual(names(.resultCount, ascending: true), ["Bravo", "Charlie", "alpha"])
    }

    func testQueryOrderKeepsStoredPosition() {
        XCTAssertEqual(names(.queryOrder, ascending: true), ["Bravo", "alpha", "Charlie"])
        XCTAssertEqual(names(.queryOrder, ascending: false), ["Charlie", "alpha", "Bravo"])
    }

    func testRawValuesAreStableForStoredChoice() {
        XCTAssertEqual(QueryListOrder.allCases.map(\.rawValue),
                       ["lastChanged", "name", "resultCount", "queryOrder"])
    }
}
