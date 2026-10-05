import Foundation

/// A Graph response that asked the caller to slow down: 429, or a 503 that
/// carried `Retry-After`. `retryAfter` is the server's requested wait, when it
/// gave one.
public struct GraphThrottledError: Error, Sendable, CustomStringConvertible {
    public let statusCode: Int
    public let retryAfter: TimeInterval?
    public let underlying: String

    public var description: String {
        "Graph throttled the request (HTTP \(statusCode)): \(underlying)"
    }
}

/// Retry policy for throttled Microsoft Graph requests. Graph throttles per
/// application and answers 429 with a `Retry-After` header; a bulk action or a
/// whole-tenant read should wait it out rather than fail partway through.
///
/// The decisions are pure functions so they can be tested without a network.
public enum GraphThrottle {
    /// Retries after the first attempt, so a request is tried at most four times.
    public static let maxRetries = 3
    /// The longest single wait, whatever the server asks for.
    public static let maxDelay: TimeInterval = 60
    /// Waits used when the server gives no `Retry-After`: 2s, 4s, 8s.
    public static let baseDelay: TimeInterval = 2

    /// Parse a `Retry-After` header value: either delta-seconds or an HTTP-date.
    /// Returns nil for a missing or unreadable value; a date in the past is 0.
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) {
            return seconds >= 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Whether a response status should be retried. A 503 counts only when the
    /// server said when to come back; a bare 503 is an outage, not a throttle.
    public static func isThrottled(statusCode: Int, hasRetryAfter: Bool) -> Bool {
        statusCode == 429 || (statusCode == 503 && hasRetryAfter)
    }

    /// The wait before retry number `retry` (1-based): the server's value when it
    /// gave one, otherwise exponential backoff — both capped at `maxDelay`.
    public static func delay(forRetry retry: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(retryAfter, maxDelay) }
        let backoff = baseDelay * pow(2, Double(max(0, retry - 1)))
        return min(backoff, maxDelay)
    }

    /// `az rest` reports an HTTP failure as text such as
    /// `Too Many Requests({"error":…})` and does not print response headers, so
    /// the elevation path can tell a throttle apart but never knows the wait.
    public static func isThrottledAzRestMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("too many requests") || lower.contains("toomanyrequests") { return true }
        // A 503 counts only when Graph says it is throttling, matching the HTTP rule.
        return lower.contains("service unavailable") && lower.contains("throttl")
    }

    /// Run `operation`, retrying while it throws `GraphThrottledError`.
    static func withRetry<T>(
        _ label: String,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        _ operation: () async throws -> T
    ) async throws -> T {
        var retry = 0
        while true {
            do {
                return try await operation()
            } catch let error as GraphThrottledError {
                retry += 1
                guard retry <= maxRetries else { throw error }
                let wait = delay(forRetry: retry, retryAfter: error.retryAfter)
                DebugLogger.shared.warn(
                    "Graph throttled \(label) (HTTP \(error.statusCode)); retry \(retry)/\(maxRetries) in \(Int(wait.rounded()))s",
                    category: "graph"
                )
                try await sleep(wait)
            }
        }
    }

    /// Turn a failed HTTP response into `GraphThrottledError` when it is a
    /// throttle, otherwise hand back the original error.
    static func classify(_ response: HTTPURLResponse?, error: Error) -> Error {
        guard let response else { return error }
        let header = response.value(forHTTPHeaderField: "Retry-After")
        let retryAfter = parseRetryAfter(header)
        guard isThrottled(statusCode: response.statusCode, hasRetryAfter: retryAfter != nil) else { return error }
        return GraphThrottledError(statusCode: response.statusCode, retryAfter: retryAfter, underlying: "\(error)")
    }
}
