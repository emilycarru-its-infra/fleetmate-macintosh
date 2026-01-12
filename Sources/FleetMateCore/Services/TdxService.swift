import Foundation
import Alamofire

/// TeamDynamix (TDX) service for ticket management
/// Uses JWT authentication via username/password or BEID
class TdxService {
    private let config: FleetMateConfig
    private let session: Session
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    // Reference data caches
    private var statusCache: [Int: String] = [:]
    private var typeCache: [Int: String] = [:]
    private var priorityCache: [Int: String] = [:]
    private var refDataExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval

    var isConfigured: Bool {
        return config.isTdxConfigured
    }

    var baseUrl: String {
        (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = Session(configuration: configuration)
    }

    // MARK: - Authentication

    private func getAccessToken() async throws -> String? {
        if let token = cachedToken, Date() < tokenExpiry {
            return token
        }

        // Try admin login first (BEID + WebServicesKey)
        if let beid = config.tdxBeid, let webServicesKey = config.tdxWebServicesKey,
           !beid.isEmpty, !webServicesKey.isEmpty {
            let loginUrl = "\(baseUrl)/api/auth/loginadmin"
            let body: [String: String] = [
                "BEID": beid,
                "WebServicesKey": webServicesKey
            ]

            if let token = try? await authenticate(url: loginUrl, body: body) {
                cachedToken = token
                tokenExpiry = Date().addingTimeInterval(23 * 60 * 60) // 23 hours
                return token
            }
        }

        // Fallback to regular login
        guard let username = config.tdxUsername, let password = config.tdxPassword,
              !username.isEmpty, !password.isEmpty else {
            print("TDX credentials not configured.")
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

    func searchTickets(search: TicketSearchRequest? = nil, maxResults: Int = 50) async throws -> [TdxTicket] {
        guard let headers = await headers() else { return [] }

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
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    func getTicket(id: Int) async throws -> TdxTicket? {
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

    func createTicket(request: CreateTicketRequest) async throws -> TdxTicket? {
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

    func updateTicket(id: Int, updates: [String: Any]) async throws -> TdxTicket? {
        guard let headers = await headers() else { return nil }

        let url = config.tdxTicketsUrl("\(id)")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .patch, parameters: updates, encoding: JSONEncoding.default, headers: headers)
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

    // MARK: - Feed (Comments)

    func getTicketFeed(ticketId: Int) async throws -> [TdxFeedEntry] {
        guard let headers = await headers() else { return [] }

        let url = config.tdxTicketsUrl("\(ticketId)/feed")

        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
                .validate()
                .responseDecodable(of: [TdxFeedEntry].self) { response in
                    switch response.result {
                    case .success(let feed):
                        continuation.resume(returning: feed)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    func addComment(ticketId: Int, comment: String, isPrivate: Bool = false, notify: [String]? = nil) async throws -> Bool {
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

    // MARK: - Reference Data

    func getStatuses() async throws -> [Int: String] {
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

    func getTypes() async throws -> [Int: String] {
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

    func getPriorities() async throws -> [Int: String] {
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
}
