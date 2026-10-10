import XCTest
@testable import FleetMateCore

final class AppleOrgKeyVaultTests: XCTestCase {
    private let body = String(repeating: "A", count: 100)

    func testSingleLinePEMIsRebuilt() {
        let flat = "-----BEGIN PRIVATE KEY----- \(body.prefix(50)) \(body.dropFirst(50)) -----END PRIVATE KEY-----"
        let pem = AppleOrgKeyVault.normalizedPEM(flat)
        XCTAssertEqual(pem, "-----BEGIN PRIVATE KEY-----\n\(body.prefix(64))\n\(body.dropFirst(64))\n-----END PRIVATE KEY-----\n")
    }

    func testEscapedNewlinesAreRebuilt() {
        let escaped = "-----BEGIN EC PRIVATE KEY-----\\n\(body)\\n-----END EC PRIVATE KEY-----"
        let pem = AppleOrgKeyVault.normalizedPEM(escaped)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN EC PRIVATE KEY-----\n"))
        XCTAssertTrue(pem.hasSuffix("\n-----END EC PRIVATE KEY-----\n"))
        XCTAssertFalse(pem.contains("\\n"))
    }

    func testTextWithoutPEMMarkersIsReturnedTrimmed() {
        XCTAssertEqual(AppleOrgKeyVault.normalizedPEM("  not a key \n"), "not a key")
    }

    func testSourcesNeedAVault() {
        var config = FleetMateConfig()
        XCTAssertTrue(config.appleOrgSources.isEmpty)
        config.appleOrgKeyVault = "example-vault"
        XCTAssertEqual(config.appleOrgSources, [AppleOrgSource(vault: "example-vault", prefix: "Asbm")])
        config.appleOrgSecretPrefixes = ["School", " ", "Business"]
        XCTAssertEqual(config.appleOrgSources.map(\.clientIdSecret), ["SchoolClientId", "BusinessClientId"])
    }

    func testSecretReadFailureNamesTheSecret() async {
        do {
            _ = try await AppleOrgKeyVault.secret("AsbmKeyId", in: "example-vault") { _ in
                ProcessOutput(stdout: "", stderr: "Forbidden", exitCode: 1)
            }
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AsbmKeyId"))
            XCTAssertTrue(error.localizedDescription.contains("Forbidden"))
        }
    }
}
