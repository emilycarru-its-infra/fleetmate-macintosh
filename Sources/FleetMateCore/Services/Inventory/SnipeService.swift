import Foundation
import Alamofire

/// Client for Snipe-IT Asset Management API
/// https://snipe-it.readme.io/reference/api-overview
public class SnipeService {
    public let baseUrl: String
    public let apiKey: String
    /// When set, authenticate with an Entra bearer token for this audience
    /// (SSO / az model) instead of the shared Snipe API key. Dormant until
    /// Snipe-IT's OIDC guard ships (ADO #3721). See FleetMateConfig.
    public let oidcAudience: String?

    private var session: Session
    private var assetCache: [SnipeAsset]?
    private var assetCacheExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval

    // SSO cookie-based auth
    private var ssoCookies: [HTTPCookie]?
    public private(set) var ssoUserName: String?
    public private(set) var ssoAuthenticated: Bool = false

    public var isConfigured: Bool {
        return !baseUrl.isEmpty && (!apiKey.isEmpty || ssoAuthenticated)
    }

    /// True when SSO is preferred but not yet authenticated
    public var shouldAttemptSso: Bool {
        return !baseUrl.isEmpty && !ssoAuthenticated
    }

    public var authenticatedUserName: String? {
        ssoUserName
    }

    public init(baseUrl: String?, apiKey: String?, oidcAudience: String? = nil, cacheMinutes: Int = 5) {
        self.baseUrl = (baseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey ?? ""
        self.oidcAudience = (oidcAudience?.isEmpty == false) ? oidcAudience : nil
        self.cacheDuration = TimeInterval(cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120

        self.session = Session(configuration: configuration)
    }

    // MARK: - SSO Cookie Management

    /// After WKWebView SSO login, Snipe-IT sets:
    /// - `snipeit_session` — Laravel session cookie
    /// - `snipeit_passport_token` — Encrypted JWT for API auth (set by CreateFreshApiToken middleware)
    /// - `XSRF-TOKEN` — CSRF token (must be sent back as X-XSRF-TOKEN header, URL-decoded)
    /// This mimics exactly how a browser interacts with Snipe-IT after SSO.
    public func setSsoCookies(_ cookies: [HTTPCookie], userName: String?) {
        ssoCookies = cookies
        ssoUserName = userName
        ssoAuthenticated = true

        // Inject cookies into shared storage so Alamofire picks them up
        let storage = HTTPCookieStorage.shared
        for cookie in cookies {
            storage.setCookie(cookie)
        }

        // Recreate session with cookie support enabled
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = storage
        session = Session(configuration: configuration)
    }

    public func clearSsoCookies() {
        if let cookies = ssoCookies {
            let storage = HTTPCookieStorage.shared
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
        ssoCookies = nil
        ssoUserName = nil
        ssoAuthenticated = false

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        session = Session(configuration: configuration)
    }

    /// Extract the XSRF token from cookies (Laravel expects it URL-decoded in X-XSRF-TOKEN header)
    private var xsrfToken: String? {
        guard let cookies = ssoCookies else { return nil }
        return cookies
            .first(where: { $0.name == "XSRF-TOKEN" })?
            .value
            .removingPercentEncoding
    }

    private var headers: HTTPHeaders {
        if ssoAuthenticated, ssoCookies != nil {
            // Cookie-based auth — mimic browser behavior.
            // Cookies (session + passport token) are on the session's cookie storage.
            // Laravel requires X-XSRF-TOKEN header for CSRF protection on cookie-auth requests.
            var h: HTTPHeaders = [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "X-Requested-With": "XMLHttpRequest",
                "Referer": baseUrl,
            ]
            if let xsrf = xsrfToken {
                h.add(name: "X-XSRF-TOKEN", value: xsrf)
            }
            return h
        }
        return [
            "Authorization": "Bearer \(apiKey)",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
    }

    /// True when configured to use Entra bearer (SSO) auth rather than the API key.
    public var usesOidc: Bool { oidcAudience != nil }

    /// Resolve auth headers: an Entra bearer token minted off the operator's
    /// az/login session when an OIDC audience is configured (prefer-bearer),
    /// otherwise the legacy SSO-cookie / API-key headers. Dormant until
    /// `snipe_oidc_audience` is set.
    private func authHeaders() async throws -> HTTPHeaders {
        if let audience = oidcAudience {
            let token = try await AzTokenSource.shared.token(forResource: audience)
            return [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "Content-Type": "application/json",
            ]
        }
        return headers
    }
    
    // MARK: - Assets
    
    /// Fetch all assets with pagination (no limit)
    /// - Parameters:
    ///   - search: Optional search query (matches serial, asset tag, name, etc.)
    ///   - includeArchived: If true, includes assets with archived status (default: true)
    /// - Returns: Array of all matching assets
    public func getAllAssets(search: String? = nil, includeArchived: Bool = true) async throws -> [SnipeAsset] {
        var allAssets: [SnipeAsset] = []
        var offset = 0
        let pageSize = 500
        
        while true {
            var parameters: [String: Any] = [
                "limit": pageSize,
                "offset": offset
            ]
            if let search = search { parameters["search"] = search }
            
            let assets: [SnipeAsset] = try await fetchList("/api/v1/hardware", parameters: parameters)
            
            if assets.isEmpty {
                break
            }
            
            allAssets.append(contentsOf: assets)
            offset += pageSize
            
            // Safety check - stop if we got less than a full page (last page)
            if assets.count < pageSize {
                break
            }
        }
        
        return allAssets
    }
    
    public func getAssets(search: String? = nil, statusId: Int? = nil, locationId: Int? = nil, limit: Int = 500) async throws -> [SnipeAsset] {
        var parameters: [String: Any] = ["limit": limit]
        if let search = search { parameters["search"] = search }
        if let statusId = statusId { parameters["status_id"] = statusId }
        if let locationId = locationId { parameters["location_id"] = locationId }
        
        return try await fetchList("/api/v1/hardware", parameters: parameters)
    }
    
    public func getAsset(id: Int) async throws -> SnipeAsset? {
        return try await fetch("/api/v1/hardware/\(id)")
    }
    
    public func getAssetByTag(_ tag: String) async throws -> SnipeAsset? {
        let assets: [SnipeAsset] = try await fetchList("/api/v1/hardware", parameters: ["search": tag])
        return assets.first { $0.assetTag == tag }
    }
    
    public func getAssetBySerial(_ serial: String) async throws -> SnipeAsset? {
        return try await fetch("/api/v1/hardware/byserial/\(serial)")
    }
    
    // MARK: - Users
    
    public func getUsers(search: String? = nil) async throws -> [SnipeUser] {
        var parameters: [String: Any] = ["limit": 500]
        if let search = search { parameters["search"] = search }
        return try await fetchList("/api/v1/users", parameters: parameters)
    }
    
    public func getUser(id: Int) async throws -> SnipeUser? {
        return try await fetch("/api/v1/users/\(id)")
    }
    
    // MARK: - Locations
    
    public func getLocations() async throws -> [SnipeLocation] {
        return try await fetchList("/api/v1/locations", parameters: ["limit": 500])
    }
    
    // MARK: - Models
    
    public func getModels() async throws -> [SnipeModel] {
        return try await fetchList("/api/v1/models", parameters: ["limit": 500])
    }
    
    // MARK: - Categories
    
    public func getCategories() async throws -> [SnipeCategory] {
        return try await fetchList("/api/v1/categories", parameters: ["limit": 500])
    }
    
    // MARK: - Status Labels
    
    public func getStatusLabels() async throws -> [SnipeStatusLabel] {
        return try await fetchList("/api/v1/statuslabels", parameters: ["limit": 500])
    }
    
    // MARK: - Activity Reports
    
    public func getActivityLog(limit: Int = 15) async throws -> [SnipeActivityLog] {
        return try await fetchList("/api/v1/reports/activity", parameters: ["limit": limit, "order": "desc", "sort": "created_at"])
    }
    
    // MARK: - Asset Operations
    
    public func checkoutAsset(assetId: Int, request: SnipeCheckoutRequest) async throws -> SnipeResponse {
        return try await post("/api/v1/hardware/\(assetId)/checkout", body: request)
    }
    
    public func checkinAsset(assetId: Int, request: SnipeCheckinRequest? = nil) async throws -> SnipeResponse {
        return try await post("/api/v1/hardware/\(assetId)/checkin", body: request ?? SnipeCheckinRequest())
    }
    
    public func auditAsset(assetId: Int, request: SnipeAuditRequest? = nil) async throws -> SnipeResponse {
        return try await post("/api/v1/hardware/\(assetId)/audit", body: request ?? SnipeAuditRequest())
    }

    public func updateAsset(assetId: Int, request: SnipeAssetUpdateRequest) async throws -> SnipeResponse {
        return try await put("/api/v1/hardware/\(assetId)", body: request)
    }
    
    // MARK: - Private Helpers
    
    private func fetch<T: Decodable>(_ path: String) async throws -> T? {
        let url = "\(baseUrl)\(path)"
        
        let hdrs = try await authHeaders()
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: hdrs)
                .validate()
                .responseDecodable(of: T.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        if case .responseValidationFailed(reason: .unacceptableStatusCode(code: 404)) = error {
                            continuation.resume(returning: nil)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
        }
    }
    
    private func fetchList<T: Decodable>(_ path: String, parameters: [String: Any] = [:]) async throws -> [T] {
        let url = "\(baseUrl)\(path)"
        
        let hdrs = try await authHeaders()
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, parameters: parameters, headers: hdrs)
                .validate()
                .responseDecodable(of: SnipeListResponse<T>.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value.rows)
                    case .failure(let error):
                        // Log detailed decode error
                        if case .responseSerializationFailed(let reason) = error {
                            if case .decodingFailed(let decodingError) = reason {
                                print("[SnipeService] Decode error: \(decodingError)")
                            }
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    private func post<T: Encodable, R: Decodable>(_ path: String, body: T) async throws -> R {
        let url = "\(baseUrl)\(path)"
        
        let hdrs = try await authHeaders()
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoder: JSONParameterEncoder.default, headers: hdrs)
                .validate(statusCode: 200..<500)  // allow 4xx so we can decode Snipe-IT error bodies
                .responseDecodable(of: R.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        if let data = response.data, let body = String(data: data, encoding: .utf8) {
                            print("[SnipeService POST] Decode failure body: \(body.prefix(400))")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    private func put<T: Encodable, R: Decodable>(_ path: String, body: T) async throws -> R {
        let url = "\(baseUrl)\(path)"

        let hdrs = try await authHeaders()
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .put, parameters: body, encoder: JSONParameterEncoder.default, headers: hdrs)
                .validate(statusCode: 200..<500)
                .responseDecodable(of: R.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        if let data = response.data, let body = String(data: data, encoding: .utf8) {
                            print("[SnipeService PUT] Decode failure body: \(body.prefix(400))")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
}
