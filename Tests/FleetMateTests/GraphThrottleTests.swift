import XCTest
@testable import FleetMateCore

final class GraphThrottleTests: XCTestCase {
    func testParsesDeltaSeconds() {
        XCTAssertEqual(GraphThrottle.parseRetryAfter("12"), 12)
        XCTAssertEqual(GraphThrottle.parseRetryAfter(" 0 "), 0)
    }

    func testParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: later)
        XCTAssertEqual(GraphThrottle.parseRetryAfter(header, now: now) ?? -1, 30, accuracy: 1)
    }

    func testPastDateIsZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(GraphThrottle.parseRetryAfter("Mon, 01 Jan 2001 00:00:00 GMT", now: now), 0)
    }

    func testRejectsMissingOrGarbage() {
        XCTAssertNil(GraphThrottle.parseRetryAfter(nil))
        XCTAssertNil(GraphThrottle.parseRetryAfter(""))
        XCTAssertNil(GraphThrottle.parseRetryAfter("soon"))
        XCTAssertNil(GraphThrottle.parseRetryAfter("-5"))
    }

    func testThrottledStatuses() {
        XCTAssertTrue(GraphThrottle.isThrottled(statusCode: 429, hasRetryAfter: false))
        XCTAssertTrue(GraphThrottle.isThrottled(statusCode: 503, hasRetryAfter: true))
        XCTAssertFalse(GraphThrottle.isThrottled(statusCode: 503, hasRetryAfter: false))
        XCTAssertFalse(GraphThrottle.isThrottled(statusCode: 500, hasRetryAfter: true))
        XCTAssertFalse(GraphThrottle.isThrottled(statusCode: 404, hasRetryAfter: false))
    }

    func testDelayUsesServerValueCapped() {
        XCTAssertEqual(GraphThrottle.delay(forRetry: 1, retryAfter: 7), 7)
        XCTAssertEqual(GraphThrottle.delay(forRetry: 1, retryAfter: 600), GraphThrottle.maxDelay)
    }

    func testDelayBacksOffWithoutHeader() {
        XCTAssertEqual(GraphThrottle.delay(forRetry: 1, retryAfter: nil), 2)
        XCTAssertEqual(GraphThrottle.delay(forRetry: 2, retryAfter: nil), 4)
        XCTAssertEqual(GraphThrottle.delay(forRetry: 3, retryAfter: nil), 8)
        XCTAssertEqual(GraphThrottle.delay(forRetry: 20, retryAfter: nil), GraphThrottle.maxDelay)
    }

    func testAzRestMessages() {
        XCTAssertTrue(GraphThrottle.isThrottledAzRestMessage("ERROR: Too Many Requests({\"error\":{\"code\":\"TooManyRequests\"}})"))
        XCTAssertTrue(GraphThrottle.isThrottledAzRestMessage("ERROR: Service Unavailable({\"error\":{\"message\":\"Request was throttled\"}})"))
        XCTAssertFalse(GraphThrottle.isThrottledAzRestMessage("ERROR: Service Unavailable({})"))
        XCTAssertFalse(GraphThrottle.isThrottledAzRestMessage("ERROR: Not Found({})"))
    }

    func testRetriesThenSucceeds() async throws {
        var attempts = 0
        var waits: [TimeInterval] = []
        let value: Int = try await GraphThrottle.withRetry("test", sleep: { waits.append($0) }) {
            attempts += 1
            if attempts < 3 { throw GraphThrottledError(statusCode: 429, retryAfter: 5, underlying: "") }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, [5, 5])
    }

    func testGivesUpAfterMaxRetries() async {
        var attempts = 0
        do {
            let _: Int = try await GraphThrottle.withRetry("test", sleep: { _ in }) {
                attempts += 1
                throw GraphThrottledError(statusCode: 429, retryAfter: nil, underlying: "")
            }
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is GraphThrottledError)
        }
        XCTAssertEqual(attempts, GraphThrottle.maxRetries + 1)
    }

    func testOtherErrorsAreNotRetried() async {
        var attempts = 0
        do {
            let _: Int = try await GraphThrottle.withRetry("test", sleep: { _ in }) {
                attempts += 1
                throw URLError(.badServerResponse)
            }
            XCTFail("expected throw")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }
}
