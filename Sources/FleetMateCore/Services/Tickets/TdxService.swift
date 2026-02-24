import Foundation
import Alamofire

/// TeamDynamix (TDX) service for ticket management
/// Uses JWT authentication via SSO, username/password, or BEID
public class TdxService {
    private let config: FleetMateConfig
    private let session: Session
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast
    
    // SSO authentication state
    private var ssoToken: String?
    private var ssoTokenExpiry: Date = .distantPast
    private var ssoUserId: String?
    private var ssoUserName: String?

    // Reference data caches
    private var statusCache: [Int: String] = [:]
    private var typeCache: [Int: String] = [:]
    private var priorityCache: [Int: String] = [:]
    private var formCache: [(id: Int, name: String)] = []
    private var refDataExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval

    public var isConfigured: Bool {
        return config.isTdxConfigured
    }

    public var baseUrl: String {
        (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    /// Returns true if SSO authentication is active and valid
    public var isSsoAuthenticated: Bool {
        guard let token = ssoToken, !token.isEmpty else { return false }
        return Date() < ssoTokenExpiry
    }
    
    /// The authenticated SSO user's display name
    public var authenticatedUserName: String? {
        return isSsoAuthenticated ? ssoUserName : nil
    }
    
    /// The authenticated SSO user's ID
    public var authenticatedUserId: String? {
        return isSsoAuthenticated ? ssoUserId : nil
    }
    
    /// Returns true if SSO authentication is required based on config
    public var requiresSsoLogin: Bool {
        let method = config.tdxAuthMethod
        switch method {
        case .browserSSO:
            return !isSsoAuthenticated
        case .auto:
            // SSO preferred, but can fall back to service account
            return false
        case .serviceAccount, .userPassword:
            return false
        }
    }
    
    /// Returns true if SSO should be attempted (based on config)
    public var shouldAttemptSso: Bool {
        let method = config.tdxAuthMethod
        return method == .browserSSO || method == .auto
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = Session(configuration: configuration)
    }
    
    // MARK: - SSO Authentication
    
    /// Set SSO token from external SSO login flow
    public func setSsoToken(_ token: String, expiry: Date, userId: String? = nil, userName: String? = nil) {
        self.ssoToken = token
        self.ssoTokenExpiry = expiry
        self.ssoUserId = userId
        self.ssoUserName = userName
    }
    
    /// Clear SSO authentication state
    public func clearSsoToken() {
        self.ssoToken = nil
        self.ssoTokenExpiry = .distantPast
        self.ssoUserId = nil
        self.ssoUserName = nil
    }

    // MARK: - Authentication

    private func getAccessToken() async throws -> String? {
        let authMethod = config.tdxAuthMethod
        dbg.debug("TDX getAccessToken (method=\(authMethod), ssoValid=\(ssoToken != nil && Date() < ssoTokenExpiry))", category: "tdx-auth")
        
        // Check for valid SSO token first (if SSO is configured)
        if authMethod == .browserSSO || authMethod == .auto {
            if let token = ssoToken, !token.isEmpty, Date() < ssoTokenExpiry {
                dbg.info("TDX using SSO token (expires in \(Int(ssoTokenExpiry.timeIntervalSinceNow))s)", category: "tdx-auth")
                return token
            }
            
            // If browserSSO is required and no valid token, return nil
            if authMethod == .browserSSO {
                dbg.warn("TDX browserSSO required but no valid SSO token", category: "tdx-auth")
                return nil
            }
        }
        
        // Check cached service account / password token
        if let token = cachedToken, Date() < tokenExpiry {
            dbg.debug("TDX using cached service token", category: "tdx-auth")
            return token
        }
        
        // For SSO-only mode, don't fall back to service account
        if authMethod == .browserSSO {
            return nil
        }

        // Try admin login first (BEID + WebServicesKey)
        if authMethod == .serviceAccount || authMethod == .auto {
            if let beid = config.tdxBeid, let webServicesKey = config.tdxWebServicesKey,
               !beid.isEmpty, !webServicesKey.isEmpty {
                dbg.info("TDX trying admin login (BEID)", category: "tdx-auth")
                let loginUrl = "\(baseUrl)/api/auth/loginadmin"
                let body: [String: String] = [
                    "BEID": beid,
                    "WebServicesKey": webServicesKey
                ]

                if let token = try? await authenticate(url: loginUrl, body: body) {
                    cachedToken = token
                    tokenExpiry = Date().addingTimeInterval(23 * 60 * 60) // 23 hours
                    dbg.info("TDX admin login OK (\(token.count) chars)", category: "tdx-auth")
                    return token
                } else {
                    dbg.warn("TDX admin login failed", category: "tdx-auth")
                }
            }
        }

        // Fallback to regular login (if configured for password auth)
        if authMethod == .userPassword || authMethod == .auto {
            guard let username = config.tdxUsername, let password = config.tdxPassword,
                  !username.isEmpty, !password.isEmpty else {
                dbg.warn("TDX credentials not configured", category: "tdx-auth")
                return nil
            }

            let loginUrl = "\(baseUrl)/api/auth/login"
            let body: [String: String] = [
                "UserName": username,
                "Password": password
            ]

            if let token = try? await authenticate(url: loginUrl, body: body) {
                cachedToken = token
                tokenExpiry = Date().addingTimeInterval(23 * 60 * 60)
                return token
            }
        }

        return nil
    }

    private func authenticate(url: String, body: [String: String]) async throws -> String? {
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoding: JSONEncoding.default)
                .validate()
                .responseString { response in
                    switch response.result {
                    case .success(let token):
                        let cleanToken = token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        continuation.resume(returning: cleanToken)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    private func headers() async -> HTTPHeaders? {
        guard let token = try? await getAccessToken() else { return nil }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    // MARK: - Tickets

    public func searchTickets(search: TicketSearchRequest? = nil, maxResults: Int = 50) async throws -> [TdxTicket] {
        dbg.info("TDX searchTickets (maxResults=\(maxResults))", category: "tdx")
        guard let headers = await headers() else {
            dbg.warn("TDX searchTickets — no auth headers, returning []", category: "tdx")
            return []
        }

        var request = search ?? TicketSearchRequest()
        request.maxResults = maxResults

        let url = config.tdxTicketsUrl("search")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .responseDecodable(of: [TdxTicket].self) { response in
                    switch response.result {
                    case .success(let tickets):
                        continuation.resume(returning: tickets)
                    case .failure(let error):
                        // Log response body for 400 errors to help diagnose
                        if let data = response.data, let statusCode = response.response?.statusCode, statusCode == 400 {
                            let responseBody = String(data: data, encoding: .utf8) ?? "(unable to decode)"
                            dbg.warn("TDX 400 Bad Request from search: \(responseBody)", category: "tdx")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    public func getTicket(id: Int) async throws -> TdxTicket? {
        guard let headers = await headers() else { return nil }

        let url = config.tdxTicketsUrl("\(id)")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: TdxTicket.self) { response in
                    switch response.result {
                    case .success(let ticket):
                        continuation.resume(returning: ticket)
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

    public func createTicket(request: CreateTicketRequest) async throws -> TdxTicket? {
        guard let headers = await headers() else { return nil }

        var createRequest = request

        // Apply defaults
        if createRequest.typeId == 0 {
            createRequest.typeId = config.tdxDefaultTypeId ?? 0
        }
        if createRequest.statusId == nil {
            createRequest.statusId = config.tdxDefaultStatusId
        }
        if createRequest.priorityId == nil {
            createRequest.priorityId = config.tdxDefaultPriorityId
        }
        if createRequest.sourceId == nil {
            createRequest.sourceId = config.tdxDefaultSourceId
        }
        if createRequest.accountId == nil {
            createRequest.accountId = config.tdxDefaultAccountId
        }

        let url = config.tdxTicketsUrl()

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: createRequest, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .responseDecodable(of: TdxTicket.self) { response in
                    switch response.result {
                    case .success(let ticket):
                        continuation.resume(returning: ticket)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    public func updateTicket(id: Int, updates: [String: Any], notifyNewResponsible: Bool = false) async throws -> TdxTicket? {
        guard let headers = await headers() else { return nil }

        var url = config.tdxTicketsUrl("\(id)")
        if notifyNewResponsible {
            url += "?notifyNewResponsible=true"
        }
        dbg.info("TDX PATCH updateTicket \(id) fields: \(updates.keys.sorted())", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .patch, parameters: updates, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseDecodable(of: TdxTicket.self) { response in
                    switch response.result {
                    case .success(let ticket):
                        continuation.resume(returning: ticket)
                    case .failure(let error):
                        if let data = response.data {
                            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                            dbg.warn("TDX PATCH updateTicket \(id) error (\(response.response?.statusCode ?? 0)): \(body)", category: "tdx")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    /// Update a ticket using a full TicketUpdateRequest (required fields included to avoid 400).
    /// Uses POST — TDX's PATCH is really a full replace and POST is the reliable method.
    public func updateTicket(id: Int, request: TicketUpdateRequest, notifyNewResponsible: Bool = false) async throws -> TdxTicket? {
        guard let headers = await headers() else { return nil }

        var url = config.tdxTicketsUrl("\(id)")
        if notifyNewResponsible {
            url += "?notifyNewResponsible=true"
        }
        dbg.info("TDX updateTicket \(id) → POST \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .responseDecodable(of: TdxTicket.self) { response in
                    switch response.result {
                    case .success(let ticket):
                        continuation.resume(returning: ticket)
                    case .failure(let error):
                        if let data = response.data {
                            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                            dbg.warn("TDX updateTicket \(id) error (\(response.response?.statusCode ?? 0)): \(body)", category: "tdx")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    // MARK: - Feed (Comments)

    public func getTicketFeed(ticketId: Int) async throws -> [TdxFeedEntry] {
        guard let headers = await headers() else { return [] }

        let url = config.tdxTicketsUrl("\(ticketId)/feed")
        dbg.debug("TDX getTicketFeed → GET \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseData { dataResponse in
                    // Log raw JSON to diagnose threading
                    if let data = dataResponse.data {
                        if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                            for (i, item) in jsonArray.prefix(5).enumerated() {
                                let hasReplies = item["Replies"] as? [[String: Any]]
                                let replyCount = hasReplies?.count ?? 0
                                let body = (item["Body"] as? String)?.prefix(40) ?? "nil"
                                // Dump ALL keys to find parent/depth/threading fields
                                let keys = item.keys.sorted().joined(separator: ", ")
                                dbg.debug("TDX feed[\(i)] keys: \(keys)", category: "tdx")
                                dbg.debug("TDX feed[\(i)]: id=\(item["ID"] ?? "?") type=\(item["ItemType"] ?? "?") replies=\(replyCount) parentId=\(item["ParentID"] ?? item["ParentId"] ?? "nil") body=\(body)", category: "tdx")
                            }
                        }
                        do {
                            let feed = try JSONDecoder().decode([TdxFeedEntry].self, from: data)
                            let withReplies = feed.filter { ($0.replies?.count ?? 0) > 0 }
                            dbg.debug("TDX feed decoded: \(feed.count) entries, \(withReplies.count) with replies", category: "tdx")
                            continuation.resume(returning: feed)
                        } catch {
                            dbg.error("TDX feed decode error: \(error)", category: "tdx")
                            continuation.resume(throwing: error)
                        }
                    } else if let error = dataResponse.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: [])
                    }
                }
        }
    }

    public func addComment(ticketId: Int, comment: String, isPrivate: Bool = false, notify: [String]? = nil) async throws -> Bool {
        guard let headers = await headers() else { return false }

        let request = CreateFeedEntryRequest(
            comments: comment,
            isPrivate: isPrivate,
            notify: notify
        )

        let url = config.tdxTicketsUrl("\(ticketId)/feed")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .response { response in
                    switch response.result {
                    case .success:
                        continuation.resume(returning: true)
                    case .failure:
                        continuation.resume(returning: false)
                    }
                }
        }
    }

    /// Reply to an existing feed entry (threaded comment)
    public func replyToFeedEntry(ticketId: Int, feedEntryId: Int, comment: String, isPrivate: Bool = false, notify: [String]? = nil) async throws -> Bool {
        guard let headers = await headers() else { return false }

        let request = CreateFeedEntryRequest(
            comments: comment,
            isPrivate: isPrivate,
            notify: notify
        )

        let url = config.tdxTicketsUrl("\(ticketId)/feed/\(feedEntryId)")
        dbg.debug("TDX replyToFeedEntry → POST \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .response { response in
                    switch response.result {
                    case .success:
                        continuation.resume(returning: true)
                    case .failure:
                        continuation.resume(returning: false)
                    }
                }
        }
    }

    // MARK: - People Search

    /// Search for people in TDX by name or email
    public func searchPeople(searchText: String, maxResults: Int = 10) async throws -> [TdxPerson] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let headers = await headers() else { return [] }

        let encoded = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchText
        let url = config.tdxPeopleUrl("lookup?searchText=\(encoded)&maxResults=\(maxResults)")
        dbg.debug("TDX searchPeople → GET \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [TdxPerson].self) { response in
                    switch response.result {
                    case .success(let people):
                        continuation.resume(returning: people)
                    case .failure(let error):
                        dbg.warn("TDX searchPeople failed: \(error.localizedDescription)", category: "tdx")
                        continuation.resume(returning: [])
                    }
                }
        }
    }

    // MARK: - Reference Data

    public func getStatuses() async throws -> [Int: String] {
        if !statusCache.isEmpty && Date() < refDataExpiry {
            return statusCache
        }

        guard let headers = await headers() else { return statusCache }

        let url = "\(baseUrl)/api/\(config.tdxAppId ?? 0)/tickets/statuses"

        let statuses: [TdxStatusItem] = try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [TdxStatusItem].self) { response in
                    switch response.result {
                    case .success(let items):
                        continuation.resume(returning: items)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }

        statusCache = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0.name ?? "Status \($0.id)") })
        refDataExpiry = Date().addingTimeInterval(cacheDuration)

        return statusCache
    }

    public func getTypes() async throws -> [Int: String] {
        if !typeCache.isEmpty && Date() < refDataExpiry {
            return typeCache
        }

        guard let headers = await headers() else { return typeCache }

        let url = "\(baseUrl)/api/\(config.tdxAppId ?? 0)/tickets/types"

        let types: [TdxTypeItem] = try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [TdxTypeItem].self) { response in
                    switch response.result {
                    case .success(let items):
                        continuation.resume(returning: items)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }

        typeCache = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0.name ?? "Type \($0.id)") })

        return typeCache
    }

    public func getPriorities() async throws -> [Int: String] {
        if !priorityCache.isEmpty && Date() < refDataExpiry {
            return priorityCache
        }

        guard let headers = await headers() else { return priorityCache }

        let url = "\(baseUrl)/api/\(config.tdxAppId ?? 0)/tickets/priorities"

        let priorities: [TdxPriorityItem] = try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [TdxPriorityItem].self) { response in
                    switch response.result {
                    case .success(let items):
                        continuation.resume(returning: items)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }

        priorityCache = Dictionary(uniqueKeysWithValues: priorities.map { ($0.id, $0.name ?? "Priority \($0.id)") })

        return priorityCache
    }

    public func getForms() async throws -> [(id: Int, name: String)] {
        if !formCache.isEmpty && Date() < refDataExpiry {
            return formCache
        }

        guard let headers = await headers() else { return formCache }

        let appId = config.tdxTicketingAppId ?? config.tdxAppId ?? 0
        let url = "\(baseUrl)/api/\(appId)/tickets/forms"

        let forms: [TdxFormItem] = try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [TdxFormItem].self) { response in
                    switch response.result {
                    case .success(let items):
                        continuation.resume(returning: items)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }

        var result: [(id: Int, name: String)] = []
        for form in forms {
            if let name = form.name, !name.isEmpty, form.active != false {
                result.append((id: form.id, name: name))
            }
        }
        formCache = result.sorted { $0.name < $1.name }

        return formCache
    }
}
