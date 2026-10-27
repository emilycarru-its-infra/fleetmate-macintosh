import XCTest
@testable import FleetMateCore

final class TdxHeadlessSignInTests: XCTestCase {
    @MainActor
    func testRefusedIdentityCannotKeepPreviousUserSession() {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tickets.example.invalid"
        let service = TdxService(config: config)
        service.setSsoToken("eyJ.header.signature", expiry: Date().addingTimeInterval(300))
        TdxHeadlessSignIn.apply(.identityRefused("Identity mismatch"), to: service, config: config)
        XCTAssertFalse(service.actingIdentityIsUser)
        XCTAssertEqual(service.refusedSsoReason, "Identity mismatch")
    }

    @MainActor
    func testSuccessfulJwtAppliesUserSession() {
        let config = FleetMateConfig()
        let service = TdxService(config: config)
        TdxHeadlessSignIn.apply(.success(token: "eyJ.header.signature", userEmail: "operator@example.invalid"),
            to: service, config: config)
        XCTAssertTrue(service.actingIdentityIsUser)
        XCTAssertEqual(service.authenticatedUserId, "operator@example.invalid")
    }

    @MainActor
    func testFailedResultDoesNotCreateUserSession() {
        let config = FleetMateConfig()
        let service = TdxService(config: config)
        TdxHeadlessSignIn.apply(.failure("Silent sign-in failed"), to: service, config: config)
        XCTAssertFalse(service.actingIdentityIsUser)
        XCTAssertEqual(service.refusedSsoReason, "Silent sign-in failed")
    }
}
