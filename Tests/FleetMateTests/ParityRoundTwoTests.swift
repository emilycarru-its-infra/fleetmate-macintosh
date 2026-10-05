import XCTest
@testable import FleetMateCore

final class WindowsUpdateInventoryTests: XCTestCase {
    func testNormalizeBuildKeepsTheLastTwoParts() {
        XCTAssertEqual(WindowsUpdateInventory.normalizeBuild("10.0.26100.9457"), "26100.9457")
        XCTAssertEqual(WindowsUpdateInventory.normalizeBuild("26100.9457"), "26100.9457")
        XCTAssertEqual(WindowsUpdateInventory.normalizeBuild(nil), "")
    }

    private func device(_ name: String, os: String = "Windows", version: String, synced: String) throws -> IntuneDevice {
        let json = """
        {"id":"\(UUID().uuidString)","deviceName":"\(name)","operatingSystem":"\(os)","osVersion":"\(version)","lastSyncDateTime":"\(synced)"}
        """
        return try JSONDecoder().decode(IntuneDevice.self, from: Data(json.utf8))
    }

    func testCountsRecentWindowsDevicesByBuild() throws {
        let since = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let devices = [
            try device("A", version: "10.0.26100.9457", synced: "2026-10-03T10:00:00Z"),
            try device("B", version: "10.0.26100.9457", synced: "2026-10-04T10:00:00Z"),
            try device("C", version: "10.0.22631.4890", synced: "2026-10-04T10:00:00Z"),
            try device("Old", version: "10.0.22631.4890", synced: "2026-09-01T10:00:00Z"),
            try device("Mac", os: "macOS", version: "26.0", synced: "2026-10-04T10:00:00Z"),
        ]
        let inventory = WindowsUpdateInventory.build(from: devices, since: since, selectedBuilds: ["10.0.26100.9457"])
        XCTAssertEqual(inventory.totalDevices, 3)
        XCTAssertEqual(inventory.matchingDevices, 2)
        XCTAssertEqual(inventory.coveragePercentage, 66.7)
        XCTAssertEqual(inventory.builds.first?.build, "26100.9457")
        XCTAssertEqual(inventory.devices.map(\.deviceName), ["A", "B"])
    }
}

final class TdxAssetDecodingTests: XCTestCase {
    func testDecodesTheFieldsTheCLIShows() throws {
        let json = #"{"ID":7,"Name":"Laptop","Tag":"T-1","SerialNumber":"ABC123","StatusName":"In Use","LocationName":"Room 1","ModelName":"Model X"}"#
        let asset = try JSONDecoder().decode(TdxAsset.self, from: Data(json.utf8))
        XCTAssertEqual(asset.id, 7)
        XCTAssertEqual(asset.status, "In Use")
        XCTAssertEqual(asset.location, "Room 1")
        XCTAssertNil(asset.manufacturer)
    }
}
