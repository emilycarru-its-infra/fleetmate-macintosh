import Foundation
import Crypto
import Security

// MARK: - DevOps SSO Result

/// Result of a DevOps SSO authentication attempt
public struct DevOpsSsoResult: Sendable, Equatable {
    public let success: Bool
    public let accessToken: String?
    public let refreshToken: String?
    public let expiresIn: Int?
    public let userName: String?
    public let userEmail: String?
    public let error: String?

    public static func success(accessToken: String, refreshToken: String? = nil, expiresIn: Int? = nil, userName: String? = nil, userEmail: String? = nil) -> DevOpsSsoResult {
        DevOpsSsoResult(success: true, accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn, userName: userName, userEmail: userEmail, error: nil)
    }

    public static func failure(_ error: String) -> DevOpsSsoResult {
        DevOpsSsoResult(success: false, accessToken: nil, refreshToken: nil, expiresIn: nil, userName: nil, userEmail: nil, error: error)
    }
}

// MARK: - DevOps SSO Service

/// OAuth2 Authorization Code + PKCE token service for Azure DevOps.
/// Uses Azure CLI's first-party client ID (pre-approved in all Entra tenants — no app registration needed).
/// Handles PKCE generation, authorize URL construction, token exchange, refresh, and Keychain persistence.
public class DevOpsSsoService {

    /// Azure CLI first-party client ID — pre-approved in all Entra tenants
    public static let clientId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

    /// Azure DevOps resource ID
    public static let devOpsResource = "499b84ac-1321-427f-aa17-267ca6975798"

    /// OAuth2 redirect URI (Azure CLI native client)
    public static let redirectUri = "https://login.microsoftonline.com/common/oauth2/nativeclient"

    /// OAuth2 scope for Azure DevOps + offline_access for refresh tokens
    public static let scope = "499b84ac-1321-427f-aa17-267ca6975798/.default offline_access"

    // OAuth2 endpoints
    private let authorizeUrl: String
    private let tokenUrl: String

    // PKCE state for the current auth flow
    private var codeVerifier: String?

    // Token state
    public private(set) var accessToken: String?
    public private(set) var refreshToken: String?
    public private(set) var tokenExpiry: Date = .distantPast
    public private(set) var userName: String?
    public private(set) var userEmail: String?

    // Keychain
    private let keychainService = "ca.ecuad.macadmin.fleetmate.devops-sso"
    private let keychainRefreshKey = "refresh_token"

    /// True if we have a non-expired access token (with 5-minute buffer)
    public var isAuthenticated: Bool {
        guard let token = accessToken, !token.isEmpty else { return false }
        return Date().addingTimeInterval(5 * 60) < tokenExpiry
    }

    /// True if a refresh token is available (possibly from Keychain)
    public var hasRefreshToken: Bool {
        refreshToken != nil && !refreshToken!.isEmpty
    }

    public init(tenantId: String? = nil) {
        let tenant = tenantId ?? "organizations"
        self.authorizeUrl = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize"
        self.tokenUrl = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token"

        // Load persisted refresh token from Keychain
        self.refreshToken = loadFromKeychain(key: keychainRefreshKey)
        if refreshToken != nil {
            dbg.info("[DevOps SSO] Loaded refresh token from Keychain", category: "devops-sso")
        }
    }

    // MARK: - PKCE + Authorize URL

    /// Build an OAuth2 authorize URL with PKCE code challenge.
    /// Generates a fresh code verifier each call. The verifier is stored internally
    /// and used later in `exchangeCode(_:)`.
    /// - Parameters:
    ///   - loginHint: Pre-fill the username field (e.g., Platform SSO UPN)
    ///   - state: Optional state parameter for CSRF protection
    /// - Returns: The authorize URL to load in a WKWebView
    public func buildAuthorizeUrl(loginHint: String? = nil, state: String? = nil) -> URL? {
        // Generate code verifier (32 random bytes → base64url = ~43 chars)
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URLEncode(Data(bytes))
        self.codeVerifier = verifier

        // Code challenge = base64url(SHA256(verifier))
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(hash))

