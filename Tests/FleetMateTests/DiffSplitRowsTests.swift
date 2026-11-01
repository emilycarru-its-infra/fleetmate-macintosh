import XCTest
@testable import FleetMateCore

final class DiffSplitRowsTests: XCTestCase {
    private func hunk(_ lines: [DiffLine]) -> DiffHunk {
        DiffHunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: lines)
    }

    func testContextShowsOnBothSides() {
        let line = DiffLine(kind: .context, oldLine: 1, newLine: 1, content: "same")
        let rows = hunk([line]).splitRows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].left, line)
        XCTAssertEqual(rows[0].right, line)
    }

    func testChangedLineSitsOppositeItsReplacement() {
        let old = DiffLine(kind: .deletion, oldLine: 7, content: "old")
        let new = DiffLine(kind: .addition, newLine: 7, content: "new")
        let rows = hunk([old, new]).splitRows
        XCTAssertEqual(rows, [DiffSplitRow(left: old, right: new)])
    }

    func testUnevenRunsLeaveTheShorterSideEmpty() {
        let removed = (1...3).map { DiffLine(kind: .deletion, oldLine: $0, content: "r\($0)") }
        let added = DiffLine(kind: .addition, newLine: 1, content: "a1")
        let rows = hunk(removed + [added]).splitRows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].right, added)
        XCTAssertNil(rows[1].right)
        XCTAssertNil(rows[2].right)
        XCTAssertEqual(rows.compactMap(\.left), removed)
    }

    func testPureAdditionHasNoLeftSide() {
        let added = DiffLine(kind: .addition, newLine: 1, content: "a")
        let rows = hunk([added]).splitRows
        XCTAssertEqual(rows, [DiffSplitRow(left: nil, right: added)])
    }

    func testNoNewlineMarkerStaysWithItsSide() {
        let old = DiffLine(kind: .deletion, oldLine: 1, content: "x")
        let marker = DiffLine(kind: .noNewline, content: "No newline at end of file")
        let new = DiffLine(kind: .addition, newLine: 1, content: "x")
        let rows = hunk([old, marker, new]).splitRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], DiffSplitRow(left: old, right: new))
        XCTAssertEqual(rows[1], DiffSplitRow(left: marker, right: nil))
    }

    func testDefaultLayoutKeyAndTitles() {
        XCTAssertEqual(DiffLayout(rawValue: "split"), .split)
        XCTAssertEqual(DiffLayout.split.title, "Side by Side")
        XCTAssertEqual(DiffLayout.inline.title, "Inline")
    }
}
