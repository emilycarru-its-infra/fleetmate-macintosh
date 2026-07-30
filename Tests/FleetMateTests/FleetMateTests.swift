import XCTest
@testable import FleetMateCore

final class FleetMateTests: XCTestCase {

    func testKeychainServiceKeyEnum() {
        // Raw values are the on-disk credential keys — renaming one silently
        // orphans every stored credential, so they are pinned here.
        XCTAssertEqual(KeychainService.Key.reportMateUrl.rawValue, "ReportMateUrl")
        XCTAssertEqual(KeychainService.Key.snipeApiKey.rawValue, "SnipeApiKey")
        XCTAssertEqual(KeychainService.Key.graphTenantId.rawValue, "GraphTenantId")
    }

    func testFleetMateConfigLoad() throws {
        // Should not throw even without config files
        let config = try FleetMateConfig.load()
        XCTAssertNotNil(config)
    }

    func testSecureShellConfig() {
        let config = SecureShellConfig(
            privateKeyPath: "/path/to/key",
            defaultUsername: "testuser"
        )

        XCTAssertEqual(config.privateKeyPath, "/path/to/key")
        XCTAssertEqual(config.defaultUsername, "testuser")
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.connectionTimeoutSeconds, 30)
    }

    func testReportMateDeviceDisplayName() {
        var device = ReportMateDevice()
        device.serialNumber = "ABC123"
        device.deviceName = "Test-Mac"
        device.name = "test-mac.local"
        device.hostname = "test-mac.local"
        XCTAssertEqual(device.displayName, "Test-Mac")

        var deviceNoName = ReportMateDevice()
        deviceNoName.serialNumber = "DEF456"
        deviceNoName.name = "hostname.local"
        deviceNoName.hostname = "hostname.local"
        XCTAssertEqual(deviceNoName.displayName, "hostname.local")

        var serialOnly = ReportMateDevice()
        serialOnly.serialNumber = "GHI789"
        XCTAssertEqual(serialOnly.displayName, "GHI789")
    }

    func testInstallRecordErrorDetection() {
        var successRecord = InstallRecord()
        successRecord.itemName = "GoogleChrome"
        successRecord.currentStatus = "installed"
        successRecord.installedVersion = "120.0.0"
        XCTAssertFalse(successRecord.isError)
        XCTAssertEqual(successRecord.category, .unknown)

        var errorRecord = InstallRecord()
        errorRecord.itemName = "SomeApp"
        errorRecord.currentStatus = "error"
        var raw = InstallRawInfo()
        raw.lastError = "404 file not found on the distribution point"
        errorRecord.raw = raw
        XCTAssertTrue(errorRecord.isError)
        XCTAssertEqual(errorRecord.category, .notFound)

        var hashRecord = InstallRecord()
        hashRecord.currentStatus = "failed"
        var hashRaw = InstallRawInfo()
        hashRaw.lastError = "Hash validation failed for package"
        hashRecord.raw = hashRaw
        XCTAssertTrue(hashRecord.isError)
        XCTAssertEqual(hashRecord.category, .hashMismatch)
    }
}
