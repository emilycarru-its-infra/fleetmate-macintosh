import Foundation

// MARK: - Models

/// One hit from `GET /v1/teams/search`: a thread whose root or replies matched.
public struct TeamsSearchHit: Codable, Sendable, Equatable {
    public var threadId: String
    public var teamId: String
    public var teamName: String
    public var channelId: String
    public var channelName: String
    public var subject: String?
    public var snippet: String
    public var authorDisplayName: String?
    public var createdAt: String
    public var lastActivityAt: String
    public var replyCount: Int
    public var participants: [String]
    public var score: Double
    public var webUrl: String?
}

public struct TeamsSearchResponse: Codable, Sendable, Equatable {
    public var query: String
    public var asOf: String?
    public var total: Int
    public var results: [TeamsSearchHit]
}

public struct TeamsBrowseResponse: Codable, Sendable, Equatable {
    public var asOf: String?
    public var indexVersion: String
    public var total: Int
    public var results: [TeamsSearchHit]
    public var nextOffset: Int?
}

public struct TeamsAttachment: Codable, Sendable, Equatable {
    public var name: String
    public var url: String?
}

public struct TeamsMessage: Codable, Sendable, Equatable {
    public var messageId: String
    public var replyToId: String?
    public var authorDisplayName: String?
    public var createdAt: String
    public var editedAt: String?
    public var text: String
    public var attachments: [TeamsAttachment]
    public var webUrl: String?
}

/// `GET /v1/teams/threads/{id}`: the root message and its replies, oldest first.
public struct TeamsThread: Codable, Sendable, Equatable {
    public var threadId: String
    public var teamId: String
    public var teamName: String
    public var channelId: String
    public var channelName: String
    public var subject: String?
    public var webUrl: String?
    public var messages: [TeamsMessage]
}

public struct TeamsChannel: Codable, Sendable, Equatable {
    public var teamId: String
    public var teamName: String
    public var channelId: String
    public var channelName: String
    public var membershipType: String
    public var threads: Int
    public var lastActivityAt: String?
}

public struct TeamsChannelsResponse: Codable, Sendable, Equatable {
    public var asOf: String?
    public var channels: [TeamsChannel]
}

/// A decoded response together with the exact bytes the API returned, so
/// `--json` can pass the API's own JSON through unchanged.
public struct TeamsPayload<Value: Sendable>: Sendable {
    public let value: Value
    public let raw: Data
}

/// The filters `fleetmate teams search` passes to the API.
public struct TeamsSearchQuery: Sendable, Equatable {
    public var text: String
    public var team: String?
    public var channel: String?
    public var author: String?
    /// `YYYY-MM-DD`, inclusive.
    public var since: String?
    /// `YYYY-MM-DD`, inclusive.
    public var until: String?
    /// 1–100; nil leaves the API's default (20).
    public var limit: Int?

    public init(text: String, team: String? = nil, channel: String? = nil, author: String? = nil,
                since: String? = nil, until: String? = nil, limit: Int? = nil) {
        self.text = text
        self.team = team
        self.channel = channel
        self.author = author
        self.since = since
        self.until = until
        self.limit = limit
    }
}

// MARK: - Errors

