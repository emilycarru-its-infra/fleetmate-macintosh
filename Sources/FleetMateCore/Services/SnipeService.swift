import Foundation
import Alamofire

/// Client for Snipe-IT Asset Management API
/// https://snipe-it.readme.io/reference/api-overview
class SnipeService {
    let baseUrl: String
    let apiKey: String
    
    private let session: Session
    private var assetCache: [SnipeAsset]?
    private var assetCacheExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval
    
    var isConfigured: Bool {
        return !baseUrl.isEmpty && !apiKey.isEmpty
    }
    
    init(baseUrl: String?, apiKey: String?, cacheMinutes: Int = 5) {
        self.baseUrl = (baseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey ?? ""
        self.cacheDuration = TimeInterval(cacheMinutes * 60)
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        
        self.session = Session(configuration: configuration)
    }
    
    private var headers: HTTPHeaders {
        [
            "Authorization": "Bearer \(apiKey)",
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
    }
    
    // MARK: - Assets
    
    func getAssets(search: String? = nil, statusId: Int? = nil, locationId: Int? = nil) async throws -> [SnipeAsset] {
        var parameters: [String: Any] = ["limit": 500]
        if let search = search { parameters["search"] = search }
        if let statusId = statusId { parameters["status_id"] = statusId }
        if let locationId = locationId { parameters["location_id"] = locationId }
        
        return try await fetchList("/api/v1/hardware", parameters: parameters)
    }
    
    func getAsset(id: Int) async throws -> SnipeAsset? {
        return try await fetch("/api/v1/hardware/\(id)")
    }
    
    func getAssetByTag(_ tag: String) async throws -> SnipeAsset? {
        let assets: [SnipeAsset] = try await fetchList("/api/v1/hardware", parameters: ["search": tag])
        return assets.first { $0.assetTag == tag }
    }
    
    func getAssetBySerial(_ serial: String) async throws -> SnipeAsset? {
        return try await fetch("/api/v1/hardware/byserial/\(serial)")
    }
    
    // MARK: - Users
    
    func getUsers(search: String? = nil) async throws -> [SnipeUser] {
        var parameters: [String: Any] = ["limit": 500]
        if let search = search { parameters["search"] = search }
        return try await fetchList("/api/v1/users", parameters: parameters)
    }
    
    func getUser(id: Int) async throws -> SnipeUser? {
        return try await fetch("/api/v1/users/\(id)")
    }
    
    // MARK: - Locations
    
    func getLocations() async throws -> [SnipeLocation] {
        return try await fetchList("/api/v1/locations", parameters: ["limit": 500])
    }
    
    // MARK: - Models
    
    func getModels() async throws -> [SnipeModel] {
        return try await fetchList("/api/v1/models", parameters: ["limit": 500])
    }
    
    // MARK: - Categories
    
    func getCategories() async throws -> [SnipeCategory] {
        return try await fetchList("/api/v1/categories", parameters: ["limit": 500])
    }
    
    // MARK: - Status Labels
    
    func getStatusLabels() async throws -> [SnipeStatusLabel] {
        return try await fetchList("/api/v1/statuslabels", parameters: ["limit": 500])
    }
    
    // MARK: - Asset Operations
    
    func checkoutAsset(assetId: Int, request: SnipeCheckoutRequest) async throws -> SnipeResponse {
        return try await post("/api/v1/hardware/\(assetId)/checkout", body: request)
    }
    
    func checkinAsset(assetId: Int, request: SnipeCheckinRequest? = nil) async throws -> SnipeResponse {
        return try await post("/api/v1/hardware/\(assetId)/checkin", body: request ?? SnipeCheckinRequest())
    }
    
    func auditAsset(assetId: Int, request: SnipeAuditRequest? = nil) async throws -> SnipeResponse {
        return try await post("/api/v1/hardware/\(assetId)/audit", body: request ?? SnipeAuditRequest())
    }
    
    // MARK: - Private Helpers
    
    private func fetch<T: Decodable>(_ path: String) async throws -> T? {
        let url = "\(baseUrl)\(path)"
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, headers: headers)
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
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, parameters: parameters, headers: headers)
                .validate()
                .responseDecodable(of: SnipeListResponse<T>.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value.rows)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    private func post<T: Encodable, R: Decodable>(_ path: String, body: T) async throws -> R {
        let url = "\(baseUrl)\(path)"
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(url, method: .post, parameters: body, encoder: JSONParameterEncoder.default, headers: headers)
                .validate()
                .responseDecodable(of: R.self) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
}
