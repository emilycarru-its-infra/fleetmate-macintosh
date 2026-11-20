import XCTest
@testable import FleetMateCore

final class LightboxColumnsTests: XCTestCase {
    /// The lightbox is 90% of the window.
    private func plan(window: Double, hasDiscussion: Bool = true) -> LightboxColumns {
        LightboxColumns.plan(width: window * 0.9, hasDiscussion: hasDiscussion)
    }

    func testSmallWindowStacks() {
        let columns = plan(window: 700)
        XCTAssertEqual(columns.arrangement, .stacked)
        XCTAssertEqual(columns.readingWidth, 630)
        XCTAssertEqual(columns.sideWidth, 0)
    }

    func testLaptopWindowPutsFieldsBesideReading() {
        let columns = plan(window: 1280)
        XCTAssertEqual(columns.arrangement, .readingAndSide)
        XCTAssertEqual(columns.sideWidth, LightboxColumns.sideMin)
        XCTAssertGreaterThanOrEqual(columns.readingWidth, LightboxColumns.readingMin)
        XCTAssertLessThanOrEqual(columns.readingWidth, LightboxColumns.readingMax)
        XCTAssertEqual(columns.margin, 0, "Under the reading maximum every point goes to the columns")
        XCTAssertEqual(columns.contentWidth, 1152)
    }

    func testDesktopWindowGivesCommentsTheirOwnColumn() {
        let columns = plan(window: 1920)
        XCTAssertEqual(columns.arrangement, .readingDiscussionAndSide)
        XCTAssertGreaterThanOrEqual(columns.readingWidth, LightboxColumns.readingMin)
        XCTAssertGreaterThanOrEqual(columns.discussionWidth, LightboxColumns.discussionMin)
        XCTAssertGreaterThan(columns.readingWidth, columns.discussionWidth)
        XCTAssertEqual(columns.contentWidth + 2 * columns.margin, 1728, accuracy: 1)
    }

    func testLargeDisplayCapsColumnsAndCentresTheGroup() {
        let columns = plan(window: 2560)
        XCTAssertEqual(columns.arrangement, .readingDiscussionAndSide)
        XCTAssertEqual(columns.readingWidth, LightboxColumns.readingMax)
        XCTAssertEqual(columns.discussionWidth, LightboxColumns.discussionMax)
        XCTAssertEqual(columns.sideWidth, LightboxColumns.sideMax)
        XCTAssertGreaterThan(columns.margin, 0)
        XCTAssertEqual(columns.contentWidth + 2 * columns.margin, 2304, accuracy: 1)
    }

    func testWithoutDiscussionStaysTwoColumnsAndCentres() {
        let columns = plan(window: 2560, hasDiscussion: false)
        XCTAssertEqual(columns.arrangement, .readingAndSide)
        XCTAssertEqual(columns.readingWidth, LightboxColumns.readingMax)
        XCTAssertEqual(columns.sideWidth, LightboxColumns.sideMax)
        XCTAssertEqual(columns.contentWidth + 2 * columns.margin, 2304, accuracy: 1)
    }

    func testBreakpointsAreContinuous() {
        // Every width from tiny to huge fills exactly what it is given.
        var width = 0.0
        while width <= 3000 {
            let columns = LightboxColumns.plan(width: width)
            XCTAssertEqual(columns.contentWidth + 2 * columns.margin, width, accuracy: 1, "width \(width)")
            if columns.arrangement != .stacked {
                XCTAssertGreaterThanOrEqual(columns.readingWidth, LightboxColumns.readingMin, "width \(width)")
                XCTAssertLessThanOrEqual(columns.readingWidth, LightboxColumns.readingMax, "width \(width)")
                XCTAssertGreaterThanOrEqual(columns.sideWidth, LightboxColumns.sideMin, "width \(width)")
                XCTAssertLessThanOrEqual(columns.sideWidth, LightboxColumns.sideMax, "width \(width)")
            }
            if columns.arrangement == .readingDiscussionAndSide {
                XCTAssertGreaterThanOrEqual(columns.discussionWidth, LightboxColumns.discussionMin, "width \(width)")
                XCTAssertLessThanOrEqual(columns.discussionWidth, LightboxColumns.discussionMax, "width \(width)")
            }
            width += 7
        }
    }

    func testThresholds() {
        XCTAssertEqual(LightboxColumns.plan(width: LightboxColumns.sideBySideWidth - 1).arrangement, .stacked)
        XCTAssertEqual(LightboxColumns.plan(width: LightboxColumns.sideBySideWidth).arrangement, .readingAndSide)
        XCTAssertEqual(LightboxColumns.plan(width: LightboxColumns.threeColumnWidth - 1).arrangement, .readingAndSide)
        XCTAssertEqual(LightboxColumns.plan(width: LightboxColumns.threeColumnWidth).arrangement, .readingDiscussionAndSide)
    }

    func testNonFiniteWidthStacksAtZero() {
        XCTAssertEqual(LightboxColumns.plan(width: .infinity).arrangement, .stacked)
        XCTAssertEqual(LightboxColumns.plan(width: -10).readingWidth, 0)
    }
}
