import Foundation
import Alamofire

/// One HTTP request FleetMate made. Only the method, the host, the path and
/// the outcome are kept: never headers, never the query string, never a body.
public struct ActivityRequest: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let method: String
    public let host: String
    public let path: String
    /// HTTP status, or nil when the request never got a response.
    public let status: Int?
    public let duration: TimeInterval
    public let failure: String?
    /// Serials this request concerned: read from the URL before the query was
    /// dropped, or from a device id FleetMate has already seen.
    public let serials: [String]

    /// A request with no status succeeded when nothing failed: Graph calls
    /// made through an elevation session report only success or failure.
    public var succeeded: Bool { failure == nil && (status.map { (200..<400).contains($0) } ?? true) }
    public var statusText: String { status.map(String.init) ?? (failure ?? "OK") }
}

/// Something FleetMate was asked to do, and the requests made for it.
public struct ActivityAction: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let service: String
    public let startedAt: Date
    public internal(set) var finishedAt: Date?
    public internal(set) var failure: String?
    public internal(set) var serials: [String]
    public internal(set) var requests: [ActivityRequest]
    /// Requests nobody asked for by name (polling, refreshes) are grouped
    /// into one background row per service.
    public let isBackground: Bool

    public var isFinished: Bool { finishedAt != nil }
    public var result: String {
        if !isFinished { return "Running" }
        if let failure { return "Failed: \(failure)" }
        if requests.contains(where: { !$0.succeeded }) { return isBackground ? "Some failed" : "Failed" }
        return "OK"
    }
}

