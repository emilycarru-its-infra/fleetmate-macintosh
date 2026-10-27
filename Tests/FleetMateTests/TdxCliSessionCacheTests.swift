import XCTest
@testable import FleetMateCore

final class TdxCliSessionCacheTests: XCTestCase {
    private func record() throws -> TdxCliSessionCache.Record {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": 2_000_000_000])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return .init(baseURL: "https://tickets.example.invalid", email: "operator@example.invalid", name: nil,
                     token: "eyJhbGciOiJIUzI1NiJ9.\(payload).synthetic", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testCacheIsBoundToServiceUserAndTokenExpiry() throws {
        let record = try record()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertNotNil(TdxCliSessionCache.validated(record, baseURL: record.baseURL, expectedUpn: record.email, now: now))
        XCTAssertNil(TdxCliSessionCache.validated(record, baseURL: "https://other.example.invalid", expectedUpn: record.email, now: now))
        XCTAssertNil(TdxCliSessionCache.validated(record, baseURL: record.baseURL, expectedUpn: "other@example.invalid", now: now))
        XCTAssertNil(TdxCliSessionCache.validated(record, baseURL: record.baseURL, expectedUpn: nil, now: now))
        XCTAssertNil(TdxCliSessionCache.validated(record, baseURL: record.baseURL, expectedUpn: record.email, now: record.expiresAt))
    }

    func testCookieMarkersAndMalformedTokensAreNeverCached() {
        for token in ["cookie-auth", "", "eyJ.a.b", "not-a-token"] {
            XCTAssertNil(TdxCliSessionCache.tokenExpiry(token))
        }
    }
}
