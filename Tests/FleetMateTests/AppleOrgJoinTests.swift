import XCTest
@testable import FleetMateCore

final class AppleOrgJoinTests: XCTestCase {
    private func intune(_ id: String, serial: String?, name: String, lastSync: String, compliance: String = "compliant") throws -> IntuneDevice {
        var json: [String: Any] = ["id": id, "deviceName": name, "lastSyncDateTime": lastSync, "complianceState": compliance]
        if let serial { json["serialNumber"] = serial }
        return try JSONDecoder().decode(IntuneDevice.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testJoinsBySerialIgnoringCaseAndWhitespace() throws {
        let devices = [AppleOrgDevice(serialNumber: "C02ABC123", model: "MacBook Pro", assignedServerId: "s1")]
        let records = [try intune("1", serial: " c02abc123 ", name: "LAB-01", lastSync: "2026-10-01T00:00:00Z")]
        let servers = [AppleOrgServer(id: "s1", name: "Intune", type: "MDM")]

        let rows = AppleOrgJoin.join(devices: devices, intune: records, servers: servers)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].intune?.deviceName, "LAB-01")
        XCTAssertEqual(rows[0].serverName, "Intune")
        XCTAssertTrue(rows[0].isEnrolled)
    }

    func testMostRecentlySyncedRecordWinsForDuplicateSerials() throws {
        let devices = [AppleOrgDevice(serialNumber: "SERIAL1", model: "iMac")]
        let records = [
            try intune("old", serial: "SERIAL1", name: "OLD", lastSync: "2026-01-01T00:00:00Z"),
            try intune("new", serial: "SERIAL1", name: "NEW", lastSync: "2026-09-01T00:00:00Z"),
            try intune("older", serial: "SERIAL1", name: "OLDER", lastSync: "2025-01-01T00:00:00Z"),
        ]
        let rows = AppleOrgJoin.join(devices: devices, intune: records, servers: [])
        XCTAssertEqual(rows[0].intune?.deviceName, "NEW")
    }

    func testDeviceWithoutIntuneRecordReadsNotEnrolled() {
        let rows = AppleOrgJoin.join(devices: [AppleOrgDevice(serialNumber: "X", model: "Mac mini")], intune: [], servers: [])
        XCTAssertFalse(rows[0].isEnrolled)
        XCTAssertEqual(rows[0].value(for: .enrollment), "Not Enrolled")
        XCTAssertEqual(rows[0].value(for: .compliance), "Not Enrolled")
        XCTAssertEqual(rows[0].value(for: .server), "No Service")
        XCTAssertEqual(rows[0].value(for: .order), "No Order")
    }

    func testAssignmentsFromServerListings() {
        let map = AppleOrgJoin.assignments(fromServerListings: ["a": ["s1", "s2"], "b": ["s3"]])
        XCTAssertEqual(map["S1"], "a")
        XCTAssertEqual(map["S3"], "b")
        XCTAssertNil(map["S4"])
    }

    func testLabels() {
        let released = AppleOrgDevice(serialNumber: "R", model: "M", status: "UNASSIGNED", releasedFromOrg: Date())
        let migrating = AppleOrgDevice(serialNumber: "G", model: "M", status: "ASSIGNED", purchaseSource: "MANUALLY_ADDED", migrationStatus: "STARTED")
        let r1 = AppleOrgRow(device: released, intune: nil, serverName: nil)
        let r2 = AppleOrgRow(device: migrating, intune: nil, serverName: "X")
        XCTAssertEqual(r1.statusLabel, "Released")
        XCTAssertEqual(r2.statusLabel, "Assigned")
        XCTAssertEqual(r2.migrationLabel, "In Progress")
        XCTAssertEqual(r2.purchaseSourceLabel, "Manually Added")
        XCTAssertTrue(migrating.hasActiveMigration)
        XCTAssertFalse(released.hasActiveMigration)
        XCTAssertEqual(r1.migrationLabel, "None")
    }

    func testEveryFacetAnswersForEveryRow() {
        let row = AppleOrgRow(device: AppleOrgDevice(serialNumber: "Z", model: "M"), intune: nil, serverName: nil)
        for facet in AppleOrgFacet.allCases {
            XCTAssertFalse(row.value(for: facet).isEmpty, "\(facet) returned an empty value")
        }
    }

    func testLatestDeadlineIsNinetyDaysOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let latest = AppleOrgAction.latestDeadline(from: now)
        let days = Calendar.current.dateComponents([.day], from: now, to: latest).day
        XCTAssertEqual(days, 90)
        XCTAssertTrue(AppleOrgAction.release.isBusinessOnly)
        XCTAssertFalse(AppleOrgAction.cancelMigration.isBusinessOnly)
    }
}
