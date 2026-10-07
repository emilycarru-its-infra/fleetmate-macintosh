import Foundation
import Alamofire

/// Lightweight GitHub GraphQL API client.
/// Sends POST requests to https://api.github.com/graphql with query + variables.
/// Auth chain: config token → gh CLI → GITHUB_TOKEN/GH_TOKEN env → Keychain → OAuth Device Flow.
public actor GitHubGraphQLClient {
    private static let graphQLEndpoint = "https://api.github.com/graphql"
    
    private let tokenSource: GitHubTokenSource
    private let session: Session
    
    public init(config: GitHubProviderConfig, deviceFlowPrompt: ((String, URL) async -> Void)? = nil) {
        self.tokenSource = GitHubTokenSource(config: config, deviceFlowPrompt: deviceFlowPrompt)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = Session(configuration: configuration, activityService: "GitHub")
    }
    
    /// Authenticates with GitHub by verifying the token.
    public func authenticate() async throws -> Bool {
        guard await tokenSource.token() != nil else {
            print("GitHub GraphQL: No token available")
            return false
        }
        
        struct ViewerResponse: Decodable {
            let viewer: Viewer
            struct Viewer: Decodable { let login: String }
        }
        
        let result: ViewerResponse = try await execute(query: "query { viewer { login } }")
        print("GitHub GraphQL: Authenticated as \(result.viewer.login)")
        return true
    }
    
    /// Executes a GraphQL query/mutation and returns the deserialized "data" portion.
    public func execute<T: Decodable>(query: String, variables: [String: Any]? = nil) async throws -> T {
        try GitHubRateLimitGate.check(.graphql)
        let token = try await ensureToken()
        
        var body: [String: Any] = ["query": query]
        if let variables = variables {
            body["variables"] = variables
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        
        var request = URLRequest(url: URL(string: Self.graphQLEndpoint)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("FleetMate", forHTTPHeaderField: "User-Agent")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(request)
                .validate()
                .responseData { response in
                    if let http = response.response { GitHubRateLimitGate.record(http, bucket: .graphql) }
                    switch response.result {
                    case .success(let data):
                        do {
                            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                continuation.resume(throwing: GitHubGraphQLError.invalidResponse)
                                return
                            }
                            
                            // Check for GraphQL errors
                            if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
                                let message = first["message"] as? String ?? "Unknown GraphQL error"
                                GitHubRateLimitGate.tripIfRateLimit(message, bucket: .graphql, response: response.response)
                                continuation.resume(throwing: GitHubGraphQLError.graphQLError(message))
                                return
                            }
                            
                            guard let dataObj = json["data"] else {
                                continuation.resume(throwing: GitHubGraphQLError.noData)
                                return
                            }
                            
                            let dataJson = try JSONSerialization.data(withJSONObject: dataObj)
                            let decoded = try JSONDecoder().decode(T.self, from: dataJson)
                            continuation.resume(returning: decoded)
                        } catch let error as GitHubGraphQLError {
                            continuation.resume(throwing: error)
                        } catch {
                            continuation.resume(throwing: GitHubGraphQLError.decodingError(error))
                        }
                    case .failure(let error):
                        continuation.resume(throwing: GitHubGraphQLError.networkError(error))
                    }
                }
        }
    }
    
    /// Executes a GraphQL query and returns raw dictionary data.
    public func executeRaw(query: String, variables: [String: Any]? = nil) async throws -> [String: Any] {
        try GitHubRateLimitGate.check(.graphql)
        let token = try await ensureToken()
        
        var body: [String: Any] = ["query": query]
        if let variables = variables {
            body["variables"] = variables
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        
        var request = URLRequest(url: URL(string: Self.graphQLEndpoint)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("FleetMate", forHTTPHeaderField: "User-Agent")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(request)
                .validate()
                .responseData { response in
                    if let http = response.response { GitHubRateLimitGate.record(http, bucket: .graphql) }
                    switch response.result {
                    case .success(let data):
                        do {
                            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                continuation.resume(throwing: GitHubGraphQLError.invalidResponse)
                                return
                            }
                            
                            if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
                                let message = first["message"] as? String ?? "Unknown GraphQL error"
                                GitHubRateLimitGate.tripIfRateLimit(message, bucket: .graphql, response: response.response)
                                continuation.resume(throwing: GitHubGraphQLError.graphQLError(message))
                                return
                            }
                            
                            guard let dataObj = json["data"] as? [String: Any] else {
                                continuation.resume(throwing: GitHubGraphQLError.noData)
                                return
                            }
                            
                            continuation.resume(returning: dataObj)
                        } catch let error as GitHubGraphQLError {
                            continuation.resume(throwing: error)
                        } catch {
                            continuation.resume(throwing: GitHubGraphQLError.decodingError(error))
                        }
                    case .failure(let error):
                        continuation.resume(throwing: GitHubGraphQLError.networkError(error))
                    }
                }
        }
    }
    
    /// Executes a GitHub REST v3 API call and returns raw Data.
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, PATCH, PUT, DELETE).
    ///   - path: Path relative to https://api.github.com (e.g. "/repos/owner/repo/issues/7/comments").
    ///   - body: Optional JSON body dictionary.
    public func executeREST(
        method: String = "GET",
        path: String,
        body: [String: Any]? = nil
    ) async throws -> Data {
        try GitHubRateLimitGate.check(.core)
        let token = try await ensureToken()
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubGraphQLError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        // A conditional GET answered 304 does not count against the hourly
        // budget, so every poll of an unchanged list is free. Inside the
        // interval GitHub asks for (X-Poll-Interval), don't ask at all.
        let cached = method == "GET" ? GitHubLocalCache.shared.restEntry(for: path) : nil
        if let cached, cached.isWithinPollInterval {
            return cached.body
        }
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        } else if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        // URLSession's own cache would answer the 304 itself and hide it.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FleetMate", forHTTPHeaderField: "User-Agent")

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Write endpoints (mark-read, merge, review) answer 200/202/204/205
            // with no body; Alamofire only tolerates an empty body on 204/205
            // by default, so widen it rather than fail on a successful call.
            session.request(request)
                .validate(statusCode: Array(200..<300) + [304])
                .responseData(emptyResponseCodes: [200, 201, 202, 204, 205, 304]) { response in
                    if let http = response.response { GitHubRateLimitGate.record(http, bucket: .core) }
                    switch response.result {
                    case .success(let data):
                        let http = response.response
                        let poll = http?.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init)
                        if http?.statusCode == 304, let cached {
                            GitHubLocalCache.shared.touch(path: path, pollInterval: poll)
                            continuation.resume(returning: cached.body)
                            return
                        }
                        if method == "GET", let http {
                            GitHubLocalCache.shared.storeREST(
                                path: path, body: data,
                                etag: http.value(forHTTPHeaderField: "ETag"),
                                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                pollInterval: poll)
                        }
                        continuation.resume(returning: data)
                    case .failure(let error):
                        continuation.resume(throwing: GitHubGraphQLError.networkError(error))
                    }
                }
        }
    }

    /// GET a REST path whose response is plain text, following one redirect
    /// without the API token. GitHub serves job logs this way: the API
    /// answers 302 to a signed blob URL that rejects an Authorization header.
    public func executeRESTText(path: String) async throws -> String {
        try GitHubRateLimitGate.check(.core)
        let token = try await ensureToken()
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubGraphQLError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FleetMate", forHTTPHeaderField: "User-Agent")

        let first: (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
            session.request(request)
                .redirect(using: Redirector(behavior: .doNotFollow))
                .validate(statusCode: 200..<400)
                .responseData(emptyResponseCodes: [200, 204, 301, 302, 307]) { response in
                    if let http = response.response { GitHubRateLimitGate.record(http, bucket: .core) }
                    switch response.result {
                    case .success(let data):
                        guard let http = response.response else {
                            continuation.resume(throwing: GitHubGraphQLError.invalidResponse)
                            return
                        }
                        continuation.resume(returning: (data, http))
                    case .failure(let error):
                        continuation.resume(throwing: GitHubGraphQLError.networkError(error))
                    }
                }
        }

        if (300..<400).contains(first.1.statusCode) {
            guard let location = first.1.value(forHTTPHeaderField: "Location"), let target = URL(string: location) else {
                throw GitHubGraphQLError.invalidResponse
            }
            let (data, _) = try await URLSession.shared.data(from: target)
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: first.0, as: UTF8.self)
    }

    // MARK: - Token Management

    private func ensureToken() async throws -> String {
        guard let token = await tokenSource.token(), !token.isEmpty else {
            throw GitHubGraphQLError.noToken
        }
        return token
    }
}

