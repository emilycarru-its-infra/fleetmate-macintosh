import Foundation

/// The inventory system FleetMate's inventory operations run against.
///
/// Snipe-IT (the fork) is the system of record until Cellarum replaces it.
/// Switching is one setting, `inventory_backend`; the operation names the CLI
/// and agents use stay the same on either side.
public enum InventoryBackend: String, CaseIterable, Sendable {
    case snipe
    case cellarum

    public var displayName: String {
        switch self {
        case .snipe: return "Snipe-IT"
        case .cellarum: return "Cellarum"
        }
    }

    /// The configured backend; Snipe-IT when nothing is set.
    public static func configured(_ config: FleetMateConfig) throws -> InventoryBackend {
        let raw = (config.inventoryBackend ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty || raw == "snipe-it" || raw == "snipeit" { return .snipe }
        guard let backend = InventoryBackend(rawValue: raw) else {
            throw InventoryApiError.unknownBackend(raw)
        }
        return backend
    }
}

public enum InventoryApiError: LocalizedError {
    case unknownBackend(String)
    case notConfigured(InventoryBackend, String)
    case invalidPath(String)
    case http(status: Int, body: String)
    case rejected(body: String)

    public var errorDescription: String? {
        switch self {
        case .unknownBackend(let name):
            return "Unknown inventory_backend '\(name)'. Use snipe or cellarum."
        case .notConfigured(let backend, let detail):
            return "\(backend.displayName) is not configured: \(detail)"
        case .invalidPath(let path):
            return "Not a relative API path: \(path)"
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(2000))"
        case .rejected(let body):
            return "The request was refused: \(body.prefix(2000))"
        }
    }
}

/// Raw, authenticated access to the active inventory backend's REST API.
///
/// Snipe-IT authenticates with an Entra bearer token for `snipe_oidc_audience`
/// or the API key; Cellarum with a bearer token for `cellarum_oidc_audience`
/// or a scoped key sent as X-API-Key.
public final class InventoryApi: @unchecked Sendable {
    public let backend: InventoryBackend
    public let root: String
    private let audience: String?
    private let apiKey: String?
    private let session: URLSession

    public init(config: FleetMateConfig, backend: InventoryBackend? = nil) throws {
        let selected = try backend ?? InventoryBackend.configured(config)
        self.backend = selected
        let base: String?
        switch selected {
        case .snipe:
            base = config.snipeUrl
            audience = config.snipeOidcAudience
            apiKey = config.snipeApiKey
        case .cellarum:
            base = config.cellarumUrl
            audience = config.cellarumOidcAudience
            apiKey = config.cellarumApiKey
        }
        guard var url = base?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            throw InventoryApiError.notConfigured(selected, "set \(selected == .snipe ? "snipe_url" : "cellarum_url").")
        }
        while url.hasSuffix("/") { url.removeLast() }
        if !url.hasSuffix("/api/v1") { url += "/api/v1" }
        root = url
        guard (audience ?? "").isEmpty == false || (apiKey ?? "").isEmpty == false else {
            let prefix = selected == .snipe ? "snipe" : "cellarum"
            throw InventoryApiError.notConfigured(selected, "set \(prefix)_oidc_audience or \(prefix)_api_key.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// Redirects are not followed: a redirect to another host would carry the
    /// API key or bearer with it. An inventory API never needs one.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public struct Response: Sendable {
        public let status: Int
        public let data: Data
        public let contentType: String?
    }

    /// Send one request. `path` is relative to the API root and may carry a
    /// query string. A non-2xx answer throws; so does Snipe-IT's 200 answer
    /// whose body says `"status": "error"`, which is how it reports refusals.
    public func send(
        _ method: String, path: String, query: [URLQueryItem] = [],
        body: Data? = nil, contentType: String = "application/json"
    ) async throws -> Response {
        guard !path.hasPrefix("/"), !path.contains("://"), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw InventoryApiError.invalidPath(path)
        }
        guard var components = URLComponents(string: "\(root)/\(path)") else {
            throw InventoryApiError.invalidPath(path)
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw InventoryApiError.invalidPath(path) }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let audience, !audience.isEmpty {
            let token = try await AzTokenSource.shared.token(forResource: audience)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let apiKey {
            switch backend {
            case .snipe: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .cellarum: request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw InventoryApiError.http(status: status, body: text)
        }
        if backend == .snipe,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["status"] as? String) == "error" {
            throw InventoryApiError.rejected(body: text)
        }
        return Response(status: status, data: data, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Attach a file to a record. Snipe-IT takes a multipart upload on the
    /// record; Cellarum takes base64 bytes on /attachments and needs the
    /// holding domain.
    public func upload(
        file: URL, snipeRecord: String, cellarumRecord: String, id: String,
        notes: String?, domain: String?
    ) async throws -> Response {
        let bytes = try Data(contentsOf: file)
        let name = file.lastPathComponent
        let mediaType = Self.mediaType(for: file.pathExtension)
        switch backend {
        case .snipe:
            let boundary = "FleetMate-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            if let notes { field("notes", notes) }
            let safeName = name.replacingOccurrences(of: "\"", with: "")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file[]\"; filename=\"\(safeName)\"\r\nContent-Type: \(mediaType)\r\n\r\n".utf8))
            body.append(bytes)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            return try await send("POST", path: "\(snipeRecord)/\(Self.escape(id))/files",
                                  body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        case .cellarum:
            var fields: [String: Any] = [
                "record_kind": cellarumRecord, "record_id": id, "filename": name,
                "media_type": mediaType, "content_base64": bytes.base64EncodedString(),
            ]
            if let domain { fields["domain_id"] = domain }
            if let notes { fields["notes"] = notes }
            return try await send("POST", path: "attachments", body: try JSONSerialization.data(withJSONObject: fields))
        }
    }

    public static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    static func mediaType(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "txt", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
