import XCTest
@testable import FleetMateCore

final class FleetMateTests: XCTestCase {
    
    func testKeychainServiceKeyEnum() {
        // Verify all keychain keys are defined
        XCTAssertEqual(KeychainService.Key.reportMateUrl.rawValue, "reportMateUrl")
        XCTAssertEqual(KeychainService.Key.snipeApiKey.rawValue, "snipeApiKey")
        XCTAssertEqual(KeychainService.Key.graphTenantId.rawValue, "graphTenantId")
    }
    
    func testFleetMateConfigLoad() throws {
        // Should not throw even without config files
        let config = try FleetMateConfig.load()
        XCTAssertNotNil(config)
    }
    
    func testErrorCategoryClassification() {
        // Test error category detection
        XCTAssertEqual(ErrorCategory.categorize("Package not found"), .notFound)
        XCTAssertEqual(ErrorCategory.categorize("Hash mismatch"), .hashMismatch)
        XCTAssertEqual(ErrorCategory.categorize("disk space"), .diskSpace)
        XCTAssertEqual(ErrorCategory.categorize("permission denied"), .permissions)
        XCTAssertEqual(ErrorCategory.categorize("script error"), .scriptFailure)
        XCTAssertEqual(ErrorCategory.categorize("network timeout"), .network)
        XCTAssertEqual(ErrorCategory.categorize("something else"), .unknown)
    }
    
    func testSecureShellConfig() {
        let config = SecureShellConfig(
            privateKeyPath: "/path/to/key",
            username: "testuser"
        )
        
        XCTAssertEqual(config.privateKeyPath, "/path/to/key")
        XCTAssertEqual(config.username, "testuser")
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.connectionTimeout, 30)
    }
    
    func testReportMateDeviceDisplayName() {
        let device = ReportMateDevice(
            id: 1,
            serialNumber: "ABC123",
            deviceName: "Test-Mac",
            name: "test-mac.local",
            hostname: "test-mac.local"
        )
        
        XCTAssertEqual(device.displayName, "Test-Mac")
        
        let deviceNoName = ReportMateDevice(
            id: 2,
            serialNumber: "DEF456",
            deviceName: "",
            name: "hostname.local",
            hostname: "hostname.local"
        )
        
        XCTAssertEqual(deviceNoName.displayName, "hostname.local")
    }
    
    func testInstallRecordErrorDetection() {
        let successRecord = InstallRecord(
            id: 1,
            deviceId: 1,
            serialNumber: "ABC123",
            deviceName: "Test-Mac",
            itemName: "GoogleChrome",
            currentStatus: "installed",
            installedVersion: "120.0.0"
        )
        XCTAssertFalse(successRecord.isError)
        
        let errorRecord = InstallRecord(
            id: 2,
            deviceId: 1,
            serialNumber: "ABC123",
            deviceName: "Test-Mac",
            itemName: "SomeApp",
            currentStatus: "error",
            installedVersion: "",
            lastError: "Package not found"
        )
        XCTAssertTrue(errorRecord.isError)
        XCTAssertEqual(errorRecord.category, .notFound)
    }
}
