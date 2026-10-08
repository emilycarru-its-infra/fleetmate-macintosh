import XCTest
@testable import FleetMateCore

final class ActivityLogTests: XCTestCase {
    func testMasksSerialsConsistently() {
        let masker = ActivityMasker(knownSerials: ["TESTSERIAL0001"])
        XCTAssertEqual(masker.mask("Erase TESTSERIAL0001"), "Erase SERIAL-1")
        XCTAssertEqual(masker.mask("/hardware/byserial/testserial0001"), "/hardware/byserial/SERIAL-1")
        XCTAssertEqual(masker.mask("/device/PF3ABCD9"), "/device/SERIAL-2")
        XCTAssertEqual(masker.mask("again TESTSERIAL0001 and PF3ABCD9"), "again SERIAL-1 and SERIAL-2")
    }

    func testMasksUdidsHardwareAddressesAndEmails() {
        let masker = ActivityMasker()
        XCTAssertEqual(masker.mask("/managedDevices/0b4f2c1e-9a7d-4e21-8c3b-5f6a7d8e9f01/wipe"), "/managedDevices/UDID-1/wipe")
        XCTAssertEqual(masker.mask("udid 00008030-001A2D3E0C38802E"), "udid UDID-2")
        XCTAssertEqual(masker.mask("mac a4:83:e7:12:34:56 and A4-83-E7-12-34-56"), "mac MAC-1 and MAC-1")
        XCTAssertEqual(masker.mask("/users/someone@example.org/devices"), "/users/USER-1/devices")
    }

    func testLeavesOrdinaryPathsAlone() {
        let masker = ActivityMasker()
        XCTAssertEqual(masker.mask("/v1.0/deviceManagement/managedDevices"), "/v1.0/deviceManagement/managedDevices")
        XCTAssertEqual(masker.mask("Sync devices"), "Sync devices")
        XCTAssertEqual(masker.mask("HTTP 404"), "HTTP 404")
    }

    func testMasksPrivateHostsOnly() {
        let masker = ActivityMasker()
        XCTAssertEqual(masker.maskHost("graph.microsoft.com"), "graph.microsoft.com")
        XCTAssertEqual(masker.maskHost("inventory.example.org"), "host-1")
        XCTAssertEqual(masker.maskHost("INVENTORY.example.org"), "host-1")
    }

    func testReadsSerialsFromQueryBeforeDroppingIt() {
        let url = URL(string: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$filter=serialNumber%20eq%20'TESTSERIAL0001'")
        XCTAssertEqual(ActivityMasker.serialsInQuery(url), ["TESTSERIAL0001"])
    }

    func testRecordsNoQueryAndFilesUnderTheAction() async {
        let log = ActivityLog(capacity: 10)
        log.remember(serial: "TESTSERIAL0001", forDeviceId: "0B4F2C1E-9A7D-4E21-8C3B-5F6A7D8E9F01")
        let id = log.begin("Erase devices", service: "Microsoft Graph")
        log.record(service: "Microsoft Graph", method: "post",
                   url: URL(string: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/0b4f2c1e-9a7d-4e21-8c3b-5f6a7d8e9f01/wipe?token=secret"),
                   status: 204, startedAt: Date(), duration: 0.2, actionId: id)
        log.finish(id, failure: nil)

        let action = log.snapshot[0]
        XCTAssertEqual(action.requests.count, 1)
        XCTAssertEqual(action.requests[0].method, "POST")
        XCTAssertFalse(action.requests[0].path.contains("secret"))
        XCTAssertEqual(action.serials, ["TESTSERIAL0001"])
        XCTAssertEqual(log.search("testserial00").count, 1)
        XCTAssertEqual(action.result, "OK")

        let text = ActivityMasker.export(log.snapshot)
        XCTAssertFalse(text.contains("TESTSERIAL0001"))
        XCTAssertFalse(text.contains("0b4f2c1e"))
        XCTAssertTrue(text.contains("SERIAL-1"))
    }

    func testUnclaimedRequestsGroupIntoOneBackgroundRow() {
        let log = ActivityLog(capacity: 10)
        let now = Date()
        for _ in 0..<3 {
            log.record(service: "GitHub", method: "GET", url: URL(string: "https://api.github.com/graphql"),
                       status: 200, startedAt: now, duration: 0.1, actionId: nil)
        }
        XCTAssertEqual(log.snapshot.count, 1)
        XCTAssertTrue(log.snapshot[0].isBackground)
        XCTAssertEqual(log.snapshot[0].requests.count, 3)
    }

    func testKeepsOnlyTheNewestActions() {
        let log = ActivityLog(capacity: 3)
        for n in 0..<5 { log.finish(log.begin("Action \(n)", service: "Inventory"), failure: nil) }
        XCTAssertEqual(log.snapshot.map(\.title), ["Action 2", "Action 3", "Action 4"])
    }

    func testPathsDropEmailsAndTokensWhenRecorded() {
        let log = ActivityLog(capacity: 10)
        let token = "sk" + String(repeating: "a1B2c3D4", count: 5)
        log.record(service: "Microsoft Graph", method: "GET",
                   url: URL(string: "https://graph.microsoft.com/v1.0/users/someone@example.org/keys/\(token)/devices"),
                   status: 200, startedAt: Date(), duration: 0.1, actionId: nil)
        let path = log.snapshot[0].requests[0].path
        XCTAssertEqual(path, "/v1.0/users/[email]/keys/[token]/devices")
    }

    func testKeepsDeviceIdsInPaths() {
        XCTAssertEqual(ActivityLog.sanitizePath("/managedDevices/0b4f2c1e-9a7d-4e21-8c3b-5f6a7d8e9f01/wipe"),
                       "/managedDevices/0b4f2c1e-9a7d-4e21-8c3b-5f6a7d8e9f01/wipe")
    }

    func testFailureTextLosesUrlsBodiesAndLength() {
        let text = ActivityLog.sanitizeFailure("Request to https://inventory.example.org/api?key=abc failed for someone@example.org\n{\"error\": \"body\"}")
        XCTAssertEqual(text, "Request to [url] failed for [email]")
        XCTAssertLessThanOrEqual(ActivityLog.sanitizeFailure(String(repeating: "x ", count: 200)).count, 120)
        XCTAssertEqual(ActivityLog.sanitizeFailure("bad eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl here"), "bad [token] here")
    }

    func testQueryYieldsOnlySerials() {
        let url = URL(string: "https://example.org/api/hardware?serial=TESTSERIAL0001&token=abcdef123456&user=someone")
        XCTAssertEqual(ActivityMasker.serialsInQuery(url), ["TESTSERIAL0001"])
    }

    func testExportMasksTitlesAndFailures() {
        let log = ActivityLog(capacity: 10)
        let id = log.begin("Look up TESTSERIAL0001", service: "Inventory")
        log.finish(id, failure: "Denied for TESTSERIAL0001 at a4:83:e7:12:34:56")
        let text = ActivityMasker.export(log.snapshot)
        XCTAssertFalse(text.contains("TESTSERIAL0001"))
        XCTAssertFalse(text.contains("a4:83"))
        XCTAssertTrue(text.contains("Look up SERIAL-1"))
        XCTAssertTrue(text.contains("MAC-1"))
    }
}
