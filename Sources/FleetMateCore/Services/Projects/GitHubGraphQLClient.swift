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
        self.session = Session(configuration: configuration)
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
        try GitHubRateLimitGate.check()
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
                                GitHubRateLimitGate.tripIfRateLimit(message)
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
        try GitHubRateLimitGate.check()
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
                    switch response.result {
                    case .success(let data):
                        do {
                            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                continuation.resume(throwing: GitHubGraphQLError.invalidResponse)
                                return
                            }
                            
                            if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
                                let message = first["message"] as? String ?? "Unknown GraphQL error"
                                GitHubRateLimitGate.tripIfRateLimit(message)
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
        try GitHubRateLimitGate.check()
        let token = try await ensureToken()
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw GitHubGraphQLError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FleetMate", forHTTPHeaderField: "User-Agent")

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return try await withCheckedThrowingContinuation { continuation in
            session.request(request)
                .validate(statusCode: 200..<300)
                .responseData { response in
                    switch response.result {
                    case .success(let data):
                        continuation.resume(returning: data)
                    case .failure(let error):
                        // 403/429 from REST is the rate limiter — latch it.
                        if let status = response.response?.statusCode, status == 403 || status == 429 {
                            GitHubRateLimitGate.trip()
                        }
                        continuation.resume(throwing: GitHubGraphQLError.networkError(error))
                    }
                }
        }
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
/// their own clients but drain ONE hourly quota. Once GitHub says rate
/// limited, every call from every instance fails fast until the window ends
/// instead of burning more budget (each rejected call still costs points).
enum GitHubRateLimitGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var until: Date?

    static func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let until, until > Date() {
            let time = until.formatted(date: .omitted, time: .shortened)
            throw GitHubGraphQLError.graphQLError("API rate limit exceeded — backing off until \(time)")
        }
        until = nil
    }

    static func trip(for seconds: TimeInterval = 15 * 60) {
        lock.lock(); defer { lock.unlock() }
        let candidate = Date().addingTimeInterval(seconds)
        if until == nil || candidate > until! { until = candidate }
        dbg.warn("GitHub rate limit tripped — gating all clients for \(Int(seconds))s", category: "github")
    }

    /// Trip the gate when an upstream message looks like a rate limit.
    static func tripIfRateLimit(_ message: String) {
        if message.localizedCaseInsensitiveContains("rate limit") { trip() }
    }
}