/// What FleetMate asked each service to do and how it answered, in memory
/// only and capped. Feeds the Activity Log window.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()
    public static let didChange = Notification.Name("FleetMateActivityLogDidChange")

    /// The action the current task is performing, so inline requests file
    /// under it.
    @TaskLocal public static var currentActionId: UUID?

    public let capacity: Int
    private let lock = NSLock()
    private var actions: [ActivityAction] = []
    private var deviceSerials: [String: String] = [:]
    private static let backgroundWindow: TimeInterval = 10

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public var snapshot: [ActivityAction] {
        lock.lock(); defer { lock.unlock() }
        return actions
    }

    public func clear() {
        lock.lock(); actions.removeAll(); lock.unlock()
        notify()
    }

    /// Remember which serial a device id belongs to, so a request that names
    /// only the id can still be found by serial.
    public func remember(serial: String?, forDeviceId id: String?) {
        guard let serial, !serial.isEmpty, let id, !id.isEmpty else { return }
        lock.lock(); deviceSerials[id.lowercased()] = serial; lock.unlock()
    }

    /// Serials already seen for these device ids.
    public func serials(forDeviceIds ids: [String]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ids.compactMap { deviceSerials[$0.lowercased()] }
    }

    /// Run `work` as a named action; requests it makes are listed under it.
    public func perform<T>(_ title: String, service: String, serials: [String] = [], _ work: () async throws -> T) async rethrows -> T {
        let id = begin(title, service: service, serials: serials)
        do {
            let value = try await ActivityLog.$currentActionId.withValue(id) { try await work() }
            finish(id, failure: nil)
            return value
        } catch {
            finish(id, failure: Self.describe(error))
            throw error
        }
    }

    @discardableResult
    public func begin(_ title: String, service: String, serials: [String] = []) -> UUID {
        let action = ActivityAction(id: UUID(), title: Self.sanitizeFailure(title), service: service, startedAt: Date(),
                                    finishedAt: nil, failure: nil, serials: serials, requests: [], isBackground: false)
        append(action)
        return action.id
    }

    public func finish(_ id: UUID, failure: String?) {
        lock.lock()
        if let i = actions.firstIndex(where: { $0.id == id }) {
            actions[i].finishedAt = Date()
            actions[i].failure = failure.map(Self.sanitizeFailure)
        }
        lock.unlock()
        notify()
    }

    /// Record one request. Files it under the task's action when there is
    /// one, else the newest running action for the same service, else that
    /// service's background row.
    public func record(service: String, method: String, url: URL?, status: Int?, startedAt: Date,
                       duration: TimeInterval, failure: String? = nil, actionId: UUID? = ActivityLog.currentActionId) {
        let entry = makeRequest(method: method, url: url, status: status, startedAt: startedAt,
                                duration: duration, failure: failure)
        lock.lock()
        let index: Int
        if let actionId, let i = actions.firstIndex(where: { $0.id == actionId }) {
            index = i
        } else if let i = actions.lastIndex(where: { !$0.isBackground && !$0.isFinished && $0.service == service }) {
            index = i
        } else if let i = actions.lastIndex(where: { $0.isBackground && $0.service == service }),
                  entry.startedAt.timeIntervalSince(actions[i].startedAt) < Self.backgroundWindow {
            index = i
        } else {
            actions.append(ActivityAction(id: UUID(), title: "Background requests", service: service,
                                          startedAt: entry.startedAt, finishedAt: entry.startedAt, failure: nil,
                                          serials: [], requests: [], isBackground: true))
            index = actions.count - 1
        }
        actions[index].requests.append(entry)
        for serial in entry.serials where !actions[index].serials.contains(serial) {
            actions[index].serials.append(serial)
        }
        if actions[index].isBackground { actions[index].finishedAt = Date() }
        trim()
        lock.unlock()
        notify()
    }

    /// Actions whose title, serials or request paths contain `query`.
    public func search(_ query: String) -> [ActivityAction] {
        let all = snapshot
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { action in
            action.title.localizedCaseInsensitiveContains(needle)
                || action.serials.contains { $0.localizedCaseInsensitiveContains(needle) }
                || action.requests.contains { $0.path.localizedCaseInsensitiveContains(needle) }
        }
    }

    // MARK: - Internals

    private func append(_ action: ActivityAction) {
        lock.lock(); actions.append(action); trim(); lock.unlock()
        notify()
    }

    /// Callers hold the lock.
    private func trim() {
        if actions.count > capacity { actions.removeFirst(actions.count - capacity) }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func makeRequest(method: String, url: URL?, status: Int?, startedAt: Date,
                             duration: TimeInterval, failure: String?) -> ActivityRequest {
        let host = url?.host ?? ""
        let rawPath = url?.path ?? ""
        var serials = ActivityMasker.serialsInQuery(url)
        lock.lock()
        for segment in rawPath.split(separator: "/") {
            if let serial = deviceSerials[segment.lowercased()], !serials.contains(serial) { serials.append(serial) }
        }
        lock.unlock()
        let path = Self.sanitizePath(rawPath)
        return ActivityRequest(id: UUID(), startedAt: startedAt, method: method.uppercased(), host: host,
                               path: path, status: status, duration: duration, failure: failure.map(Self.sanitizeFailure), serials: serials)
    }

    /// A short reason for a failure: the HTTP status when there is one,
    /// otherwise the error's message with URLs removed. Never a response body.
    static func describe(_ error: Error) -> String {
        if let af = error as? AFError, let code = af.responseCode { return "HTTP \(code)" }
        if let throttled = error as? GraphThrottledError { return "HTTP \(throttled.statusCode)" }
        if let url = error as? URLError { return "Network error \(url.code.rawValue)" }
        return sanitizeFailure((error as NSError).localizedDescription)
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#)
    private static let emailPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    private static let jwtPattern = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?"#)
    private static let guidPattern = try! NSRegularExpression(pattern: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)

    /// Failure text fit to keep: one line, URLs, emails and tokens removed,
    /// at most 120 characters.
    public static func sanitizeFailure(_ text: String) -> String {
        var result = text.components(separatedBy: .newlines).first ?? ""
        result = replacing(urlPattern, in: result, with: "[url]")
        result = replacing(jwtPattern, in: result, with: "[token]")
        result = replacing(emailPattern, in: result, with: "[email]")
        result = result.split(separator: " ").map { isTokenLike(String($0)) ? "[token]" : String($0) }.joined(separator: " ")
        return result.count > 120 ? String(result.prefix(119)) + "…" : result
    }

    /// A path fit to keep: emails and anything that looks like a key or token
    /// are replaced where they are recorded, not only on export.
    public static func sanitizePath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return decoded.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let text = String(segment)
            if text.isEmpty { return text }
            if matches(emailPattern, text) { return "[email]" }
            if matches(jwtPattern, text) || isTokenLike(text) { return "[token]" }
            return text
        }.joined(separator: "/")
    }

    /// 32 or more characters of key-like alphabet with letters and digits
    /// mixed: an API key, a signature or an opaque token. A GUID is a device
    /// or object id, not a secret, and is kept.
    static func isTokenLike(_ text: String) -> Bool {
        guard text.count >= 32, !matches(guidPattern, text) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~+/="))
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return text.contains(where: \.isLetter) && text.contains(where: \.isNumber)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Feeds every Alamofire session's finished requests into the activity log.
public final class ActivityLogMonitor: EventMonitor, @unchecked Sendable {
    public let queue = DispatchQueue(label: "fleetmate.activity-log", qos: .utility)
    private let service: String
    private let log: ActivityLog

    public init(service: String, log: ActivityLog = .shared) {
        self.service = service
        self.log = log
    }

    public func requestDidFinish(_ request: Request) {
        guard let urlRequest = request.lastRequest ?? request.request else { return }
        let interval = request.metrics?.taskInterval
        log.record(service: service,
                   method: urlRequest.httpMethod ?? "GET",
                   url: urlRequest.url,
                   status: request.response?.statusCode,
                   startedAt: interval?.start ?? Date(),
                   duration: interval?.duration ?? 0,
                   failure: request.response == nil ? request.error.map(ActivityLog.describe) : nil,
                   actionId: nil)
    }
}

public extension Session {
    /// A session whose requests are listed in the Activity Log.
    convenience init(configuration: URLSessionConfiguration, activityService: String) {
        self.init(configuration: configuration, eventMonitors: [ActivityLogMonitor(service: activityService)])
    }
}

public extension URLSession {
    /// `data(for:)`, recorded in the Activity Log under `service`.
    func loggedData(for request: URLRequest, service: String) async throws -> (Data, URLResponse) {
        let started = Date()
        do {
            let (data, response) = try await data(for: request)
            ActivityLog.shared.record(service: service, method: request.httpMethod ?? "GET", url: request.url,
                                      status: (response as? HTTPURLResponse)?.statusCode, startedAt: started,
                                      duration: Date().timeIntervalSince(started))
            return (data, response)
        } catch {
            ActivityLog.shared.record(service: service, method: request.httpMethod ?? "GET", url: request.url,
                                      status: nil, startedAt: started, duration: Date().timeIntervalSince(started),
                                      failure: ActivityLog.describe(error))
            throw error
        }
    }
}
