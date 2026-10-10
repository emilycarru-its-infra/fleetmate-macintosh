import XCTest
@testable import FleetMateCore

/// A widget click must land on the filter value the list holds. Mirrors
/// FleetMate for Windows' WidgetParityTests.
final class WidgetFilterMatchTests: XCTestCase {
    func testPlatformLabelsNameApplePlatformsAsTheWidgetShowsThem() {
        XCTAssertEqual(WidgetFilterMatch.platformLabel("macOS"), "Macintosh")
        XCTAssertEqual(WidgetFilterMatch.platformLabel("iOS"), "iOS/iPadOS")
        XCTAssertEqual(WidgetFilterMatch.platformLabel("iPadOS"), "iOS/iPadOS")
        XCTAssertEqual(WidgetFilterMatch.platformLabel("Windows"), "Windows")
        XCTAssertEqual(WidgetFilterMatch.platformLabel(nil), "")
    }

    func testMacintoshTileSelectsTheMacOSFilterValue() {
        let values = WidgetFilterMatch.matchingValues(
            "Macintosh", in: ["Windows", "macOS"], display: WidgetFilterMatch.platformLabel)
        XCTAssertEqual(values, ["macOS"])
    }

    func testIOSTileSelectsBothIOSAndIPadOS() {
        let values = WidgetFilterMatch.matchingValues(
            "iOS/iPadOS", in: ["Windows", "iOS", "iPadOS", "macOS"], display: WidgetFilterMatch.platformLabel)
        XCTAssertEqual(Set(values), ["iOS", "iPadOS"])
    }

    func testMatchingToleratesCaseAndPunctuation() {
        XCTAssertEqual(WidgetFilterMatch.matchingValues("Non-Compliant", in: ["Compliant", "Noncompliant"]), ["Noncompliant"])
        XCTAssertEqual(WidgetFilterMatch.matchingValues("deployable", in: ["Deployable", "Deployed"]), ["Deployable"])
    }

    func testUnmatchedValuePassesThrough() {
        XCTAssertEqual(WidgetFilterMatch.matchingValues("Linux", in: ["Windows"]), ["Linux"])
        XCTAssertEqual(WidgetFilterMatch.matchingValues("Linux", in: nil), ["Linux"])
    }

    func testFilterValueDropsTheCount() {
        XCTAssertEqual(WidgetFilterMatch.filterValue("deployable (12)"), "deployable")
        XCTAssertEqual(WidgetFilterMatch.filterValue("Windows"), "Windows")
    }

    func testAssetStatusTypePrefersMetaThenNameThenUnknown() {
        XCTAssertEqual(WidgetFilterMatch.assetStatusType(meta: "deployable", name: "Ready to Deploy"), "deployable")
        XCTAssertEqual(WidgetFilterMatch.assetStatusType(meta: nil, name: "In Repair"), "In Repair")
        XCTAssertEqual(WidgetFilterMatch.assetStatusType(meta: "", name: nil), "Unknown")
    }

    /// The Asset Status wedge and the Status filter both read the status
    /// type, so a wedge's label always resolves to a filter value.
    func testStatusWedgeResolvesToTheStatusFilterValue() {
        let wedge = WidgetFilterMatch.filterValue("\(WidgetFilterMatch.assetStatusType(meta: "deployable", name: "Ready")) (4)")
        let filterValue = WidgetFilterMatch.assetStatusType(meta: "deployable", name: "Ready").capitalized
        XCTAssertEqual(WidgetFilterMatch.matchingValues(wedge, in: [filterValue, "Deployed"]), [filterValue])
    }
}
