import Foundation

/// Records outgoing requests and answers them from a canned response table.
///
/// This exists so the contract tests can assert what a service *actually puts
/// on the wire* while running the service's real code path — the alternative,
/// asserting against a hand-written copy of the URL-building logic, passes just
/// as happily when the real call is pointed at an endpoint that doesn't exist.
final class StubURLProtocol: URLProtocol {

    struct RecordedRequest {
        let method: String
        let url: URL
        let body: Data?
        let headers: [String: String]

        var path: String { url.path }
        var query: String? { url.query }

        /// The body decoded as a JSON object, for field-level assertions.
        var jsonObject: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }

        /// The body decoded as a JSON array — TDX's PATCH payloads are arrays.
        var jsonArray: [[String: Any]]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [[String: Any]]
        }
    }

    /// Responses keyed by a substring of the request path. First match wins, so
    /// register more specific paths before more general ones.
    struct Stub {
        let pathContains: String
        let method: String?
        let statusCode: Int
        let body: String

        init(pathContains: String, method: String? = nil, statusCode: Int = 200, body: String) {
            self.pathContains = pathContains
            self.method = method
            self.statusCode = statusCode
            self.body = body
        }
    }

    private static let lock = NSLock()
    private static var _stubs: [Stub] = []
    private static var _recorded: [RecordedRequest] = []

    static var recorded: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    /// Every recorded request that is not the TDX auth handshake.
    static var apiCalls: [RecordedRequest] {
        recorded.filter { !$0.path.contains("/auth/") }
    }

    static func reset(stubs: [Stub]) {
        lock.lock(); defer { lock.unlock() }
        _stubs = stubs
        _recorded = []
    }

    /// A URLSession configuration that routes everything through this stub.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url ?? URL(string: "about:blank")!,
            body: body,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        Self.lock.lock()
        Self._recorded.append(recorded)
        let stub = Self._stubs.first {
            recorded.path.contains($0.pathContains) && ($0.method == nil || $0.method == recorded.method)
        }
        Self.lock.unlock()

        let statusCode = stub?.statusCode ?? 200
        let payload = stub?.body ?? "{}"
        let response = HTTPURLResponse(
            url: recorded.url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves a request body onto `httpBodyStream`, leaving
    /// `httpBody` nil by the time a URLProtocol sees it.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
