import XCTest
@testable import FleetMateCore

final class ReportingDeviceSearchTests: XCTestCase {
    private let fleet = [
        ReportingDeviceRecord(serial: "C02ABC123", name: "Lab-Mac-01", hostname: "labmac01", user: "Alex Doe", assetTag: "A1001"),
        ReportingDeviceRecord(serial: "PF3XYZ99", name: "Studio-PC", user: "Sam Roe", assetTag: "A1002", platform: "Windows"),
        ReportingDeviceRecord(serial: "A1001X", name: "Spare"),
    ]

    func testMatchesNameSerialUserAndAssetTag() {
        XCTAssertEqual(ReportingDeviceSearch.search("studio", in: fleet, limit: 6).map(\.field), ["Name"])
        XCTAssertEqual(ReportingDeviceSearch.search("pf3xyz", in: fleet, limit: 6).map(\.field), ["Serial"])
        XCTAssertEqual(ReportingDeviceSearch.search("sam", in: fleet, limit: 6).map(\.device.serial), ["PF3XYZ99"])
        XCTAssertEqual(ReportingDeviceSearch.search("labmac", in: fleet, limit: 6).first?.field, "Name")
    }

    func testExactSerialOrAssetTagSortsFirst() {
        let hits = ReportingDeviceSearch.search("A1001", in: fleet, limit: 6)
        XCTAssertEqual(hits.map(\.device.serial), ["C02ABC123", "A1001X"])
        XCTAssertEqual(hits.first?.field, "Asset tag")
    }

    func testOneRowPerDeviceAndLimit() {
        let hits = ReportingDeviceSearch.search("a", in: fleet, limit: 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.device.serial)).count, 2)
    }

    func testBlankQueryFindsNothing() {
        XCTAssertTrue(ReportingDeviceSearch.search("  ", in: fleet, limit: 6).isEmpty)
    }
}