// MARK: - Error Types

public enum GitHubGraphQLError: Error, LocalizedError {
    case noToken
    case invalidResponse
    case noData
    case graphQLError(String)
    case networkError(Error)
    case decodingError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .noToken: return "No GitHub authentication token available"
        case .invalidResponse: return "Invalid response from GitHub GraphQL API"
        case .noData: return "No data field in GitHub GraphQL response"
        case .graphQLError(let msg): return "GitHub GraphQL error: \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingError(let err): return "Decoding error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Shared rate-limit gate

/// Process-wide latch shared by every client instance — the dashboard queue,
/// the issues table, the Projects provider and the PR viewer all construct
/// their own clients but drain the same hourly quotas.
///
/// GitHub keeps separate budgets for REST ("core") and GraphQL, so each has
/// its own gate: running GraphQL dry must not stop REST calls that still have
/// budget. The gate closes only when GitHub says so — remaining hits zero,
/// a Retry-After arrives, or a message names the rate limit — and opens at
/// the reset time GitHub gives, not a fixed fifteen minutes. A plain 403 (no
/// permission) no longer closes it at all.
public enum GitHubRateLimitGate {
    public enum Bucket: String, Sendable { case core, graphql }

    public struct Status: Sendable {
        public let remaining: Int?
        public let limit: Int?
        public let resetsAt: Date?
        public let blockedUntil: Date?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked: [Bucket: Date] = [:]
    nonisolated(unsafe) private static var latest: [Bucket: (remaining: Int, limit: Int, reset: Date)] = [:]

