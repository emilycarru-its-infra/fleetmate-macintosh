import XCTest
@testable import FleetMateCore

final class DeviceLookupTests: XCTestCase {
    private func intune(_ id: String, serial: String?, os: String = "macOS", owner: String? = nil) throws -> IntuneDevice {
        var json: [String: Any] = ["id": id, "deviceName": "D-\(id)", "operatingSystem": os, "lastSyncDateTime": "2026-10-01T00:00:00Z"]
        if let serial { json["serialNumber"] = serial }
        if let owner { json["managedDeviceOwnerType"] = owner }
        return try JSONDecoder().decode(IntuneDevice.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Parsing

    func testParsesPastedListsInOrderOnce() {
        let text = "c02abc123\n  C02ABC123 , FVFX12345;\t\"DMPQ0001\"\n\nSerial\n"
        XCTAssertEqual(SerialList.parse(text), ["C02ABC123", "FVFX12345", "DMPQ0001"])
    }

    func testReadsOnlyTheSerialColumnOfACSV() {
        let csv = "Asset Tag,Serial Number,Name\nA-1,c02abc123,Lab 1\nA-2,\"FVFX12345\",\"Lab, 2\"\n"
        XCTAssertEqual(SerialList.parse(csv), ["C02ABC123", "FVFX12345"],
                       "asset tags and names beside the serial column are not serials")
    }

    func testSemicolonAndTabDelimitedCSVs() {
        XCTAssertEqual(SerialList.parse("Name;SN\nLab;ABC123\n"), ["ABC123"])
        XCTAssertEqual(SerialList.parse("Name\tSerial\nLab\tXYZ789\n"), ["XYZ789"])
    }

    func testDropsTokensThatCannotBeSerials() {
        XCTAssertEqual(SerialList.parse("ok-123 a <bad> _x_ " + String(repeating: "Z", count: 41)), ["OK-123"])
    }

    // MARK: Lookup rows

    func testLookupShowsListedDevicesThenNotFoundRows() throws {
        let rows = AppleOrgJoin.merge(intune: [try intune("1", serial: "AAA111"), try intune("2", serial: "BBB222")],
                                      apple: [], servers: [])
        let shown = SerialList.rows(for: ["BBB222", "ZZZ999"], in: rows)
        XCTAssertEqual(shown.map(\.serialText), ["BBB222", "ZZZ999"])
        let unknown = try XCTUnwrap(shown.last)
        XCTAssertTrue(unknown.isUnknown)
        XCTAssertEqual(unknown.nameText, DeviceListRow.notFound)
        XCTAssertEqual(unknown.id, DeviceListRow.unknownPrefix + "ZZZ999")
        XCTAssertNil(unknown.intune, "a Not Found row has no record for any action to target")
        XCTAssertEqual(unknown.values(for: .discrepancy), [DeviceDiscrepancy.unknown])
    }

    // MARK: Discrepancies

    func testDiscrepanciesWaitForBothSystemsToLoad() throws {
        let rows = AppleOrgJoin.merge(intune: [try intune("1", serial: "MAC1")], apple: [], servers: [])
        let notRead = DeviceDiscrepancy.annotate(rows, sources: .init(autopilotRead: false, appleOrgsRead: false))
        XCTAssertEqual(notRead[0].values(for: .discrepancy), [DeviceDiscrepancy.none])
        let read = DeviceDiscrepancy.annotate(rows, sources: .init(autopilotRead: false, appleOrgsRead: true))
        XCTAssertEqual(read[0].discrepancies, [DeviceDiscrepancy.enrolledUnregistered])
    }

    func testAnotherServiceIsRelativeToTheServiceMostEnrolledDevicesUse() throws {
        let servers = [AppleOrgServer(id: "s1", name: "Main Service", type: "MDM"),
                       AppleOrgServer(id: "s2", name: "Old Service", type: "MDM")]
        let apple = [AppleOrgDevice(serialNumber: "A1", model: "Mac", assignedServerId: "s1"),
                     AppleOrgDevice(serialNumber: "A2", model: "Mac", assignedServerId: "s1"),
                     AppleOrgDevice(serialNumber: "A3", model: "Mac", assignedServerId: "s2"),
                     AppleOrgDevice(serialNumber: "A4", model: "Mac"),
                     AppleOrgDevice(serialNumber: "A5", model: "Mac", assignedServerId: "s1")]
        let records = try ["A1", "A2", "A3", "A4"].map { try intune($0, serial: $0) }
        let rows = DeviceDiscrepancy.annotate(AppleOrgJoin.merge(intune: records, apple: apple, servers: servers),
                                              sources: .init(autopilotRead: false, appleOrgsRead: true))
        let bySerial = Dictionary(uniqueKeysWithValues: rows.map { ($0.serialText, $0.discrepancies) })
        XCTAssertEqual(DeviceDiscrepancy.homeService(rows), "Main Service")
        XCTAssertEqual(bySerial["A1"], [])
        XCTAssertEqual(bySerial["A3"], [DeviceDiscrepancy.otherService])
        XCTAssertEqual(bySerial["A4"], [DeviceDiscrepancy.noService])
        XCTAssertEqual(bySerial["A5"], [DeviceDiscrepancy.orgNotEnrolled])
    }

    func testMissingFromInventoryOnlyOnceInventoryIsRead() throws {
        let rows = AppleOrgJoin.merge(intune: [try intune("1", serial: "IN1"), try intune("2", serial: "OUT1")],
                                      apple: [], servers: [])
        let none = DeviceDiscrepancy.annotate(rows, sources: .init(autopilotRead: false, appleOrgsRead: false, inventorySerials: []))
        XCTAssertTrue(none.allSatisfy(\.discrepancies.isEmpty))
        let read = DeviceDiscrepancy.annotate(rows, sources: .init(autopilotRead: false, appleOrgsRead: false, inventorySerials: ["IN1"]))
        XCTAssertEqual(read.first { $0.serialText == "OUT1" }?.discrepancies, [DeviceDiscrepancy.notInInventory])
        XCTAssertEqual(read.first { $0.serialText == "IN1" }?.discrepancies, [])
    }

    func testDiscrepanciesIsTheLastFilterCategory() {
        XCTAssertEqual(DeviceFacet.allCases.last, .discrepancy)
        XCTAssertEqual(DeviceFacet.discrepancy.rawValue, "Discrepancies")
    }
}
