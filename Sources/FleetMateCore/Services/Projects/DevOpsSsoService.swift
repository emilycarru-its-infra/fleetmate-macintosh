import Foundation
import CryptoKit
import Security

#if canImport(AppKit)
import AppKit
#endif

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

    /// True if we have a non-expired access token (with 5-minute buffer)
    public var isAuthenticated: Bool {
        guard let token = accessToken, !token.isEmpty else { return false }
        return Date().addingTimeInterval(5 * 60) < tokenExpiry
    }

    /// True if a refresh token is available (from MSAL cache or in-memory)
    public var hasRefreshToken: Bool {
        if let rt = refreshToken, !rt.isEmpty { return true }
        // Check MSAL cache file for a refresh token
        return loadRefreshTokenFromMsalCache() != nil
    }

    public init(tenantId: String? = nil) {
        let tenant = tenantId ?? "organizations"
        self.authorizeUrl = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize"
        self.tokenUrl = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token"

        dbg.info("[DevOps SSO] Initialized (tenant=\(tenant), az CLI + MSAL cache — no Keychain)", category: "devops-sso")
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

    /// Acquire a valid access token.
    /// Priority: 1) `az` CLI  2) MSAL cache refresh token  3) in-memory refresh token
    public func refreshAccessToken() async throws -> DevOpsSsoResult {
        // 1. Try `az` CLI first — seamless with Platform SSO, no prompts
        dbg.info("[DevOps SSO] Attempting token acquisition via az CLI...", category: "devops-sso")
        let azResult = await acquireTokenFromAzCli()
        if azResult.success {
            dbg.info("[DevOps SSO] az CLI token acquired — user=\(azResult.userName ?? "unknown")", category: "devops-sso")
            return azResult
        }
        dbg.warn("[DevOps SSO] az CLI failed: \(azResult.error ?? "unknown") — trying MSAL cache...", category: "devops-sso")

        // 2. Try MSAL cache file (same tokens az CLI uses, but read directly)
        if let msalRefresh = loadRefreshTokenFromMsalCache() {
            dbg.info("[DevOps SSO] Found refresh token in MSAL cache, refreshing...", category: "devops-sso")
            let msalResult = try await refreshWithToken(msalRefresh)
            if msalResult.success {
                return msalResult
            }
            dbg.warn("[DevOps SSO] MSAL cache refresh failed: \(msalResult.error ?? "unknown")", category: "devops-sso")
        }

        // 3. Try in-memory refresh token (from previous PKCE flow in this session)
        if let refresh = refreshToken, !refresh.isEmpty {
            dbg.info("[DevOps SSO] Trying in-memory refresh token...", category: "devops-sso")
            let result = try await refreshWithToken(refresh)
            if !result.success {
                self.refreshToken = nil
            }
            return result
        }

        return .failure("No token source available (az CLI, MSAL cache, or refresh token)")
    }

    /// Refresh using a specific refresh token
    private func refreshWithToken(_ refresh: String) async throws -> DevOpsSsoResult {
        let body = [
            "client_id": Self.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "scope": Self.scope,
        ]
        return try await postTokenRequest(body)
    }

    /// Set tokens from an external source (in-memory only — no Keychain)
    public func setTokens(accessToken: String, refreshToken: String? = nil, expiresIn: Int = 3600, userName: String? = nil, userEmail: String? = nil) {
        self.accessToken = accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        self.userName = userName
        self.userEmail = userEmail
        if let refresh = refreshToken {
            self.refreshToken = refresh
        }
    }

    /// Clear all in-memory token state
    public func clearTokens() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = .distantPast
        userName = nil
        userEmail = nil
        dbg.info("[DevOps SSO] Tokens cleared (in-memory)", category: "devops-sso")
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

    // MARK: - az CLI Token Acquisition

    /// Acquire a DevOps access token via `az account get-access-token`.
    /// This is seamless with Platform SSO — no prompts, no Keychain.
    private func acquireTokenFromAzCli() async -> DevOpsSsoResult {
        do {
            let result = try await runAzCli()
            return result
        } catch {
            return .failure("az CLI: \(error.localizedDescription)")
        }
    }

    private func runAzCli() async throws -> DevOpsSsoResult {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            // Find az in common locations
            let azPaths = ["/opt/homebrew/bin/az", "/usr/local/bin/az", "/usr/bin/az"]
            let azPath = azPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let path = azPath else {
                continuation.resume(returning: .failure("az CLI not found"))
                return
            }

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["account", "get-access-token", "--resource", Self.devOpsResource, "--output", "json"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure("az CLI launch failed: \(error)"))
                return
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                continuation.resume(returning: .failure("az CLI exited with status \(process.terminationStatus)"))
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else {
                continuation.resume(returning: .failure("az CLI returned empty output"))
                return
            }

            struct AzTokenResponse: Decodable {
                let accessToken: String
                let expiresOn: String?
                let expires_on: Int?
                let tenant: String?
                let tokenType: String?
            }

            do {
                let tokenResp = try JSONDecoder().decode(AzTokenResponse.self, from: data)
                let userInfo = Self.extractUserInfoFromJwt(tokenResp.accessToken)

                // Calculate expires_in from expires_on timestamp
                let expiresIn: Int
                if let ts = tokenResp.expires_on {
                    expiresIn = max(ts - Int(Date().timeIntervalSince1970), 60)
                } else {
                    expiresIn = 3600
                }

                // Store token in memory
                self.accessToken = tokenResp.accessToken
                self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
                self.userName = userInfo.name
                self.userEmail = userInfo.email

                continuation.resume(returning: .success(
                    accessToken: tokenResp.accessToken,
                    expiresIn: expiresIn,
                    userName: userInfo.name,
                    userEmail: userInfo.email
                ))
            } catch {
                continuation.resume(returning: .failure("az CLI JSON parse failed: \(error)"))
            }
        }
    }

    // MARK: - MSAL Token Cache (fallback)

    /// Read refresh token from az CLI's MSAL token cache file (~/.azure/msal_token_cache.json).
    /// No Keychain access — just reads a JSON file.
    private func loadRefreshTokenFromMsalCache() -> String? {
        let cacheUrl = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".azure")
            .appendingPathComponent("msal_token_cache.json")

        guard let data = try? Data(contentsOf: cacheUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshTokens = json["RefreshToken"] as? [String: Any] else {
            return nil
        }

        // Find a refresh token for our client ID
        for (_, value) in refreshTokens {
            guard let entry = value as? [String: Any],
                  let clientId = entry["client_id"] as? String,
                  clientId == Self.clientId,
                  let secret = entry["secret"] as? String,
                  !secret.isEmpty else {
                continue
            }
            return secret
        }
        return nil
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
