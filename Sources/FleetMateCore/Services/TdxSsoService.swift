import Foundation
import WebKit

// MARK: - TDX SSO Authentication Result

/// Result of a TDX SSO authentication attempt
public struct TdxSsoResult: Sendable, Equatable {
    public let success: Bool
    public let token: String?
    public let userName: String?
    public let userEmail: String?
    public let error: String?
    
    public static func success(token: String, userName: String? = nil, userEmail: String? = nil) -> TdxSsoResult {
        TdxSsoResult(success: true, token: token, userName: userName, userEmail: userEmail, error: nil)
    }
    
    public static func failure(_ error: String) -> TdxSsoResult {
        TdxSsoResult(success: false, token: nil, userName: nil, userEmail: nil, error: error)
    }
}

// MARK: - TDX SSO Delegate Protocol

/// Delegate protocol for TDX SSO authentication events
@MainActor
public protocol TdxSsoDelegate: AnyObject {
    /// Called when SSO authentication completes
    func tdxSsoDidComplete(result: TdxSsoResult)
    
    /// Called when the SSO window should be dismissed
    func tdxSsoDidRequestDismiss()
}

// MARK: - TDX SSO Service

/// Service for handling TDX SSO authentication via embedded WebView
/// Uses WKWebView to navigate the SAML/Shibboleth flow and capture the JWT token
@MainActor
public class TdxSsoService: NSObject {
    
    // MARK: - Properties
    
    private let config: FleetMateConfig
    private var webView: WKWebView?
    private var authContinuation: CheckedContinuation<TdxSsoResult, Never>?
    
    public weak var delegate: TdxSsoDelegate?
    
    /// The TDX SSO login URL
    public var ssoLoginUrl: URL? {
        guard let baseUrl = config.tdxBaseUrl?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            return nil
        }
        // TDX SSO endpoint - initiates SAML flow
        return URL(string: "\(baseUrl)/TDWebApi/api/auth/loginsso")
    }
    
    /// Patterns indicating successful authentication
    private let successPatterns = [
        "/SBTDClient/",      // TDX client home after login
        "/TDClient/",        // Another TDX client pattern
        "/TDNext/",          // TDNext interface
        "/Home/Desktop"      // TDX desktop home
    ]
    
    /// Cookie names to look for JWT token
    private let tokenCookieNames = [
        "TDWebApi-AuthToken",
        "authToken",
        ".AspNetCore.Cookies"
    ]
    
    // MARK: - Initialization
    
    public init(config: FleetMateConfig) {
        self.config = config
        super.init()
    }
    
    // MARK: - Public API
    
    /// Check if SSO is available for authentication
    public var isSsoAvailable: Bool {
        guard let baseUrl = config.tdxBaseUrl, !baseUrl.isEmpty else {
            return false
        }
        return config.tdxSsoEnabled
    }
    
    /// Create and configure a WebView for SSO authentication
    /// - Returns: A configured WKWebView ready for SSO login
    public func createSsoWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        
        // Use persistent data store for cookies
        let dataStore = WKWebsiteDataStore.default()
        configuration.websiteDataStore = dataStore
        
        // Allow JavaScript (required for SAML flow)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        
        self.webView = webView
        return webView
    }
    
    /// Start the SSO authentication flow
    /// - Parameter webView: The WebView to use for authentication
    public func startAuthentication(in webView: WKWebView) {
        guard let url = ssoLoginUrl else {
            delegate?.tdxSsoDidComplete(result: .failure("TDX base URL not configured"))
            return
        }
        
        self.webView = webView
        webView.navigationDelegate = self
        
        let request = URLRequest(url: url)
        webView.load(request)
    }
    
    /// Authenticate with SSO and wait for result
    /// - Returns: The SSO authentication result
    public func authenticate() async -> TdxSsoResult {
        guard let webView = webView else {
            return .failure("WebView not configured")
        }
        
        guard let url = ssoLoginUrl else {
            return .failure("TDX base URL not configured")
        }
        
        return await withCheckedContinuation { continuation in
            self.authContinuation = continuation
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    /// Extract JWT token from cookies after successful authentication
    public func extractToken() async -> String? {
        guard let webView = webView else { return nil }
        
        let dataStore = webView.configuration.websiteDataStore
        let cookies = await dataStore.httpCookieStore.allCookies()
        
        // Look for auth token in cookies
        for cookieName in tokenCookieNames {
            if let cookie = cookies.first(where: { $0.name == cookieName }) {
                return cookie.value
            }
        }
        
        // Try to extract from page JavaScript (localStorage or sessionStorage)
        if let token = try? await extractTokenFromPage() {
            return token
        }
        
        return nil
    }
    
    /// Extract user info from the authenticated session
    public func extractUserInfo() async -> (name: String?, email: String?) {
        guard let webView = webView else { return (nil, nil) }
        
        // Try to get user info from TDX API endpoint
        let userInfoScript = """
            (function() {
                try {
                    // Check if TDX has user info in global scope
                    if (typeof CURRENT_USER !== 'undefined') {
                        return JSON.stringify({
                            name: CURRENT_USER.FullName || CURRENT_USER.Name,
                            email: CURRENT_USER.Email || CURRENT_USER.PrimaryEmail
                        });
                    }
                    // Check for TDNext user info
                    if (typeof window.__TD_USER__ !== 'undefined') {
                        return JSON.stringify({
                            name: window.__TD_USER__.fullName,
                            email: window.__TD_USER__.email
                        });
                    }
                    return null;
                } catch (e) {
                    return null;
                }
            })();
        """
        
        do {
            if let result = try await webView.evaluateJavaScript(userInfoScript) as? String,
               let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return (json["name"], json["email"])
            }
        } catch {
            print("[TdxSsoService] Failed to extract user info: \(error)")
        }
        
        return (nil, nil)
    }
    
    /// Clear all SSO session data
    public func clearSession() async {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = Set([
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeLocalStorage
        ])
        
        await dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
    }
    
    // MARK: - Private Methods
    
    private func extractTokenFromPage() async throws -> String? {
        guard let webView = webView else { return nil }
        
        let script = """
            (function() {
                // Check localStorage
                var token = localStorage.getItem('authToken') || 
                           localStorage.getItem('TDWebApi-AuthToken') ||
                           localStorage.getItem('jwtToken');
                if (token) return token;
                
                // Check sessionStorage
                token = sessionStorage.getItem('authToken') ||
                       sessionStorage.getItem('TDWebApi-AuthToken') ||
                       sessionStorage.getItem('jwtToken');
                if (token) return token;
                
                // Check for bearer token in any API configuration
                if (typeof webApiConfig !== 'undefined' && webApiConfig.bearerToken) {
                    return webApiConfig.bearerToken;
                }
                
                return null;
            })();
        """
        
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }
    
    private func checkForSuccessfulAuth(url: URL) -> Bool {
        let urlString = url.absoluteString
        return successPatterns.contains { urlString.contains($0) }
    }
    
    private func completeAuthentication() {
        Task {
            // Extract token
            guard let token = await extractToken() else {
                let result = TdxSsoResult.failure("Failed to extract authentication token")
                delegate?.tdxSsoDidComplete(result: result)
                authContinuation?.resume(returning: result)
                authContinuation = nil
                return
            }
            
            // Extract user info
            let (userName, userEmail) = await extractUserInfo()
            
            let result = TdxSsoResult.success(token: token, userName: userName, userEmail: userEmail)
            delegate?.tdxSsoDidComplete(result: result)
            authContinuation?.resume(returning: result)
            authContinuation = nil
        }
    }
}

