import XCTest
@testable import FleetMateCore

final class AppleOrgJoinTests: XCTestCase {
    private func intune(_ id: String, serial: String?, name: String, lastSync: String = "2026-10-01T00:00:00Z",
                        os: String? = nil, compliance: String = "compliant") throws -> IntuneDevice {
        var json: [String: Any] = ["id": id, "deviceName": name, "lastSyncDateTime": lastSync, "complianceState": compliance]
        if let serial { json["serialNumber"] = serial }
        if let os { json["operatingSystem"] = os }
        return try JSONDecoder().decode(IntuneDevice.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testIntuneRowsCarryTheirAppleRecordBySerial() throws {
        let apple = [AppleOrgDevice(serialNumber: "C02ABC123", orgId: "school", model: "MacBook Pro", assignedServerId: "s1")]
        let records = [try intune("1", serial: " c02abc123 ", name: "LAB-01", os: "macOS")]
        let servers = [AppleOrgServer(id: "s1", orgId: "school", name: "Intune", type: "MDM")]

        let rows = AppleOrgJoin.merge(intune: records, apple: apple, servers: servers, orgLabels: ["school": "Apple School Manager"])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "1", "an enrolled row keeps its Intune ID, which every MDM action is keyed on")
        XCTAssertEqual(rows[0].apple?.serialNumber, "C02ABC123")
        XCTAssertEqual(rows[0].serviceText, "Intune")
        XCTAssertEqual(rows[0].value(for: .appleOrganization), "Apple School Manager")
    }

    func testOrganizationDevicesWithoutIntuneRecordStillGetRows() throws {
        let apple = [
            AppleOrgDevice(serialNumber: "ENROLLED", model: "iMac"),
            AppleOrgDevice(serialNumber: "ORPHAN", model: "Mac mini", productFamily: "Mac"),
        ]
        let rows = AppleOrgJoin.merge(intune: [try intune("1", serial: "ENROLLED", name: "A")], apple: apple, servers: [])

        XCTAssertEqual(rows.count, 2)
        let orphan = try XCTUnwrap(rows.first { $0.intune == nil })
        XCTAssertEqual(orphan.id, DeviceListRow.orgOnlyPrefix + "ORPHAN")
        XCTAssertEqual(orphan.nameText, DeviceListRow.missing)
        XCTAssertEqual(orphan.complianceText, "Not Enrolled")
        XCTAssertEqual(orphan.platformText, "macOS", "platform comes from the product family when Intune has no record")
        XCTAssertEqual(orphan.value(for: .enrollment), "Not Enrolled")
        XCTAssertEqual(orphan.value(for: .managementService), "No Service")
    }

    func testIntuneOnlyRowsReadMissingForAppleColumns() throws {
        let rows = AppleOrgJoin.merge(intune: [try intune("w1", serial: "PC1", name: "PC", os: "Windows")], apple: [], servers: [])
        XCTAssertEqual(rows[0].serviceText, "Intune", "a Windows device's management service is the MDM holding it")
        XCTAssertEqual(rows[0].orgStatusText, DeviceListRow.missing)
        XCTAssertEqual(rows[0].groupOrOrderText, DeviceListRow.missing)
        XCTAssertEqual(rows[0].value(for: .orgStatus), "Not in Organization")
        XCTAssertEqual(rows[0].value(for: .appleOrganization), "Not in Organization")
        XCTAssertEqual(rows[0].value(for: .platform), "Windows")
    }

    func testDuplicateIntuneRecordsBothKeepTheAppleRecord() throws {
        let apple = [AppleOrgDevice(serialNumber: "S1", model: "iMac")]
        let records = [try intune("old", serial: "S1", name: "OLD"), try intune("new", serial: "S1", name: "NEW")]
        let rows = AppleOrgJoin.merge(intune: records, apple: apple, servers: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.apple != nil })
    }

    func testDeviceInTwoOrganizationsPrefersTheOneStillHoldingIt() {
        let released = AppleOrgDevice(serialNumber: "S1", orgId: "a", model: "M", releasedFromOrg: Date())
        let held = AppleOrgDevice(serialNumber: "S1", orgId: "b", model: "M")
        for order in [[released, held], [held, released]] {
            let rows = AppleOrgJoin.merge(intune: [], apple: order, servers: [])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].apple?.orgId, "b")
        }
    }

    func testOrganizationLabels() {
        let one = AppleOrgProfile.labels(for: [AppleOrgProfile(name: "default", clientId: "SCHOOLAPI.x")])
        XCTAssertEqual(one["default"], "Apple School Manager", "a lone organization is named for its service, never 'default'")

        let mixed = AppleOrgProfile.labels(for: [
            AppleOrgProfile(name: "default", clientId: "SCHOOLAPI.x"),
            AppleOrgProfile(name: "corp", clientId: "BUSINESSAPI.y"),
        ])
        XCTAssertEqual(mixed["default"], "Apple School Manager")
        XCTAssertEqual(mixed["corp"], "Apple Business Manager")

        let twoBusiness = AppleOrgProfile.labels(for: [
            AppleOrgProfile(name: "east", clientId: "BUSINESSAPI.a"),
            AppleOrgProfile(name: "west", clientId: "BUSINESSAPI.b"),
        ])
        XCTAssertEqual(twoBusiness["east"], "Apple Business Manager (east)")
        XCTAssertEqual(twoBusiness["west"], "Apple Business Manager (west)")
    }

    func testFacetOrderPutsTheAppleOrganizationFirst() {
        XCTAssertEqual(Array(DeviceFacet.allCases.prefix(3)), [.managementService, .orgStatus, .appleOrganization])
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
        let r1 = DeviceListRow(intune: nil, apple: released, serverName: nil)
        let r2 = DeviceListRow(intune: nil, apple: migrating, serverName: "X")
        XCTAssertEqual(r1.orgStatusLabel, "Released")
        XCTAssertEqual(r2.orgStatusLabel, "Assigned")
        XCTAssertEqual(r2.migrationLabel, "In Progress")
        XCTAssertEqual(r2.purchaseSourceLabel, "Manually Added")
        XCTAssertTrue(migrating.hasActiveMigration)
        XCTAssertFalse(released.hasActiveMigration)
        XCTAssertEqual(r1.migrationLabel, "None")
    }

    func testEveryFacetAnswersForEveryRow() throws {
        let rows = [
            DeviceListRow(intune: nil, apple: AppleOrgDevice(serialNumber: "Z", model: "M"), serverName: nil),
            DeviceListRow(intune: try intune("1", serial: "Y", name: "N"), apple: nil, serverName: nil),
        ]
        for row in rows {
            for facet in DeviceFacet.allCases {
                XCTAssertFalse(row.value(for: facet).isEmpty, "\(facet) returned an empty value")
            }
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
