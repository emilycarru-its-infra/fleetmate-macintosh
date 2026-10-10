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

    func testStatusTypeFilterValueIsTheCapitalisedType() {
        XCTAssertEqual(WidgetFilterMatch.assetStatusTypeFilterValue(meta: "deployable", name: "Ready"), "Deployable")
        XCTAssertEqual(WidgetFilterMatch.assetStatusTypeFilterValue(meta: nil, name: "ready to deploy"), "Ready To Deploy")
        XCTAssertEqual(WidgetFilterMatch.assetStatusTypeFilterValue(meta: nil, name: nil), "Unknown")
    }

    func testStatusFilterValueIsTheStatusNameAsSnipeITNamesIt() {
        XCTAssertEqual(WidgetFilterMatch.assetStatusNameFilterValue("Ready to Deploy"), "Ready to Deploy")
        XCTAssertEqual(WidgetFilterMatch.assetStatusNameFilterValue(" In Repair "), "In Repair")
        XCTAssertNil(WidgetFilterMatch.assetStatusNameFilterValue(""))
        XCTAssertNil(WidgetFilterMatch.assetStatusNameFilterValue(nil))
    }

    /// The Asset Status wedge and the Status Type filter both read the
    /// status type, so a wedge's label always resolves to a Status Type
    /// value and selects every asset of that type, whatever its name.
    func testStatusWedgeSelectsEveryAssetOfItsType() {
        let assets: [(meta: String?, name: String?)] = [
            ("deployable", "Ready to Deploy"), ("deployable", "Spare"), ("deployed", "In Use")
        ]
        let typeValues = Array(Set(assets.map { WidgetFilterMatch.assetStatusTypeFilterValue(meta: $0.meta, name: $0.name) }))
        let wedge = WidgetFilterMatch.filterValue("deployable (2)")

        let selected = WidgetFilterMatch.matchingValues(wedge, in: typeValues)

        XCTAssertEqual(selected, ["Deployable"])
        XCTAssertEqual(assets.filter {
            selected.contains(WidgetFilterMatch.assetStatusTypeFilterValue(meta: $0.meta, name: $0.name))
        }.count, 2)
    }

    /// The Status filter still offers each name, so one name narrows within
    /// a type that several names share.
    func testStatusNameSelectsOnlyThatName() {
        let assets: [(meta: String?, name: String?)] = [
            ("deployable", "Ready to Deploy"), ("deployable", "Spare"), ("deployed", "In Use")
        ]
        let nameValues = Set(assets.compactMap { WidgetFilterMatch.assetStatusNameFilterValue($0.name) })
        XCTAssertEqual(nameValues, ["Ready to Deploy", "Spare", "In Use"])
        XCTAssertEqual(assets.filter { WidgetFilterMatch.assetStatusNameFilterValue($0.name) == "Spare" }.count, 1)
    }
}
