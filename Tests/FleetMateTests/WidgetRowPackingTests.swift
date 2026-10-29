import XCTest
@testable import FleetMateCore

final class WidgetRowPackingTests: XCTestCase {
    private func sizes(_ rows: [[Int]], _ spans: [Int]) -> [Int] {
        rows.map { $0.reduce(0) { $0 + spans[$1] } }
    }

    func testOneRowWhenEverythingFits() {
        XCTAssertEqual(WidgetRowPacking.rows(spans: [1, 1, 2], unitsPerRow: 6, fullRow: 1000), [[0, 1, 2]])
    }

    func testRowsAreBalancedNotGreedy() {
        let spans = [1, 1, 1, 1, 1, 1]
        let rows = WidgetRowPacking.rows(spans: spans, unitsPerRow: 5, fullRow: 1000)
        XCTAssertEqual(sizes(rows, spans), [3, 3])
    }

    func testWideCardsBalance() {
        let spans = [2, 2, 2, 1, 1, 2, 2]
        let rows = WidgetRowPacking.rows(spans: spans, unitsPerRow: 6, fullRow: 1000)
        XCTAssertEqual(sizes(rows, spans), [6, 6])
        XCTAssertEqual(rows.flatMap { $0 }, Array(0..<7))
    }

    func testFullRowCardsBreakTheRun() {
        let rows = WidgetRowPacking.rows(spans: [1000, 1, 1], unitsPerRow: 4, fullRow: 1000)
        XCTAssertEqual(rows, [[0], [1, 2]])
    }

    func testSpansWiderThanTheRowAreClamped() {
        let rows = WidgetRowPacking.rows(spans: [3, 3, 1], unitsPerRow: 2, fullRow: 1000)
        XCTAssertEqual(rows.count, 3)
    }
}
