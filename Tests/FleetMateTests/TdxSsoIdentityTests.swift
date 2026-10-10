import XCTest
@testable import FleetMateCore

/// A TDX session for anyone but the signed-in user must fail the sign-in,
/// never be stored, and never hand over to the service account.
final class TdxSsoIdentityTests: XCTestCase {

    private let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG9lIn0.signature"

    // MARK: - Identity check

    func testAMatchingAddressSucceeds() {
        let result = TdxSsoIdentity.verify(
            .success(token: token, userName: "Alex", userEmail: "ADoe@Example.edu "),
            expectedUpn: "adoe@example.edu"
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.token, token)
        XCTAssertFalse(result.isWrongAccount)
    }

    func testADifferentAddressFailsAndDropsTheToken() {
        let result = TdxSsoIdentity.verify(
            .success(token: token, userName: "Other", userEmail: "aws-adoe@example.edu"),
            expectedUpn: "adoe@example.edu"
        )
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.isWrongAccount)
        XCTAssertNil(result.token)
        XCTAssertEqual(result.error, "TDX session belongs to aws-adoe@example.edu; expected adoe@example.edu")
    }

    func testAMissingAddressIsAttributedToTheExpectedAccount() {
        for missing in [nil, "", "Alex Doe"] as [String?] {
            let result = TdxSsoIdentity.verify(
                .success(token: token, userName: "Alex", userEmail: missing),
                expectedUpn: "ADoe@example.edu"
            )
            XCTAssertTrue(result.success, "email \(String(describing: missing))")
            XCTAssertEqual(result.token, token)
            XCTAssertEqual(result.userEmail, "adoe@example.edu")
        }
    }

    func testWithNoExpectedAddressTheResultPassesThrough() {
        let original = TdxSsoResult.success(token: token, userName: "Alex", userEmail: "adoe@example.edu")
        XCTAssertEqual(TdxSsoIdentity.verify(original, expectedUpn: nil), original)
    }

    func testAFailureIsLeftAlone() {
        let failure = TdxSsoResult.failure("Silent SSO timed out")
        XCTAssertEqual(TdxSsoIdentity.verify(failure, expectedUpn: "adoe@example.edu"), failure)
    }

    // MARK: - No service-account fallback

    private func makeServiceWithServiceAccount() -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxTicketingAppId = 115
        config.tdxAppId = 115
        config.tdxAuthMethod = .auto
        config.tdxBeid = "test-beid"
        config.tdxWebServicesKey = "test-key"
        return TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
    }

    func testARefusedSignInOffersNoCredentialAtAll() async throws {
        StubURLProtocol.reset(stubs: [
            StubURLProtocol.Stub(pathContains: "/api/auth/loginadmin", body: "\"stub-token\""),
            StubURLProtocol.Stub(pathContains: "/tickets/1", body: #"{"ID":1}"#)
        ])
        let service = makeServiceWithServiceAccount()
        service.setSsoToken(token, expiry: Date().addingTimeInterval(3600), userName: "Alex")

        service.refuseSso(reason: "TDX session belongs to b@example.edu; expected a@example.edu")

        XCTAssertFalse(service.hasUserJwt)
        XCTAssertEqual(service.refusedSsoReason, "TDX session belongs to b@example.edu; expected a@example.edu")
        do {
            _ = try await service.getTicket(id: 1)
            XCTFail("a refused sign-in must not reach TDX")
        } catch TdxAuthError.notAuthenticated {
            // expected
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty, "no request, not even the service-account login")
    }

    func testASignInAsTheRightPersonLiftsTheRefusal() {
        let service = makeServiceWithServiceAccount()
        service.refuseSso(reason: "TDX session belongs to b@example.edu; expected a@example.edu")

        service.setSsoToken(token, expiry: Date().addingTimeInterval(3600), userName: "Alex")

        XCTAssertNil(service.refusedSsoReason)
        XCTAssertTrue(service.hasUserJwt)
    }
}
