import Foundation
import Alamofire

/// Why a TDX call couldn't be made at all.
public enum TdxAuthError: LocalizedError {
    /// No usable credential. With the service account gone, this means SSO
    /// hasn't completed — every call used to return an empty list instead,
    /// which read as "TeamDynamix has no tickets" and hid the real cause.
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to TeamDynamix. Sign in with SSO to load tickets."
        }
    }
}

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

    // Cookie-based SSO (when JWT is unavailable)
    private var ssoCookies: [HTTPCookie]?
    private var cookieSession: Session?

    // Reference data caches
    private var statusCache: [Int: String] = [:]
    private var typeCache: [Int: String] = [:]
    private var priorityCache: [Int: String] = [:]
    private var formCache: [(id: Int, name: String)] = []
    private var sourceCache: [TdxLookupItem] = []
    private var accountCache: [TdxLookupItem] = []
    private var groupCache: [TdxLookupItem] = []
    private var serviceCache: [TdxLookupItem] = []
    private var refDataExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval

    public var isConfigured: Bool {
        return config.isTdxConfigured
    }

    public var baseUrl: String {
        let raw = (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Auto-append /TDWebApi if the URL is just the hostname (no API path)
        if !raw.isEmpty && !raw.contains("/TDWebApi") && !raw.hasSuffix("/api") {
            return "\(raw)/TDWebApi"
        }
        return raw
    }
    
    /// Returns true if SSO authentication is active and valid
    public var isSsoAuthenticated: Bool {
        guard let token = ssoToken, !token.isEmpty else { return false }
        return Date() < ssoTokenExpiry
    }

    /// True when the held SSO token is a real API JWT rather than a marker for
    /// a scraped web session. Only a JWT can be sent as a Bearer credential.
    public var hasUserJwt: Bool {
        guard let token = ssoToken, Date() < ssoTokenExpiry else { return false }
        return token.hasPrefix("eyJ") && token.split(separator: ".").count == 3
    }

    /// True when SSO produced a signed-in web session instead of a JWT.
    ///
    /// Cookie auth is just as much the operator's own identity as a JWT is —
    /// the credential rides on `cookieSession` rather than an Authorization
    /// header, which is the only difference that matters here.
    public var hasUserCookieSession: Bool {
        guard let token = ssoToken, Date() < ssoTokenExpiry else { return false }
        return token == Self.cookieAuthMarker && cookieSession != nil
    }

    /// Who writes will be attributed to: the signed-in person, or the service
    /// account. Surfaced so the UI can say which, rather than implying one.
    public var actingIdentityIsUser: Bool { hasUserJwt || hasUserCookieSession }

    /// Stands in for a token when the session is carried by cookies.
    static let cookieAuthMarker = "cookie-auth"
    
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

    /// - Parameter sessionConfiguration: Overrides the default URLSession setup.
    ///   Tests pass a configuration carrying a stub `URLProtocol` so every call
    ///   below runs its real code path without reaching the network.
    public init(config: FleetMateConfig, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        let configuration = sessionConfiguration ?? {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 60
            return c
        }()
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

    /// Set SSO cookies for cookie-based auth (when JWT is unavailable)
    public func setSsoCookies(_ cookies: [HTTPCookie], userName: String? = nil) {
        self.ssoCookies = cookies
        self.ssoUserName = userName
        self.ssoTokenExpiry = Date().addingTimeInterval(23 * 60 * 60) // 23h
        self.ssoToken = "cookie-auth" // marker so SSO appears valid

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        for cookie in cookies {
            configuration.httpCookieStorage?.setCookie(cookie)
        }
        self.cookieSession = Session(configuration: configuration)
    }

    /// Clear SSO authentication state
    public func clearSsoToken() {
        self.ssoToken = nil
        self.ssoTokenExpiry = .distantPast
        self.ssoUserId = nil
        self.ssoUserName = nil
        self.ssoCookies = nil
        self.cookieSession = nil
    }

    // MARK: - Authentication

    private func getAccessToken() async throws -> String? {
        let authMethod = config.tdxAuthMethod
        dbg.debug("TDX getAccessToken (method=\(authMethod), ssoValid=\(ssoToken != nil && Date() < ssoTokenExpiry))", category: "tdx-auth")
        
        // Prefer the signed-in operator's own session whenever we hold one,
        // including under `.auto`. Writes are then attributed to the person who
        // made them instead of the API service account.
        //
        // This used to be browser-SSO-only, because the "SSO token" could be a
        // value scraped from a TDNext web session, and the API answers 400 to
        // that as a Bearer credential. So the two shapes worth having are
        // checked by name rather than by "is non-empty": a real JWT from
        // `/api/auth/loginsso`, and a cookie session. Anything else still falls
        // through. See the TDX auth-ceiling notes.
        if hasUserJwt {
            dbg.info("TDX using SSO user token (expires in \(Int(ssoTokenExpiry.timeIntervalSinceNow))s)", category: "tdx-auth")
            return ssoToken
        }

        // A cookie session is the operator too. Dropping through to the service
        // account here is what made an interactive sign-in appear to succeed
        // and then post every comment as "Inventory API Automations" anyway.
        if hasUserCookieSession {
            dbg.info("TDX using SSO cookie session (expires in \(Int(ssoTokenExpiry.timeIntervalSinceNow))s)", category: "tdx-auth")
            return ssoToken
        }

        if authMethod == .browserSSO {
            // Explicitly opted into acting as yourself — falling back to the
            // service account here would silently misattribute every write.
            if let token = ssoToken, !token.isEmpty, Date() < ssoTokenExpiry {
                dbg.info("TDX using SSO session token", category: "tdx-auth")
                return token
            }
            dbg.warn("TDX browserSSO required but no valid SSO token", category: "tdx-auth")
            return nil
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
            activeSession.request(url, method: .post, parameters: body, encoding: JSONEncoding.default)
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
        if token == "cookie-auth" {
            // Cookie-based auth — cookies are on the session, no Bearer needed
            return [
                "Content-Type": "application/json",
                "Accept": "application/json"
            ]
        }
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
    }

    /// The Alamofire session to use — cookie session when available, otherwise default
    private var activeSession: Session {
        cookieSession ?? session
    }

    // MARK: - Tickets

    public func searchTickets(search: TicketSearchRequest? = nil, maxResults: Int = 50) async throws -> [TdxTicket] {
        dbg.info("TDX searchTickets (maxResults=\(maxResults))", category: "tdx")
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        var request = search ?? TicketSearchRequest()
        request.maxResults = maxResults

        let url = config.tdxTicketsUrl("search")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
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
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        let url = config.tdxTicketsUrl("\(id)")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
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

    /// Create a ticket.
    ///
    /// TDX takes the notification choices as query parameters, not body fields —
    /// putting them in the payload silently sends nothing to anyone.
    public func createTicket(
        request: CreateTicketRequest,
        notifyRequestor: Bool = false,
        notifyResponsible: Bool = false,
        allowRequestorCreation: Bool = false
    ) async throws -> TdxTicket? {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

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

        let query = "?NotifyRequestor=\(notifyRequestor)"
            + "&NotifyResponsible=\(notifyResponsible)"
            + "&AllowRequestorCreation=\(allowRequestorCreation)"
        let url = config.tdxTicketsUrl() + query
        dbg.info("TDX createTicket → POST \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, method: .post, parameters: createRequest, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .responseDecodable(of: TdxTicket.self) { response in
                    switch response.result {
                    case .success(let ticket):
                        continuation.resume(returning: ticket)
                    case .failure(let error):
                        if let data = response.data {
                            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                            dbg.warn("TDX createTicket failed (\(response.response?.statusCode ?? 0)): \(body)", category: "tdx")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    /// Unwrap an optional that was boxed by `as Any`.
    ///
    /// Callers build the sparse update dictionary with `dict["X"] = someInt? as Any`,
    /// which stores `Optional<Int>.none` rather than dropping the key.
    /// `JSONSerialization` rejects that value outright, so a cleared field would
    /// throw before the request was ever sent. Clearing a field is legitimate —
    /// it becomes an explicit JSON null.
    private static func jsonValue(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first else { return NSNull() }
        return jsonValue(wrapped.value)
    }

    public func updateTicket(id: Int, updates: [String: Any], notifyNewResponsible: Bool = false) async throws -> TdxTicket? {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        var url = config.tdxTicketsUrl("\(id)")
        if notifyNewResponsible {
            url += "?notifyNewResponsible=true"
        }
        dbg.info("TDX PATCH updateTicket \(id) fields: \(updates.keys.sorted())", category: "tdx")

        // TDX's PATCH takes an RFC 6902 JsonPatchDocument — an *array* of
        // operations, not an object of field/value pairs. Posting the bare
        // dictionary is what produced:
        //   "patch must not be null. Errors: The JsonPatchDocument was
        //    malformed and could not be parsed."
        let operations: [[String: Any]] = updates
            .sorted { $0.key < $1.key }
            .map { ["op": "replace", "path": "/\($0.key)", "value": Self.jsonValue($0.value)] }

        var request = try URLRequest(url: url, method: .patch, headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: operations)

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(request)
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
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        var url = config.tdxTicketsUrl("\(id)")
        if notifyNewResponsible {
            url += "?notifyNewResponsible=true"
        }
        dbg.info("TDX updateTicket \(id) → POST \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
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

    /// A ticket's activity feed.
    ///
    /// - Parameter includeReplies: Fetch the bodies of threaded replies. The
    ///   feed collection reports `RepliesCount` but always sends `Replies: []`,
    ///   so without this pass no thread ever renders — only `GET /api/feed/{id}`
    ///   carries the replies themselves. Costs one extra request per threaded
    ///   entry, issued concurrently.
    public func getTicketFeed(ticketId: Int, includeReplies: Bool = true) async throws -> [TdxFeedEntry] {
        let feed = try await fetchFeed(ticketId: ticketId)
        guard includeReplies else { return feed }
        return await hydrateReplies(in: feed)
    }

    /// Replace entries that have unloaded replies with copies carrying them.
    private func hydrateReplies(in feed: [TdxFeedEntry]) async -> [TdxFeedEntry] {
        let pending = feed.filter { $0.hasUnloadedReplies }
        guard !pending.isEmpty else { return feed }
        dbg.debug("TDX hydrating replies for \(pending.count) feed entries", category: "tdx")

        let loaded: [Int: [TdxFeedEntry]] = await withTaskGroup(of: (Int, [TdxFeedEntry])?.self) { group in
            for entry in pending {
                guard let id = entry.id else { continue }
                group.addTask {
                    guard let full = try? await self.getFeedEntry(id: id) else { return nil }
                    return (id, full.replyList)
                }
            }
            var result: [Int: [TdxFeedEntry]] = [:]
            for await item in group {
                if let (id, replies) = item { result[id] = replies }
            }
            return result
        }

        return feed.map { entry in
            guard let id = entry.id, let replies = loaded[id], !replies.isEmpty else { return entry }
            return entry.withReplies(replies)
        }
    }

    private func fetchFeed(ticketId: Int) async throws -> [TdxFeedEntry] {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        let url = config.tdxTicketsUrl("\(ticketId)/feed")
        dbg.debug("TDX getTicketFeed → GET \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
                .validate()
                .responseData { dataResponse in
                    if let data = dataResponse.data {
                        do {
                            let feed = try JSONDecoder().decode([TdxFeedEntry].self, from: data)
                            dbg.debug("TDX feed decoded: \(feed.count) entries", category: "tdx")
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

    /// Post a top-level comment on a ticket, returning the created feed entry.
    ///
    /// Throws rather than reporting failure as a `false` return: a swallowed
    /// failure here looks exactly like a successful post that the feed hasn't
    /// caught up with yet.
    @discardableResult
    public func addComment(ticketId: Int, comment: String, isPrivate: Bool = false, isRichHtml: Bool = false, notify: [String]? = nil) async throws -> TdxFeedEntry? {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        let request = CreateFeedEntryRequest(
            comments: comment,
            isPrivate: isPrivate,
            isRichHtml: isRichHtml,
            notify: notify
        )

        let url = config.tdxTicketsUrl("\(ticketId)/feed")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, method: .post, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .responseDecodable(of: TdxFeedEntry.self) { response in
                    switch response.result {
                    case .success(let entry):
                        continuation.resume(returning: entry)
                    case .failure(let error):
                        if let data = response.data {
                            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                            dbg.warn("TDX addComment \(ticketId) failed (\(response.response?.statusCode ?? 0)): \(body)", category: "tdx")
                        }
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    // Posting a threaded reply is not possible through the TDX Web API, and no
    // method for it belongs here. Verified against the live API on 2026-07-28:
    //
    //   • OPTIONS /api/feed/{id} answers `Allow: GET,DELETE` — there is no
    //     POST route under a feed entry at all, under any suffix.
    //   • POST /api/{appId}/tickets/{id}/feed accepts ParentID,
    //     ParentFeedEntryID, ReplyToID, and ItemUpdateID without complaint and
    //     ignores every one of them: each returns 201 having created another
    //     top-level entry, with the named parent's RepliesCount still 0.
    //
    // Existing threads *are* readable — see `getTicketFeed(includeReplies:)`.
    // The UI offers quoting into a new comment instead.

    // MARK: - Attachments

    /// Download an attachment's bytes.
    ///
    /// Attachments are listed inline on the ticket; this fetches the content
    /// each one points at via its `ContentUri`.
    public func downloadAttachment(id: String) async throws -> Data? {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        let url = config.tdxGlobalUrl("attachments/\(id)/content")
        dbg.info("TDX downloadAttachment → GET \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
                .validate()
                .responseData { response in
                    switch response.result {
                    case .success(let data):
                        continuation.resume(returning: data)
                    case .failure(let error):
                        dbg.warn("TDX attachment \(id) failed (\(response.response?.statusCode ?? 0))", category: "tdx")
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    /// Download an attachment into a temporary file and return its path, ready
    /// to hand to Quick Look or the Finder.
    public func stageAttachment(_ attachment: TdxAttachment) async throws -> URL? {
        guard let data = try await downloadAttachment(id: attachment.id) else { return nil }

        // Keep the original filename so the right app opens it, but scope it to
        // a per-attachment directory so two files named image001.png don't
        // overwrite each other.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetMate-Attachments/\(attachment.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(attachment.displayName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Fetch a single feed entry with its replies.
    public func getFeedEntry(id: Int) async throws -> TdxFeedEntry? {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        let url = config.tdxGlobalUrl("feed/\(id)")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
                .validate()
                .responseDecodable(of: TdxFeedEntry.self) { response in
                    switch response.result {
                    case .success(let entry):
                        continuation.resume(returning: entry)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    // MARK: - People Search

    /// Search for people in TDX by name or email
    public func searchPeople(searchText: String, maxResults: Int = 10) async throws -> [TdxPerson] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }

        let encoded = searchText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchText
        let url = config.tdxPeopleUrl("lookup?searchText=\(encoded)&maxResults=\(maxResults)")
        dbg.debug("TDX searchPeople → GET \(url)", category: "tdx")

        return try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
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

    /// Find the TDX person record for an email address.
    ///
    /// This is how the app learns who "me" is. TDX's Web API has no inbound SSO
    /// path, so the session is always a service account and cannot report the
    /// human driving it — the signed-in Entra identity supplies the address and
    /// TDX maps it back to a UID.
    public func findPerson(email: String) async throws -> TdxPerson? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let matches = try await searchPeople(searchText: trimmed, maxResults: 10)
        return matches.first {
            ($0.primaryEmail ?? "").compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
    }

    // MARK: - Reference Data

    public func getStatuses() async throws -> [Int: String] {
        if !statusCache.isEmpty && Date() < refDataExpiry {
            return statusCache
        }

        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no statuses.
            if statusCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return statusCache
        }

        // Must be the ticketing app, not `tdxAppId` — that is the Assets app at
        // ECU, and asking it for ticket statuses is a 400.
        let url = config.tdxTicketsUrl("statuses")

        let statuses: [TdxStatusItem] = try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
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

        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no typees.
            if typeCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return typeCache
        }

        let url = config.tdxTicketsUrl("types")

        let types: [TdxTypeItem] = try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
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

        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no priorityes.
            if priorityCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return priorityCache
        }

        let url = config.tdxTicketsUrl("priorities")

        let priorities: [TdxPriorityItem] = try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
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

        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no formes.
            if formCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return formCache
        }

        let appId = config.tdxTicketingAppId ?? config.tdxAppId ?? 0
        let url = "\(baseUrl)/api/\(appId)/tickets/forms"

        let forms: [TdxFormItem] = try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
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

    /// Ticket sources ("Staff Created", "Client Portal", …).
    public func getSources() async throws -> [TdxLookupItem] {
        if !sourceCache.isEmpty && Date() < refDataExpiry { return sourceCache }
        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no sourcees.
            if sourceCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return sourceCache
        }

        let items: [TdxSourceItem] = try await get(config.tdxTicketsUrl("sources"), headers: headers)
        sourceCache = lookupItems(items.filter { $0.isActive != false }.map { ($0.id, $0.name) })
        return sourceCache
    }

    /// Accounts / departments — the ticket's Acct/Dept field.
    public func getAccounts() async throws -> [TdxLookupItem] {
        if !accountCache.isEmpty && Date() < refDataExpiry { return accountCache }
        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no accountes.
            if accountCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return accountCache
        }

        // Accounts is a search endpoint, not a list one; an empty filter with
        // IsActive returns the full active set.
        let body: [String: Any] = ["IsActive": true, "MaxResults": 1000]
        let items: [TdxAccountItem] = try await post(config.tdxGlobalUrl("accounts/search"), body: body, headers: headers)
        accountCache = lookupItems(items.map { ($0.id, $0.name) })
        return accountCache
    }

    /// Responsible groups.
    public func getGroups() async throws -> [TdxLookupItem] {
        if !groupCache.isEmpty && Date() < refDataExpiry { return groupCache }
        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no groupes.
            if groupCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return groupCache
        }

        let body: [String: Any] = ["IsActive": true, "MaxResults": 1000]
        let items: [TdxGroupItem] = try await post(config.tdxGlobalUrl("groups/search"), body: body, headers: headers)
        groupCache = lookupItems(items.map { ($0.id, $0.name) })
        return groupCache
    }

    /// Services, labelled by their full category path where TDX supplies one.
    public func getServices() async throws -> [TdxLookupItem] {
        if !serviceCache.isEmpty && Date() < refDataExpiry { return serviceCache }
        guard let headers = await headers() else {
            // Serve the last-known values when we have them, but an empty
            // cache means we never authenticated — that is a failure, not
            // a tenant with no servicees.
            if serviceCache.isEmpty { throw TdxAuthError.notAuthenticated }
            return serviceCache
        }

        let items: [TdxServiceItem] = try await get(config.tdxGlobalUrl("services"), headers: headers)
        serviceCache = lookupItems(items.filter { $0.isActive != false }
            .map { ($0.id, $0.compositeName ?? $0.name) })
        return serviceCache
    }

    /// Ticket types as picker items (the `getTypes` dictionary loses ordering).
    public func getTypeItems() async throws -> [TdxLookupItem] {
        guard let headers = await headers() else { throw TdxAuthError.notAuthenticated }
        let items: [TdxTypeItem] = try await get(config.tdxTicketsUrl("types"), headers: headers)
        return lookupItems(items.map { ($0.id, $0.name) })
    }

    private func lookupItems(_ pairs: [(Int, String?)]) -> [TdxLookupItem] {
        pairs.compactMap { id, name in
            guard let name, !name.isEmpty else { return nil }
            return TdxLookupItem(id: id, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Request Plumbing

    private func get<T: Decodable>(_ url: String, headers: HTTPHeaders) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, headers: headers)
                .validate()
                .responseDecodable(of: T.self) { response in
                    continuation.resume(with: response.result.mapError { $0 as Error })
                }
        }
    }

    private func post<T: Decodable>(_ url: String, body: [String: Any], headers: HTTPHeaders) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            activeSession.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseDecodable(of: T.self) { response in
                    continuation.resume(with: response.result.mapError { $0 as Error })
                }
        }
    }
}
