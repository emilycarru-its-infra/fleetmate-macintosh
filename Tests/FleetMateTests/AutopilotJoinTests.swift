import XCTest
@testable import FleetMateCore

final class AutopilotJoinTests: XCTestCase {
    private func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func intune(_ id: String, serial: String?, os: String = "Windows", entra: String? = nil,
                        lastSync: String = "2026-10-01T00:00:00Z") throws -> IntuneDevice {
        var json: [String: Any] = ["id": id, "operatingSystem": os, "lastSyncDateTime": lastSync]
        if let serial { json["serialNumber"] = serial }
        if let entra { json["azureADDeviceId"] = entra }
        return try decode(json)
    }

    private func identity(_ id: String, serial: String?, managed: String? = nil, entra: String? = nil,
                          tag: String? = nil, profile: String? = nil, user: String? = nil) throws -> WindowsAutopilotDevice {
        var json: [String: Any] = ["id": id]
        if let serial { json["serialNumber"] = serial }
        if let managed { json["managedDeviceId"] = managed }
        if let entra { json["azureActiveDirectoryDeviceId"] = entra }
        if let tag { json["groupTag"] = tag }
        if let profile { json["deploymentProfileAssignmentStatus"] = profile }
        if let user { json["userPrincipalName"] = user }
        return try decode(json)
    }

    func testLinkedManagedDeviceIdWinsOverSerial() throws {
        let records = [try intune("A", serial: "SERIAL1"), try intune("B", serial: "SERIAL2")]
        // Serial says A, the Autopilot link says B: the link is authoritative.
        let ids = [try identity("ap1", serial: "SERIAL1", managed: "b")]
        let index = AutopilotJoin.index(autopilot: ids, intune: records)
        XCTAssertEqual(index.autopilot(for: records[1])?.id, "ap1")
        XCTAssertNil(index.autopilot(for: records[0]))
    }

    func testFallsBackToEntraIdThenSerial() throws {
        let records = [try intune("A", serial: "X", entra: "E1"), try intune("B", serial: " serial9 ")]
        let ids = [
            try identity("ap1", serial: "OTHER", managed: "00000000-0000-0000-0000-000000000000", entra: "e1"),
            try identity("ap2", serial: "SERIAL9"),
        ]
        let index = AutopilotJoin.index(autopilot: ids, intune: records)
        XCTAssertEqual(index.autopilot(for: records[0])?.id, "ap1")
        XCTAssertEqual(index.autopilot(for: records[1])?.id, "ap2")
        XCTAssertTrue(index.unenrolled.isEmpty)
    }

    func testClassifiesRegistration() throws {
        let windows = try intune("W", serial: "S1")
        let unregistered = try intune("U", serial: "S2")
        let mac = try intune("M", serial: "S3", os: "macOS")
        let ids = [try identity("ap1", serial: "S1"), try identity("ap2", serial: "S4")]
        let index = AutopilotJoin.index(autopilot: ids, intune: [windows, unregistered, mac])

        XCTAssertEqual(index.registration(for: windows), .registeredAndEnrolled)
        XCTAssertEqual(index.registration(for: unregistered), .enrolledNotRegistered)
        XCTAssertNil(index.registration(for: mac))
        XCTAssertEqual(index.unenrolled.map(\.id), ["ap2"])
    }

    func testIntuneRecordMatchesAtMostOnce() throws {
        let records = [try intune("A", serial: "S1")]
        let ids = [try identity("ap1", serial: "S1"), try identity("ap2", serial: "S1")]
        let index = AutopilotJoin.index(autopilot: ids, intune: records)
        XCTAssertEqual(index.autopilot(for: records[0])?.id, "ap1")
        XCTAssertEqual(index.unenrolled.map(\.id), ["ap2"])
    }

    func testFacetsLeaveNonWindowsDevicesOut() throws {
        let tagged = try identity("ap1", serial: "S1", tag: "Lab", profile: "assignedInSync")
        XCTAssertEqual(AutopilotFacet.groupTag.value(autopilot: tagged, registration: .registeredAndEnrolled), "Lab")
        XCTAssertEqual(AutopilotFacet.profile.value(autopilot: tagged, registration: .registeredAndEnrolled), "Assigned")
        XCTAssertEqual(AutopilotFacet.groupTag.value(autopilot: nil, registration: .enrolledNotRegistered), "Not Registered")
        XCTAssertNil(AutopilotFacet.groupTag.value(autopilot: nil, registration: nil))
        XCTAssertEqual(try identity("ap2", serial: "S2").groupTagLabel, "No Group Tag")
    }