    static func check(_ bucket: Bucket) throws {
        lock.lock(); defer { lock.unlock() }
        if let until = blocked[bucket], until > Date() {
            let time = until.formatted(date: .omitted, time: .shortened)
            throw GitHubGraphQLError.graphQLError("API rate limit exceeded — backing off until \(time)")
        }
        blocked[bucket] = nil
    }

    /// The last budget GitHub reported for a bucket, for display.
    public static func status(_ bucket: Bucket) -> Status {
        lock.lock(); defer { lock.unlock() }
        let l = latest[bucket]
        return Status(remaining: l?.remaining, limit: l?.limit, resetsAt: l?.reset,
                      blockedUntil: blocked[bucket].flatMap { $0 > Date() ? $0 : nil })
    }

    /// Read GitHub's rate-limit headers from any response, and close the gate
    /// when they say the budget is spent or a wait is required.
    static func record(_ response: HTTPURLResponse, bucket: Bucket) {
        let header = { (name: String) in response.value(forHTTPHeaderField: name) }
        let remaining = header("X-RateLimit-Remaining").flatMap(Int.init)
        let limit = header("X-RateLimit-Limit").flatMap(Int.init)
        let reset = header("X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let retryAfter = header("Retry-After").flatMap(TimeInterval.init)

        lock.lock()
        let previous = latest[bucket]
        if let remaining, let limit, let reset { latest[bucket] = (remaining, limit, reset) }
        lock.unlock()

        // Budget trace, one line per call, to measure what a working day of
        // FleetMate spends (#137). Spent is the drop since this process's last
        // call in the same window; other tools on the same account also move
        // it, so a large drop with no FleetMate call between is someone else.
        if let remaining, let limit {
            let sameWindow = previous.map { $0.reset == reset } ?? false
            let spent = sameWindow ? max(0, (previous?.remaining ?? remaining) - remaining) : 0
            let path = response.url?.path ?? "?"
            dbg.info("budget \(bucket.rawValue) status=\(response.statusCode) remaining=\(remaining)/\(limit) spent=\(spent) \(path)", category: "github-budget")
        }

        let limited = response.statusCode == 403 || response.statusCode == 429
        if let retryAfter, limited {
            // Secondary (burst) limit: GitHub names the wait.
            close(bucket, until: Date().addingTimeInterval(retryAfter))
        } else if remaining == 0, let reset {
            close(bucket, until: reset)
        } else if response.statusCode == 429 {
            close(bucket, until: Date().addingTimeInterval(60))
        }
    }

    /// A GraphQL error body that names the rate limit. Prefer the reset
    /// GitHub sent; a secondary limit without one waits a minute.
    static func tripIfRateLimit(_ message: String, bucket: Bucket, response: HTTPURLResponse?) {
        guard message.localizedCaseInsensitiveContains("rate limit") else { return }
        let reset = response?.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let remaining = response?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        if remaining == 0, let reset, reset > Date() {
            close(bucket, until: reset)
        } else {
            close(bucket, until: Date().addingTimeInterval(60))
        }
    }

    private static func close(_ bucket: Bucket, until: Date) {
        lock.lock(); defer { lock.unlock() }
        if let current = blocked[bucket], current >= until { return }
        blocked[bucket] = until
        dbg.warn("GitHub \(bucket.rawValue) rate limit — gated until \(until.formatted(date: .omitted, time: .standard))", category: "github")
    }
}

