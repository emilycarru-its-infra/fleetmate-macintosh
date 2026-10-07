import XCTest
@testable import FleetMateCore

final class DevOpsSsoTenantTests: XCTestCase {
    private func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    func testReadsTenantFromToken() {
        let token = jwt(["tid": "AAAA-BBBB", "name": "Example"])
        XCTAssertEqual(DevOpsSsoService.tenantId(fromJwt: token), "aaaa-bbbb")
    }

    func testMissingTenantClaimIsNil() {
        XCTAssertNil(DevOpsSsoService.tenantId(fromJwt: jwt(["name": "Example"])))
        XCTAssertNil(DevOpsSsoService.tenantId(fromJwt: "not-a-token"))
    }
}