    func testActionsOfferedOnlyWhenValidForWholeSelection() throws {
        let withUser = try identity("ap1", serial: "S1", user: "someone@example.com")
        let without = try identity("ap2", serial: "S2")
        XCTAssertTrue(AutopilotAction.unassignUser.isAvailable(for: [withUser]))
        XCTAssertFalse(AutopilotAction.unassignUser.isAvailable(for: [withUser, without]))
        XCTAssertTrue(AutopilotAction.setGroupTag("Lab").isAvailable(for: [withUser, without]))
        XCTAssertFalse(AutopilotAction.delete.isAvailable(for: [withUser, nil]))
        XCTAssertFalse(AutopilotAction.delete.isAvailable(for: []))
    }

    func testImportStatus() throws {
        let done: ImportedAutopilotIdentity = try decode(["id": "1", "state": ["deviceImportStatus": "complete"]])
        let failed: ImportedAutopilotIdentity = try decode(["id": "2", "state": ["deviceImportStatus": "error", "deviceErrorName": "ZtdDeviceAlreadyAssigned"]])
        let pending: ImportedAutopilotIdentity = try decode(["id": "3", "state": ["deviceImportStatus": "pending"]])
        XCTAssertTrue(done.isFinished && done.succeeded)
        XCTAssertEqual(failed.failureReason, "ZtdDeviceAlreadyAssigned")
        XCTAssertFalse(pending.isFinished)
    }
}

final class AutopilotHashCSVTests: XCTestCase {
    private let sampleHash = Data("hardware".utf8).base64EncodedString()

    func testParsesGetWindowsAutopilotInfoOutput() throws {
        let csv = """
        Device Serial Number,Windows Product ID,Hardware Hash,Group Tag
        SERIAL1,,\(sampleHash),Lab
        SERIAL2,00000-00000,\(sampleHash),
        """
        let parsed = try AutopilotHashCSV.parse(csv)
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(parsed.entries[0].groupTag, "Lab")
        XCTAssertNil(parsed.entries[0].productKey)
        XCTAssertEqual(parsed.entries[1].productKey, "00000-00000")
        XCTAssertNil(parsed.entries[1].groupTag)
        XCTAssertTrue(parsed.issues.isEmpty)
    }

    func testDecodesUTF16WithBOMAndQuotedFields() throws {
        let csv = "\"Device Serial Number\",\"Windows Product ID\",\"Hardware Hash\"\r\n\"SERIAL1\",\"\",\"\(sampleHash)\"\r\n"
        var data = Data([0xFF, 0xFE])
        data.append(csv.data(using: .utf16LittleEndian)!)
        let parsed = try AutopilotHashCSV.parse(data: data)
        XCTAssertEqual(parsed.entries.map(\.serialNumber), ["SERIAL1"])
        XCTAssertEqual(parsed.entries.first?.hardwareHash, sampleHash)
    }

    func testReportsBadRowsAndDuplicates() throws {
        let csv = """
        Device Serial Number,Windows Product ID,Hardware Hash
        SERIAL1,,\(sampleHash)
        ,,\(sampleHash)
        SERIAL2,,not base64!
        serial1,,\(sampleHash)
        SERIAL3,,
        """
        let parsed = try AutopilotHashCSV.parse(csv)
        XCTAssertEqual(parsed.entries.map(\.serialNumber), ["SERIAL1"])
        XCTAssertEqual(parsed.issues.map(\.line), [3, 4, 5, 6])
    }

    func testRejectsFileWithoutHashColumn() {
        XCTAssertThrowsError(try AutopilotHashCSV.parse("Device Serial Number,Model\nS1,X")) { error in
            XCTAssertEqual(error as? AutopilotHashCSV.ParseError, .missingColumns(["Hardware Hash"]))
        }
    }

    func testQuotedCommaStaysInField() {
        XCTAssertEqual(AutopilotHashCSV.fields("a,\"b,c\",\"d\"\"e\""), ["a", "b,c", "d\"e"])
    }

    func testGroupTagOverride() {
        let entry = AutopilotHashEntry(serialNumber: "S", hardwareHash: sampleHash, groupTag: "Old")
        XCTAssertEqual(entry.withGroupTag("New").groupTag, "New")
        XCTAssertEqual(entry.withGroupTag("").groupTag, "Old")
    }
}