public enum TeamsSearchError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notConfigured
    case invalidArgument(String)
    /// 401 — the token was missing, expired or rejected.
    case unauthorized
    /// 403 — signed in, but the account lacks the API's Teams search role.
    case forbidden
    /// 403 `purpose_not_granted` — the declared purpose is not one the API grants.
    case purposeNotGranted
    /// 404 — no such thread (or channel).
    case notFound
    /// 503 — the search index has not been built yet.
    case indexNotReady
    case membershipUnavailable
    case accountChanged
    case http(Int, String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "Teams search is not configured. Set teams_api_url and teams_api_scope in config.yaml or the configuration profile."
        case .invalidArgument(let message):
            return message
        case .unauthorized:
            return "The Teams search API rejected the sign-in token. Run `fleetmate login` and try again."
        case .forbidden:
            return "Your account is not authorized for Teams search. Ask your IT administrator for Teams search access."
        case .purposeNotGranted:
            return "The Teams search API does not grant the configured purpose. Check teams_api_purpose."
        case .notFound:
            return "No such Teams thread or channel in the search index."
        case .accountChanged:
            return "Your Azure sign-in changed. Refresh authentication before opening Teams."
        case .membershipUnavailable:
            return "Your Teams channel access could not be verified. Reload channels to try again."
        case .indexNotReady:
            return "The Teams search index is not ready yet. Try again later."
        case .http(let status, let detail):
            return "Teams search API returned HTTP \(status)" + (detail.isEmpty ? "." : ": \(detail)")
        case .invalidResponse(let message):
            return "Teams search API returned an unexpected response: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Service

/// Client for the Teams channel-message search API.
///
/// Every call carries a bearer token minted for the configured scope off the
/// operator's own `az` sign-in (`AzTokenSource`), so the API authorizes the
/// person, not FleetMate; no secret is stored. Base URL and scope come from
/// configuration and are empty by default.
public final class TeamsSearchService: Sendable {
    /// Returns a token for `scope`; `refresh` asks for a fresh one after a 401.
    public typealias TokenProvider = @Sendable (_ scope: String, _ refresh: Bool) async throws -> String

    private let baseUrl: String
    private let scope: String
    private let purpose: String
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let expectedAccount: CliAccount?
    private let accountIdentity = TeamsAccountIdentity()

    public var isConfigured: Bool { !baseUrl.isEmpty && !scope.isEmpty }

    /// Sent as `X-Vantage-Purpose` on every request unless configured otherwise.
    public static let defaultPurpose = "purpose.its_teams_channel_search"
    public static let purposeHeader = "X-Vantage-Purpose"

    public init(baseUrl: String?, scope: String?, purpose: String? = nil,
                sessionConfiguration: URLSessionConfiguration? = nil,
                tokenProvider: TokenProvider? = nil, expectedAccount: CliAccount? = nil) {
        var base = (baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        self.baseUrl = base
        self.scope = (scope ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.expectedAccount = expectedAccount
        let p = (purpose ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.purpose = p.isEmpty ? Self.defaultPurpose : p
        let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration, delegate: TeamsNoRedirectDelegate(), delegateQueue: nil)
        let tokens = AzTokenSource()
        self.tokenProvider = tokenProvider ?? { scope, refresh in
            if refresh { await tokens.invalidate() }
            return try await tokens.token(forScope: scope)
        }
    }

    public convenience init(config: FleetMateConfig, expectedAccount: CliAccount? = nil) {
        self.init(baseUrl: config.teamsApiUrl, scope: config.teamsApiScope, purpose: config.teamsApiPurpose,
                  expectedAccount: expectedAccount)
    }

    // MARK: Requests

    public func search(_ query: TeamsSearchQuery) async throws -> TeamsPayload<TeamsSearchResponse> {
        try await get(searchURL(query))
    }

    public func browse(team: String? = nil, channel: String? = nil, author: String? = nil,
                       since: String? = nil, until: String? = nil, limit: Int = 20,
                       offset: Int = 0) async throws -> TeamsPayload<TeamsBrowseResponse> {
        try await get(browseURL(team: team, channel: channel, author: author,
                                since: since, until: until, limit: limit, offset: offset))
    }

    public func followedFeed(channels: [String], query: String? = nil, author: String? = nil,
                             since: String? = nil, until: String? = nil, limit: Int = 20,
                             offset: Int = 0) async throws -> TeamsPayload<TeamsBrowseResponse> {
        guard (1...500).contains(channels.count), channels.allSatisfy({
            let id = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && id.count <= 500
        }) else { throw TeamsSearchError.invalidArgument("Choose between 1 and 500 channels to follow.") }
        _ = try browseURL(channel: channels[0], since: since, until: until, limit: limit, offset: offset)
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.count <= 500 else { throw TeamsSearchError.invalidArgument("Search text must be at most 500 characters.") }
        var body: [String: Any] = ["channels": Array(Set(channels)).sorted(), "limit": limit, "offset": offset]
        for (key, value) in [("q", text), ("author", author ?? ""), ("since", since ?? ""), ("until", until ?? "")] {
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body[key] = value }
        }
        return try await get(url("/v1/teams/feed", query: []), body: JSONSerialization.data(withJSONObject: body))
    }

    /// Claims select a private local bookmark file; the API still authorizes every content read.
    public func bookmarkAccountKey() async throws -> String {
        guard isConfigured else { throw TeamsSearchError.notConfigured }
        let token = try await tokenProvider(scope, false)
        try await checkAccount(token)
        guard let key = TeamsBookmarkScope.key(endpoint: baseUrl, token: token) else {
            throw TeamsSearchError.invalidArgument("Saved threads need an identifiable signed-in account.")
        }
        return key
    }

    public func browseURL(team: String? = nil, channel: String? = nil, author: String? = nil,
                          since: String? = nil, until: String? = nil, limit: Int = 20,
                          offset: Int = 0) throws -> URL {
        let team = team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let channel = channel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !team.isEmpty || !channel.isEmpty else {
            throw TeamsSearchError.invalidArgument("Choose a team or channel to browse.")
        }
        guard (1...100).contains(limit), (0...2_147_483_647).contains(offset) else {
            throw TeamsSearchError.invalidArgument("Invalid browse page size or offset.")
        }
        for date in [since, until].compactMap({ $0 }) where !Self.isDay(date) {
            throw TeamsSearchError.invalidArgument("Browse dates must use YYYY-MM-DD.")
        }
        if let since, let until, since > until {
            throw TeamsSearchError.invalidArgument("The start date must precede the end date.")
        }
        var items: [(String, String)] = []
        for (key, value) in [("team", team), ("channel", channel), ("author", author ?? ""),
                             ("since", since ?? ""), ("until", until ?? "")] {
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append((key, value)) }
        }
        items += [("limit", String(limit)), ("offset", String(offset))]
        return try url("/v1/teams/threads", query: items)
    }

    public func thread(id: String, channel: String) async throws -> TeamsPayload<TeamsThread> {
        try await get(threadURL(id: id, channel: channel))
    }

    public func channels() async throws -> TeamsPayload<TeamsChannelsResponse> {
        try await get(channelsURL())
    }

    // MARK: URL building

    public func searchURL(_ query: TeamsSearchQuery) throws -> URL {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TeamsSearchError.invalidArgument("A search query is required.") }
        if let limit = query.limit, !(1...100).contains(limit) {
            throw TeamsSearchError.invalidArgument("--limit must be between 1 and 100.")
        }
        for (flag, value) in [("--since", query.since), ("--until", query.until)] {
            if let value, !Self.isDay(value) {
                throw TeamsSearchError.invalidArgument("\(flag) must be a date in YYYY-MM-DD form.")
            }
        }
        var items: [(String, String)] = [("q", text)]
        func add(_ name: String, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { items.append((name, v)) }
        }
        add("team", query.team)
        add("channel", query.channel)
        add("author", query.author)
        add("since", query.since)
        add("until", query.until)
        if let limit = query.limit { items.append(("limit", String(limit))) }
        return try url("/v1/teams/search", query: items)
    }

    public func threadURL(id: String, channel: String) throws -> URL {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw TeamsSearchError.invalidArgument("A thread id is required.") }
        guard !channel.isEmpty else { throw TeamsSearchError.invalidArgument("--channel is required.") }
        return try url("/v1/teams/threads/" + Self.encode(id), query: [("channel", channel)])
    }

    public func channelsURL() throws -> URL {
        try url("/v1/teams/channels", query: [])
    }

    private func url(_ path: String, query: [(String, String)]) throws -> URL {
        guard isConfigured else { throw TeamsSearchError.notConfigured }
        var string = baseUrl + path
        if !query.isEmpty {
            string += "?" + query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw TeamsSearchError.invalidArgument("teams_api_url must be an HTTPS URL without embedded credentials.")
        }
        return url
    }

    /// RFC 3986 unreserved characters only, so `+`, `&`, `/` and `#` in a
    /// query or id reach the API as themselves.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func isDay(_ value: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return value.count == 10 && f.date(from: value) != nil
    }

    // MARK: Transport

    private func get<Value: Decodable & Sendable>(_ url: URL, body: Data? = nil) async throws -> TeamsPayload<Value> {
        var (data, status) = try await send(url, refresh: false, body: body)
        if status == 401 {
            (data, status) = try await send(url, refresh: true, body: body)
        }
        switch status {
        case 200..<300:
            do {
                return TeamsPayload(value: try Self.decoder.decode(Value.self, from: data), raw: data)
            } catch {
                throw TeamsSearchError.invalidResponse(String(describing: error))
            }
        case 401: throw TeamsSearchError.unauthorized
        case 403: throw Self.detail(from: data).contains("purpose_not_granted") ? TeamsSearchError.purposeNotGranted : TeamsSearchError.forbidden
        case 404: throw TeamsSearchError.notFound
        case 503: throw Self.detail(from: data).contains("teams_membership") ? TeamsSearchError.membershipUnavailable : TeamsSearchError.indexNotReady
        default: throw TeamsSearchError.http(status, Self.detail(from: data))
        }
    }

    private func send(_ url: URL, refresh: Bool, body: Data? = nil) async throws -> (Data, Int) {
        let token = try await tokenProvider(scope, refresh)
        try await checkAccount(token)
        let membershipToken = try await tokenProvider("https://graph.microsoft.com/.default", refresh)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(purpose, forHTTPHeaderField: Self.purposeHeader)
        request.setValue(membershipToken, forHTTPHeaderField: "X-Vantage-Teams-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TeamsSearchError.invalidResponse("not an HTTP response")
        }
        if (200..<300).contains(http.statusCode),
           http.value(forHTTPHeaderField: "X-Vantage-Teams-Access") != "membership-v1" {
            throw TeamsSearchError.membershipUnavailable
        }
        return (data, http.statusCode)
    }

    private func checkAccount(_ token: String) async throws {
        guard let expectedAccount else { return }
        guard TeamsBookmarkScope.matches(expectedAccount, token: token),
              let identity = TeamsBookmarkScope.key(endpoint: baseUrl, token: token) else {
            throw TeamsSearchError.accountChanged
        }
        try await accountIdentity.bind(identity)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// FastAPI's `{"detail": "..."}`, else the body's first line, kept short
    /// and stripped of control characters because it is server-supplied text.
    static func detail(from data: Data) -> String {
        var text = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = object["detail"] as? String {
            text = detail
        } else {
            text = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        return String(TeamsText.terminalSafe(text).prefix(300))
    }
}

// MARK: - Display helpers

/// Message text, subjects and names come from other people's Teams posts:
/// untrusted data. These helpers make them safe to print in a terminal and
/// render the API's timestamps in local time.
public enum TeamsText {
    /// Drops control characters (ANSI escapes, carriage returns, bidi
    /// overrides) a message could use to rewrite the terminal, keeping
    /// newlines and tabs.
    public static func terminalSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }))
    }

    /// One line, whitespace collapsed, safe for a table cell.
    public static func oneLine(_ text: String) -> String {
        terminalSafe(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Parses the API's ISO 8601 timestamps, with or without fractional seconds.
    public static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: value) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: value) { return d }
        // A timestamp with no zone is taken as UTC.
        return plain.date(from: value + "Z")
    }

    /// `yyyy-MM-dd HH:mm` in `timeZone` (local by default); the raw value if it
    /// does not parse.
    public static func localTime(_ value: String?, timeZone: TimeZone = .current) -> String {
        guard let value, !value.isEmpty else { return "-" }
        guard let date = date(value) else { return terminalSafe(value) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// Authenticated Teams reads never forward either credential through redirects.
private final class TeamsNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private actor TeamsAccountIdentity {
    private var identity: String?

    func bind(_ value: String) throws {
        if let identity, identity != value { throw TeamsSearchError.accountChanged }
        identity = value
    }
}
