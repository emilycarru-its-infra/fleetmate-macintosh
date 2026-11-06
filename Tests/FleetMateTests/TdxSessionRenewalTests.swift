import XCTest
@testable import FleetMateCore

/// The app window and the inbox helper share one TeamDynamix session. These
/// pin how a process picks up the other's session, when it renews, and what
/// the sign-in panel may claim.
final class TdxSessionRenewalTests: XCTestCase {
    private let base = "https://tdx.example.edu/TDWebApi"
    private let upn = "person@example.edu"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func service() -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = base
        config.tdxAppId = 99
        config.tdxTicketingAppId = 115
        config.tdxAuthMethod = .browserSSO
        StubURLProtocol.reset(stubs: [.init(pathContains: "/workflow", body: "null")])
        return TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
    }

    private func cached(token: String = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.shared",
                        expiresIn: TimeInterval, upn: String? = nil, baseUrl: String? = nil) -> TdxSessionCache {
        TdxSessionCache(token: token, expiry: now.addingTimeInterval(expiresIn), userId: upn ?? self.upn,
                        userName: "Synthetic Person", cookies: [],
                        confirmedUpn: upn ?? self.upn, baseUrl: baseUrl ?? base)
    }

    // MARK: Reloading the shared session

    func testExpiredSessionIsReplacedByTheSharedOne() {
        let service = service()
        service.setSsoToken("eyJ.old.token", expiry: now.addingTimeInterval(-60))
        let shared = cached(expiresIn: 20 * 3600)
        service.sharedSessionLoader = { shared }
        service.sharedSessionUpn = upn

        XCTAssertTrue(service.reloadSharedSession(now: now))
        XCTAssertEqual(service.userSessionExpiry, shared.expiry)
        XCTAssertTrue(service.hasUsableUserSession(now: now))
    }

    func testCallWithNoTokenReadsTheSharedSessionBeforeGivingUp() async throws {
        let service = service()
        let shared = cached(expiresIn: 20 * 3600)
        service.sharedSessionLoader = { shared }
        service.sharedSessionUpn = upn
        var adopted = 0
        service.onSharedSessionAdopted = { _ in adopted += 1 }

        _ = try await service.getWorkflow(ticketId: 7)

        XCTAssertEqual(adopted, 1)
        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(call.headers["Authorization"], "Bearer \(shared.token)")
    }

    func testSessionForAnotherPersonOrTenantIsNeverAdopted() {
        let service = service()
        service.sharedSessionUpn = upn
        service.sharedSessionLoader = { self.cached(expiresIn: 20 * 3600, upn: "someone.else@example.edu") }
        XCTAssertFalse(service.reloadSharedSession(now: now, force: true))
        service.sharedSessionLoader = { self.cached(expiresIn: 20 * 3600, baseUrl: "https://other.example.edu/TDWebApi") }
        XCTAssertFalse(service.reloadSharedSession(now: now, force: true))
        XCTAssertNil(service.userSessionExpiry)
    }

    func testUnknownExpectedAddressAdoptsNothing() {
        let service = service()
        service.sharedSessionLoader = { self.cached(expiresIn: 20 * 3600) }
        XCTAssertFalse(service.reloadSharedSession(now: now, force: true))
    }

    func testSharedSessionAboutToExpireIsNotAdopted() {
        let service = service()
        service.sharedSessionUpn = upn
        service.sharedSessionLoader = { self.cached(expiresIn: 60) }
        XCTAssertFalse(service.reloadSharedSession(now: now, force: true))
    }

    func testHealthySessionIsKeptUnlessTheSharedOneOutlastsIt() {
        let service = service()
        service.sharedSessionUpn = upn
        service.setSsoToken("eyJ.held.token", expiry: now.addingTimeInterval(10 * 3600))
        service.sharedSessionLoader = { self.cached(expiresIn: 5 * 3600) }
        XCTAssertFalse(service.reloadSharedSession(now: now, force: true))
        service.sharedSessionLoader = { self.cached(expiresIn: 20 * 3600) }
        XCTAssertTrue(service.reloadSharedSession(now: now, force: true))
    }

    func testRefusedSignInIsNotLiftedByTheSharedSession() {
        let service = service()
        service.sharedSessionUpn = upn
        service.sharedSessionLoader = { self.cached(expiresIn: 20 * 3600) }
        service.refuseSso(reason: "identity mismatch")
        XCTAssertFalse(service.reloadSharedSession(now: now, force: true))
    }

    func testKeychainReadsAreThrottled() {
        let service = service()
        service.sharedSessionUpn = upn
        var reads = 0
        service.sharedSessionLoader = { reads += 1; return nil }
        service.reloadSharedSession(now: now)
        service.reloadSharedSession(now: now.addingTimeInterval(1))
        service.reloadSharedSession(now: now.addingTimeInterval(6))
        XCTAssertEqual(reads, 2)
    }

    // MARK: Renewal schedule

    func testRetryBacksOffOneFiveFifteenThenEveryFifteenMinutes() {
        let schedule = TdxRenewalSchedule.standard
        XCTAssertEqual((1...6).map { schedule.retryDelay(afterFailures: $0) }, [60, 300, 900, 900, 900, 900])
        XCTAssertEqual(schedule.retryDelay(afterFailures: 0), 0)
    }

    func testHealthySessionRenewsBeforeItExpires() {
        let schedule = TdxRenewalSchedule.standard
        let expiry = now.addingTimeInterval(20 * 3600)
        let due = schedule.nextAttempt(expiry: expiry, failures: 0, lastAttempt: nil, now: now)
        XCTAssertEqual(due, expiry.addingTimeInterval(-schedule.lead))
    }

    func testMissingOrNearlyExpiredSessionRenewsNow() {
        let schedule = TdxRenewalSchedule.standard
        XCTAssertEqual(schedule.nextAttempt(expiry: nil, failures: 0, lastAttempt: nil, now: now), now)
        XCTAssertEqual(schedule.nextAttempt(expiry: now.addingTimeInterval(60), failures: 0, lastAttempt: nil, now: now), now)
    }

    func testFailureWaitsOutTheBackoff() {
        let schedule = TdxRenewalSchedule.standard
        let last = now.addingTimeInterval(-30)
        XCTAssertEqual(schedule.nextAttempt(expiry: nil, failures: 1, lastAttempt: last, now: now), last.addingTimeInterval(60))
        XCTAssertEqual(schedule.nextAttempt(expiry: nil, failures: 3, lastAttempt: last, now: now), last.addingTimeInterval(900))
    }

    func testSignInPromptOnlyAfterRepeatedFailuresWithNoSession() {
        let schedule = TdxRenewalSchedule.standard
        XCTAssertFalse(schedule.needsInteractiveSignIn(expiry: nil, failures: 1, now: now))
        XCTAssertTrue(schedule.needsInteractiveSignIn(expiry: nil, failures: 2, now: now))
        XCTAssertFalse(schedule.needsInteractiveSignIn(expiry: now.addingTimeInterval(3600), failures: 5, now: now))
    }

    // MARK: Status

    func testValidNeverOutlivesTheSession() {
        let valid = AuthTokenState.valid(user: "Synthetic Person", expiry: nil)
        let lapsed = TdxAuthStatus.effectiveState(reported: valid, hasUserSession: false, hasServiceAccount: false)
        XCTAssertEqual(AuthDisplayStatus(state: lapsed, lastChecked: now), .expired)
        XCTAssertEqual(AuthDisplayStatus.expired.label, "Expired")
        XCTAssertEqual(AuthDisplayStatus.expired.tone, .attention)
        XCTAssertNotEqual(AuthDisplayStatus.summary([AuthDisplayStatus(state: lapsed, lastChecked: now)]).label, "All valid")
    }

    func testValidStandsWhileASessionOrServiceAccountIsHeld() {
        let valid = AuthTokenState.valid(user: nil, expiry: nil)
        XCTAssertTrue(TdxAuthStatus.effectiveState(reported: valid, hasUserSession: true, hasServiceAccount: false).isHealthy)
        XCTAssertTrue(TdxAuthStatus.effectiveState(reported: valid, hasUserSession: false, hasServiceAccount: true).isHealthy)
    }

    func testFailedProbeIsNeverUpgraded() {
        let failed = AuthTokenState.failed(message: "boom")
        XCTAssertFalse(TdxAuthStatus.effectiveState(reported: failed, hasUserSession: true, hasServiceAccount: true).isHealthy)
    }

    // MARK: Coordination

    @MainActor
    func testRenewalLockLetsOnlyOneProcessRenew() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tdx-lock-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let outer = await TdxSessionSync.withRenewalLock(at: path) { () async -> Int? in
            // A second open file description stands in for the other process.
            await TdxSessionSync.withRenewalLock(at: path) { 1 }
        }
        XCTAssertEqual(outer, .some(nil))
        let after = await TdxSessionSync.withRenewalLock(at: path) { 2 }
        XCTAssertEqual(after, 2)
    }

    func testHelperAndAppWriteSeparateLogs() {
        XCTAssertEqual(DebugLogger.logFileName(isInboxHelper: false), "debug.log")
        XCTAssertEqual(DebugLogger.logFileName(isInboxHelper: true), "helper.log")
    }
}
