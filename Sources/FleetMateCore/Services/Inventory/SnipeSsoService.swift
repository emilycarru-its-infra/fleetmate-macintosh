import Foundation
import WebKit

/// Result of a Snipe-IT SSO authentication attempt.
public struct SnipeSsoResult: Sendable {
    public let success: Bool
    public let cookies: [HTTPCookie]
    public let userName: String?
    public let error: String?

    public init(success: Bool, cookies: [HTTPCookie] = [], userName: String? = nil, error: String? = nil) {
        self.success = success
        self.cookies = cookies
        self.userName = userName
        self.error = error
    }
}

/// Handles SSO authentication for Snipe-IT via WKWebView.
/// After SAML SSO, Snipe-IT (Laravel Passport) sets:
/// - `snipeit_session` — session cookie
/// - `snipeit_passport_token` — encrypted JWT for cookie-based API auth
/// - `XSRF-TOKEN` — CSRF token for request validation
/// This mimics exactly how a browser authenticates with Snipe-IT.
@MainActor
public class SnipeSsoService: NSObject, ObservableObject, WKNavigationDelegate {
    private let snipeUrl: String
    @Published public var authResult: SnipeSsoResult?

    private var webView: WKWebView?
    private var hasCompleted = false

    public init(snipeUrl: String) {
        self.snipeUrl = snipeUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        super.init()
    }

    /// Create and configure a WKWebView for SSO.
    public func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        // Mimic Safari so Platform SSO Extension intercepts the request
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView = wv
        return wv
    }

    /// Start the SSO flow by navigating to the Snipe-IT URL.
    public func startAuthentication() {
        guard let url = URL(string: snipeUrl) else {
            authResult = SnipeSsoResult(success: false, error: "Invalid Snipe-IT URL")
            return
        }
        hasCompleted = false
        authResult = nil
        let wv = webView ?? createWebView()
        wv.load(URLRequest(url: url))
    }

    /// Attempt silent SSO via URLSession (checks if existing cookies give us API access).
    public func attemptSilentAuth() async -> SnipeSsoResult {
        // Check if shared cookie storage already has a valid passport token
        guard let url = URL(string: snipeUrl) else {
            return SnipeSsoResult(success: false, error: "Invalid URL")
        }

        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let hasPassport = cookies.contains(where: { $0.name == "snipeit_passport_token" })
        let hasSession = cookies.contains(where: { $0.name.contains("snipeit_session") })

        guard hasPassport && hasSession else {
            return SnipeSsoResult(success: false, error: "No valid session cookies")
        }

        // Try an API call with the existing cookies
        let xsrf = cookies.first(where: { $0.name == "XSRF-TOKEN" })?.value.removingPercentEncoding

        guard let apiUrl = URL(string: "\(snipeUrl)/api/v1/account") else {
            return SnipeSsoResult(success: false, error: "Invalid URL")
        }

        var request = URLRequest(url: apiUrl)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.addValue(snipeUrl, forHTTPHeaderField: "Referer")
        if let xsrf { request.addValue(xsrf, forHTTPHeaderField: "X-XSRF-TOKEN") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let userName = extractUserName(from: data)
                return SnipeSsoResult(success: true, cookies: cookies, userName: userName)
            }
        } catch {}

        return SnipeSsoResult(success: false, error: "API call failed with existing cookies")
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasCompleted else { return }
        guard let url = webView.url else { return }
        let path = url.path

        // Snipe-IT redirects to / or /hardware after successful SSO login.
        // The login page is at /login — if we're NOT on login, SSO succeeded.
        let isLoginPage = path.contains("login") || path.contains("saml") || path.contains("sso")
        let isAuthenticatedPage = !isLoginPage && (path == "/" || path.hasPrefix("/hardware") || path.hasPrefix("/dashboard") || path.hasPrefix("/account"))

        if isAuthenticatedPage {
            // Wait a moment for CreateFreshApiToken middleware to set the passport cookie
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                self.extractCookiesAndComplete(from: webView)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        authResult = SnipeSsoResult(success: false, error: error.localizedDescription)
    }

    // MARK: - Cookie Extraction

    private func extractCookiesAndComplete(from webView: WKWebView) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            guard let snipeHost = URL(string: self.snipeUrl)?.host else {
                Task { @MainActor in
                    self.hasCompleted = true
                    self.authResult = SnipeSsoResult(success: false, error: "Cannot parse host from URL")
                }
                return
            }

            let snipeCookies = cookies.filter { cookie in
                cookie.domain.contains(snipeHost) || snipeHost.hasSuffix(cookie.domain.replacingOccurrences(of: ".", with: "", options: .anchored))
            }

            let hasPassport = snipeCookies.contains(where: { $0.name == "snipeit_passport_token" })
            let hasXsrf = snipeCookies.contains(where: { $0.name == "XSRF-TOKEN" })

            guard hasPassport && hasXsrf else {
                // Passport cookie not set yet — the page may need another load
                // (CreateFreshApiToken fires on web middleware, might need a second request)
                Task { @MainActor in
                    // Navigate to /hardware to trigger middleware again
                    if let hardwareUrl = URL(string: "\(self.snipeUrl)/hardware") {
                        webView.load(URLRequest(url: hardwareUrl))
                    }
                }
                return
            }

            // Copy cookies to shared storage for URLSession/Alamofire use
            for cookie in snipeCookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }

            Task { @MainActor in
                self.hasCompleted = true
                let userName = await self.fetchCurrentUser(cookies: snipeCookies)
                self.authResult = SnipeSsoResult(success: true, cookies: snipeCookies, userName: userName)
            }
        }
    }

    /// Fetch the current user's name using the SSO cookies (mimics browser XHR).
    private func fetchCurrentUser(cookies: [HTTPCookie]) async -> String? {
        guard let url = URL(string: "\(snipeUrl)/api/v1/account") else { return nil }
        let xsrf = cookies.first(where: { $0.name == "XSRF-TOKEN" })?.value.removingPercentEncoding

        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.addValue(snipeUrl, forHTTPHeaderField: "Referer")
        if let xsrf { request.addValue(xsrf, forHTTPHeaderField: "X-XSRF-TOKEN") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return extractUserName(from: data)
            }
        } catch {}
        return nil
    }

    private func extractUserName(from data: Data) -> String? {
        struct UserResponse: Decodable {
            let first_name: String?
            let last_name: String?
            let name: String?
            let username: String?
        }
        guard let user = try? JSONDecoder().decode(UserResponse.self, from: data) else { return nil }
        if let first = user.first_name, let last = user.last_name, !first.isEmpty {
            return "\(first) \(last)"
        }
        return user.name ?? user.username
    }
}
