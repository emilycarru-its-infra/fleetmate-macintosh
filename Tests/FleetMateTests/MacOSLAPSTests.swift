import Foundation
import XCTest
@testable import FleetMateCore

final class MacOSLAPSTests: XCTestCase {
    func testCredentialResponseDecodesPasswordAndRotationTime() throws {
        let data = Data("""
        {
          "value": {
            "adminAccountPassword": "unique-password",
            "passwordLastRotatedDateTime": "2026-09-15T18:00:00Z"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(
            MacOSLocalAdminCredentialResponse.self,
            from: data
        )

        XCTAssertEqual(response.value.adminAccountPassword, "unique-password")
        XCTAssertEqual(response.value.passwordLastRotatedDateTime, "2026-09-15T18:00:00Z")
    }

    func testCredentialResponseAllowsMissingPasswordForClearServiceError() throws {
        let data = Data("""
        {"value":{"passwordLastRotatedDateTime":"2026-09-15T18:00:00Z"}}
        """.utf8)

        let response = try JSONDecoder().decode(
            MacOSLocalAdminCredentialResponse.self,
            from: data
        )

        XCTAssertNil(response.value.adminAccountPassword)
    }

    func testResolveDeviceAcceptsOneMac() throws {
        let devices = try decodeDevices("""
        {"value":[{"id":"managed-device-id","serialNumber":"SERIAL1","operatingSystem":"macOS"}]}
        """)

        let device = try MacOSLAPSLookup.resolveDevice(
            from: devices,
            serialNumber: "SERIAL1"
        )

        XCTAssertEqual(device.id, "managed-device-id")
    }

    func testResolveDeviceRejectsNonMacOSDevice() throws {
        let devices = try decodeDevices("""
        {"value":[{"id":"managed-device-id","serialNumber":"SERIAL1","operatingSystem":"Windows"}]}
        """)

        XCTAssertThrowsError(
            try MacOSLAPSLookup.resolveDevice(from: devices, serialNumber: "SERIAL1")
        ) { error in
            XCTAssertEqual(error as? MacOSLAPSLookupError, .unsupportedPlatform("Windows"))
        }
    }

    func testResolveDeviceRejectsMissingSerialNumber() {
        XCTAssertThrowsError(
            try MacOSLAPSLookup.resolveDevice(from: [], serialNumber: "MISSING")
        ) { error in
            XCTAssertEqual(error as? MacOSLAPSLookupError, .deviceNotFound("MISSING"))
        }
    }

    func testResolveDeviceRejectsAmbiguousSerialNumber() throws {
        let devices = try decodeDevices("""
        {"value":[
          {"id":"managed-device-1","serialNumber":"SERIAL1","operatingSystem":"macOS"},
          {"id":"managed-device-2","serialNumber":"SERIAL1","operatingSystem":"macOS"}
        ]}
        """)

        XCTAssertThrowsError(
            try MacOSLAPSLookup.resolveDevice(from: devices, serialNumber: "SERIAL1")
        ) { error in
            XCTAssertEqual(error as? MacOSLAPSLookupError, .ambiguousSerial("SERIAL1"))
        }
    }

    func testElevationResponseCleanupRemovesRawAndCompressedBuffers() {
        let command = ElevationSession.buildCleanup(file: "/tmp/aze_example")

        XCTAssertTrue(command.contains("rm -f /tmp/aze_example /tmp/aze_example.raw"))
        XCTAssertTrue(command.contains("/tmp/aze_err"))
        XCTAssertTrue(command.contains("AZE_DONE"))
    }

    private func decodeDevices(_ json: String) throws -> [IntuneDevice] {
        try JSONDecoder().decode(IntuneDeviceListResponse.self, from: Data(json.utf8)).value
    }
}