        var components = URLComponents(string: authorizeUrl)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectUri),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let hint = loginHint, !hint.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: hint))
        }
        if let state = state {
            components.queryItems?.append(URLQueryItem(name: "state", value: state))
        }

        return components.url
    }

    /// Check if a URL is the OAuth2 redirect URI (indicating auth flow completion)
    public static func isRedirectUri(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix(redirectUri)
    }

    /// Extract the authorization code from a redirect URL
    public static func extractCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
    }

    /// Extract an error from a redirect URL (e.g., interaction_required)
    public static func extractError(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let error = components?.queryItems?.first(where: { $0.name == "error" })?.value else {
            return nil
        }
        let description = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
        return description ?? error
    }

    // MARK: - Token Exchange

    /// Exchange an authorization code for access + refresh tokens
    public func exchangeCode(_ code: String) async throws -> DevOpsSsoResult {
        guard let verifier = codeVerifier else {
            return .failure("No PKCE code verifier — call buildAuthorizeUrl first")
        }

        let body = [
            "client_id": Self.clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectUri,
            "code_verifier": verifier,
            "scope": Self.scope,
        ]

        let result = try await postTokenRequest(body)
        codeVerifier = nil // consumed
        return result
    }

    /// Refresh the access token using the stored refresh token
    public func refreshAccessToken() async throws -> DevOpsSsoResult {
        guard let refresh = refreshToken, !refresh.isEmpty else {
            return .failure("No refresh token available")
        }

        dbg.info("[DevOps SSO] Attempting token refresh...", category: "devops-sso")

        let body = [
            "client_id": Self.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": Self.scope,
        ]

        let result = try await postTokenRequest(body)

        if !result.success {
            // Refresh token may be expired — clear it
            dbg.warn("[DevOps SSO] Refresh failed — clearing stored token", category: "devops-sso")
            self.refreshToken = nil
            deleteFromKeychain(key: keychainRefreshKey)
        }

        return result
    }

    /// Set tokens from an external source
    public func setTokens(accessToken: String, refreshToken: String? = nil, expiresIn: Int = 3600, userName: String? = nil, userEmail: String? = nil) {
        self.accessToken = accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        self.userName = userName
        self.userEmail = userEmail
        if let refresh = refreshToken {
            self.refreshToken = refresh
            saveToKeychain(key: keychainRefreshKey, value: refresh)
        }
    }

    /// Clear all tokens and Keychain state
    public func clearTokens() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = .distantPast
        userName = nil
        userEmail = nil
        deleteFromKeychain(key: keychainRefreshKey)
        dbg.info("[DevOps SSO] Tokens cleared", category: "devops-sso")
    }

    /// Get a valid access token, refreshing if needed. Throws if not authenticated.
    public func getValidToken() async throws -> String {
        if isAuthenticated, let token = accessToken {
            return token
        }

        // Try refresh
        if hasRefreshToken {
            let result = try await refreshAccessToken()
            if result.success, let token = result.accessToken {
                return token
            }
        }

        throw DevOpsSsoError.notAuthenticated
    }

    // MARK: - Private — Token Request

    private func postTokenRequest(_ body: [String: String]) async throws -> DevOpsSsoResult {
        guard let url = URL(string: tokenUrl) else {
            return .failure("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = body.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure("Invalid response from token endpoint")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            dbg.error("[DevOps SSO] Token request failed (\(httpResponse.statusCode)): \(errorBody.prefix(500))", category: "devops-sso")
            return .failure("Token request failed (\(httpResponse.statusCode))")
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
            let token_type: String?
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let userInfo = Self.extractUserInfoFromJwt(tokenResponse.access_token)
        let expiresIn = tokenResponse.expires_in ?? 3600

        // Store tokens
        self.accessToken = tokenResponse.access_token
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        self.userName = userInfo.name
        self.userEmail = userInfo.email

        if let refresh = tokenResponse.refresh_token {
            self.refreshToken = refresh
            saveToKeychain(key: keychainRefreshKey, value: refresh)
        }

        dbg.info("[DevOps SSO] Token acquired — user=\(userInfo.name ?? "unknown"), expires in \(expiresIn)s", category: "devops-sso")

        return .success(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresIn: expiresIn,
            userName: userInfo.name,
            userEmail: userInfo.email
        )
    }

    // MARK: - JWT Parsing

    /// Extract user info (name, email/UPN) from a JWT access token
    public static func extractUserInfoFromJwt(_ token: String) -> (name: String?, email: String?) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }

        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        let name = json["name"] as? String
            ?? json["given_name"] as? String
            ?? json["unique_name"] as? String
        let email = json["upn"] as? String
            ?? json["email"] as? String
            ?? json["unique_name"] as? String

        return (name, email)
    }

    // MARK: - Keychain

    private func saveToKeychain(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = value.data(using: .utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Encoding Helpers

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

// MARK: - Error

public enum DevOpsSsoError: Error, LocalizedError {
    case notAuthenticated
    case tokenRefreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated to Azure DevOps. SSO login required."
        case .tokenRefreshFailed(let msg):
            return "Token refresh failed: \(msg)"
        }
    }
}
