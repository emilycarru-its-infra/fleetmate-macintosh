import Foundation
import XCTest
@testable import FleetMateCore

final class RecoverySecretTests: XCTestCase {
    func testSecretsOfferedPerPlatform() {
        XCTAssertEqual(RecoverySecretKind.available(for: .macOS), [.fileVault, .macOSLAPS])
        XCTAssertEqual(RecoverySecretKind.available(for: .windows), [.bitLocker, .windowsLAPS])
        XCTAssertTrue(RecoverySecretKind.available(for: .ios).isEmpty)
        XCTAssertTrue(RecoverySecretKind.available(for: .android).isEmpty)
    }

    func testFileVaultKeyDecodes() throws {
        let data = Data(#"{"value":"ABCD-EFGH-IJKL-MNOP-QRST-UVWX"}"#.utf8)
        let response = try JSONDecoder().decode(FileVaultKeyResponse.self, from: data)
        XCTAssertEqual(response.value, "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
    }

    func testBitLockerListDecodesWithoutKeys() throws {
        let data = Data("""
        {"value":[
          {"id":"key-1","createdDateTime":"2026-01-02T03:04:05Z","volumeType":"operatingSystemVolume","deviceId":"dev"},
          {"id":"key-2","createdDateTime":"2026-02-02T03:04:05Z","volumeType":"fixedDataVolume","deviceId":"dev"}
        ]}
        """.utf8)
        let list = try JSONDecoder().decode(BitLockerRecoveryKeyListResponse.self, from: data)
        XCTAssertEqual(list.value.count, 2)
        XCTAssertNil(list.value[0].key)
        XCTAssertEqual(list.value[0].volumeDisplayName, "Operating System Volume")
        XCTAssertEqual(list.value[1].volumeDisplayName, "Fixed Data Volume")
    }

    func testBitLockerSingleKeyDecodes() throws {
        let data = Data(#"{"id":"key-1","key":"111111-222222-333333-444444-555555-666666-777777-888888"}"#.utf8)
        let key = try JSONDecoder().decode(BitLockerRecoveryKey.self, from: data)
        XCTAssertEqual(key.key, "111111-222222-333333-444444-555555-666666-777777-888888")
        XCTAssertEqual(key.volumeDisplayName, "Volume")
    }

    func testWindowsLAPSPicksLatestCredentialAndDecodesBase64() throws {
        let old = Data("old-password".utf8).base64EncodedString()
        let new = Data("new-password".utf8).base64EncodedString()
        let data = Data("""
        {"id":"dev","deviceName":"PC","credentials":[
          {"accountName":"admin","backupDateTime":"2026-01-01T00:00:00Z","passwordBase64":"\(old)"},
          {"accountName":"admin","backupDateTime":"2026-03-01T00:00:00Z","passwordBase64":"\(new)"}
        ]}
        """.utf8)
        let info = try JSONDecoder().decode(DeviceLocalCredentialInfo.self, from: data)
        XCTAssertEqual(info.latestCredential?.password, "new-password")
        XCTAssertEqual(info.latestCredential?.accountName, "admin")
    }

    func testWindowsLAPSWithNoCredentialsHasNoLatest() throws {
        let data = Data(#"{"id":"dev","credentials":[]}"#.utf8)
        let info = try JSONDecoder().decode(DeviceLocalCredentialInfo.self, from: data)
        XCTAssertNil(info.latestCredential)
    }

    func testInvalidBase64YieldsNoPassword() throws {
        let data = Data(#"{"passwordBase64":"%%%"}"#.utf8)
        let credential = try JSONDecoder().decode(DeviceLocalCredential.self, from: data)
        XCTAssertNil(credential.password)
    }

    func testAzRestCommandCarriesExtraHeadersQuoted() {
        let request = GraphRequest(
            method: .get,
            url: "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/x?$select=credentials",
            headers: ["ocp-client-name": "FleetMate", "ocp-client-version": "1.0"]
        )
        let command = AzeGraphTransport.buildAzRestCommand(request)
        XCTAssertTrue(command.contains("--headers 'ocp-client-name=FleetMate' 'ocp-client-version=1.0'"))
        XCTAssertFalse(command.contains("--body"))
    }

    func testAzRestCommandWithBodyKeepsContentTypeFirst() {
        let request = GraphRequest(method: .post, url: "https://graph.microsoft.com/v1.0/x", body: Data("{}".utf8))
        let command = AzeGraphTransport.buildAzRestCommand(request)
        XCTAssertTrue(command.contains("--headers 'Content-Type=application/json' --body '{}'"))
    }
}