// MARK: - WKNavigationDelegate

extension TdxSsoService: WKNavigationDelegate {
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        
        print("[TdxSsoService] Navigation finished: \(url.absoluteString)")
        
        // Check if we've reached a success page
        if checkForSuccessfulAuth(url: url) {
            print("[TdxSsoService] Detected successful authentication")
            completeAuthentication()
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[TdxSsoService] Navigation failed: \(error.localizedDescription)")
        
        let result = TdxSsoResult.failure("Navigation failed: \(error.localizedDescription)")
        delegate?.tdxSsoDidComplete(result: result)
        authContinuation?.resume(returning: result)
        authContinuation = nil
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[TdxSsoService] Provisional navigation failed: \(error.localizedDescription)")
        
        // NSURLErrorCancelled is not an actual error (e.g., redirect)
        if (error as NSError).code == NSURLErrorCancelled {
            return
        }
        
        let result = TdxSsoResult.failure("Connection failed: \(error.localizedDescription)")
        delegate?.tdxSsoDidComplete(result: result)
        authContinuation?.resume(returning: result)
        authContinuation = nil
    }
    
    public func webView(_ webView: WKWebView, 
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        
        if let url = navigationAction.request.url {
            print("[TdxSsoService] Navigating to: \(url.absoluteString)")
        }
        
        decisionHandler(.allow)
    }
    
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        
        // Check for auth token in response cookies
        if let response = navigationResponse.response as? HTTPURLResponse,
           let url = response.url {
            
            // Log response for debugging
            print("[TdxSsoService] Response from \(url.host ?? "unknown"): \(response.statusCode)")
            
            // Check cookies in response
            if let headerFields = response.allHeaderFields as? [String: String] {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                for cookie in cookies {
                    if tokenCookieNames.contains(cookie.name) {
                        print("[TdxSsoService] Found auth token cookie: \(cookie.name)")
                    }
                }
            }
        }
        
        decisionHandler(.allow)
    }
}
