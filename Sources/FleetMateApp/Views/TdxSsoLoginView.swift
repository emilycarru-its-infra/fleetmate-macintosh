import SwiftUI
import WebKit
import FleetMateCore

// MARK: - SSO Login View

/// SwiftUI view for TDX SSO authentication
/// Presents a WebView that navigates through the SAML/Shibboleth flow
struct TdxSsoLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: TdxSsoLoginViewModel
    
    let onComplete: (TdxSsoResult) -> Void
    
    init(config: FleetMateConfig, onComplete: @escaping (TdxSsoResult) -> Void) {
        self._viewModel = StateObject(wrappedValue: TdxSsoLoginViewModel(config: config))
        self.onComplete = onComplete
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // WebView - show after initial navigation starts
            if let errorMessage = viewModel.errorMessage {
                errorView(message: errorMessage)
            } else {
                ZStack {
                    webViewContainer
                    
                    // Show loading overlay only during initial load
                    if viewModel.isLoading && viewModel.navigationLog.count < 3 {
                        Color.black.opacity(0.5)
                            .overlay {
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .controlSize(.large)
                                    Text("Initializing SSO login...")
                                        .foregroundColor(.white)
                                }
                            }
                    }
                }
            }
            
            // Debug footer
            Divider()
            HStack(spacing: 8) {
                if viewModel.isNavigating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.currentUrl.isEmpty ? "Waiting..." : viewModel.currentUrl)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(viewModel.navigationLog.count) events")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 800,
               minHeight: 500, idealHeight: 700, maxHeight: 900)
        .onAppear {
            viewModel.startAuthentication()
        }
        .onChange(of: viewModel.authResult) { _, result in
            if let result = result {
                onComplete(result)
                if result.success {
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to TeamDynamix")
                    .font(.headline)
                Text("Authenticate with your organization's identity provider")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if viewModel.isNavigating {
                ProgressView()
                    .controlSize(.small)
            }
            
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading SSO login...")
                .foregroundColor(.secondary)
            
            if !viewModel.currentUrl.isEmpty {
                VStack(spacing: 4) {
                    Text("Current URL:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(viewModel.currentUrl)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }
            }
            
            if let ssoUrl = viewModel.ssoService.ssoLoginUrl {
                VStack(spacing: 4) {
                    Text("Login endpoint:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(ssoUrl.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }
                .padding(.top, 8)
            }
            
            if !viewModel.navigationLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Navigation Log:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(viewModel.navigationLog, id: \.self) { log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                .frame(maxHeight: 200)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("Authentication Error")
                .font(.headline)
            
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            HStack {
                Button("Try Again") {
                    viewModel.startAuthentication()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var webViewContainer: some View {
        WebViewRepresentable(webView: viewModel.webView)
            .onAppear {
                viewModel.webView.navigationDelegate = viewModel
            }
    }
}

// MARK: - WebView Representable

/// NSViewRepresentable wrapper for WKWebView
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    
    func makeNSView(context: Context) -> WKWebView {
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No updates needed
    }
}

// MARK: - View Model

/// View model for TDX SSO login
@MainActor
class TdxSsoLoginViewModel: NSObject, ObservableObject {
    @Published var isLoading = true
    @Published var isNavigating = false
    @Published var errorMessage: String?
    @Published var authResult: TdxSsoResult?
    @Published var currentUrl: String = ""
    @Published var navigationLog: [String] = []
    
    let webView: WKWebView
    let ssoService: TdxSsoService
    private let config: FleetMateConfig
    private var urlSession: URLSession?
    
    /// Patterns indicating successful authentication
    private let successPatterns = [
        "/SBTDClient/",
        "/TDClient/",
        "/TDNext/",
        "/TDWorkManagement/",
        "/Home/Desktop"
    ]
    
    /// Cookie names that contain the auth token
    private let tokenCookieNames = [
        "TDWebApi-AuthToken",
        "authToken",
        ".AspNetCore.Cookies"
    ]
    
    init(config: FleetMateConfig) {
        self.config = config
        self.ssoService = TdxSsoService(config: config)
        
        // Create a URLSession that uses system credentials
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
        sessionConfig.urlCredentialStorage = URLCredentialStorage.shared
        sessionConfig.httpShouldSetCookies = true
        sessionConfig.httpCookieAcceptPolicy = .always
        self.urlSession = URLSession(configuration: sessionConfig)
        
        self.webView = ssoService.createSsoWebView()
        
        // Set Safari user-agent on WebView to trigger Windows Integrated Auth
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
        
        super.init()
        
        // Sync cookies from shared storage to WKWebView
        Task {
            await syncCookiesToWebView()
        }
    }
    
    private func syncCookiesToWebView() async {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await cookieStore.setCookie(cookie)
        }
        print("[TdxSsoLogin] Synced \(cookies.count) cookies from shared storage")
    }
    
    func startAuthentication() {
        isLoading = true
        errorMessage = nil
        navigationLog.removeAll()
        
        guard let url = ssoService.ssoLoginUrl else {
            errorMessage = "TDX base URL not configured"
            isLoading = false
            return
        }
        
        let logMsg = "[START] Pre-authenticating with URLSession..."
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        // Try to pre-authenticate using URLSession first (has better Kerberos support)
        Task {
            await preAuthenticateWithURLSession(targetUrl: url)
        }
    }
    
    private func preAuthenticateWithURLSession(targetUrl: URL) async {
        // Create a configuration that follows redirects and tracks cookies
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        
        // Create a delegate that handles auth and tracks final URL
        let delegate = KerberosAuthDelegate()
        let authSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        
        do {
            let logMsg = "[PREAUTH] Following SSO redirect chain..."
            print("[TdxSsoLogin] \(logMsg)")
            await MainActor.run { navigationLog.append(logMsg) }
            
            var request = URLRequest(url: targetUrl)
            request.httpShouldHandleCookies = true
            // Set Safari user-agent to trigger Windows Integrated Auth
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            
            // Follow all redirects
            var currentURL = targetUrl
            var redirectCount = 0
            let maxRedirects = 15
            
            while redirectCount < maxRedirects {
                let (data, response) = try await authSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else { break }
                
                let respLog = "[PREAUTH] \(redirectCount+1). \(httpResponse.statusCode) - \(httpResponse.url?.absoluteString ?? "unknown")"
                print("[TdxSsoLogin] \(respLog)")
                await MainActor.run { navigationLog.append(respLog) }
                
                currentURL = httpResponse.url ?? currentURL
                
                // Check if we've reached a success page (TDWorkManagement or similar)
                if let finalURL = httpResponse.url?.absoluteString,
                   (finalURL.contains("/TDWorkManagement") || 
                    finalURL.contains("/Home/Desktop") ||
                    finalURL.contains("/TDNext/Home")) {
                    let successLog = "[PREAUTH] ✓ Reached authenticated page!"
                    print("[TdxSsoLogin] \(successLog)")
                    await MainActor.run { navigationLog.append(successLog) }
                    break
                }
                
                // If status is 200-299, we've likely reached final page
                if (200...299).contains(httpResponse.statusCode) {
                    break
                }
                
                // If we got a redirect status, URLSession should have followed it automatically
                if (300...399).contains(httpResponse.statusCode) {
                    break // URLSession follows redirects automatically
                }
                
                redirectCount += 1
                
                // Create next request
                request = URLRequest(url: currentURL)
                request.httpShouldHandleCookies = true
            }
            
            // Sync all cookies to WKWebView
            if let allCookies = HTTPCookieStorage.shared.cookies {
                let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
                for cookie in allCookies {
                    await cookieStore.setCookie(cookie)
                }
                let cookieLog = "[PREAUTH] Synced \(allCookies.count) total cookies to WebView"
                print("[TdxSsoLogin] \(cookieLog)")
                await MainActor.run { navigationLog.append(cookieLog) }
            }
            
            // Load the final URL in WebView
            await MainActor.run {
                continueWithWebView(url: currentURL)
            }
            return
            
        } catch {
            let errLog = "[PREAUTH] Error: \(error.localizedDescription)"
            print("[TdxSsoLogin] \(errLog)")
            await MainActor.run { navigationLog.append(errLog) }
        }
        
        // Continue with WebView regardless of pre-auth result
        await MainActor.run {
            continueWithWebView(url: targetUrl)
        }
    }
    
    private func continueWithWebView(url: URL) {
        let logMsg = "[WEBVIEW] Loading: \(url.absoluteString)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        webView.navigationDelegate = self
        let request = URLRequest(url: url)
        webView.load(request)
    }
    
    private func checkForSuccessfulAuth(url: URL) -> Bool {
        let urlString = url.absoluteString
        return successPatterns.contains { urlString.contains($0) }
    }
    
    private func completeAuthentication() {
        Task {
            // Give the page a moment to set cookies
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            // Extract token from cookies
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            
            var token: String?
            for cookieName in tokenCookieNames {
                if let cookie = cookies.first(where: { $0.name == cookieName }) {
                    token = cookie.value
                    break
                }
            }
            
            // Also try localStorage/sessionStorage
            if token == nil {
                token = try? await extractTokenFromPage()
            }
            
            if let token = token {
                // Get user info
                let userInfo = await extractUserInfo()
                
                authResult = TdxSsoResult.success(
                    token: token,
                    userName: userInfo.name,
                    userEmail: userInfo.email
                )
            } else {
                errorMessage = "Authentication succeeded but could not extract token"
            }
        }
    }
    
    private func extractTokenFromPage() async throws -> String? {
        let script = """
            (function() {
                var token = localStorage.getItem('authToken') || 
                           localStorage.getItem('TDWebApi-AuthToken') ||
                           sessionStorage.getItem('authToken') ||
                           sessionStorage.getItem('TDWebApi-AuthToken');
                return token;
            })();
        """
        
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }
    
    private func extractUserInfo() async -> (name: String?, email: String?) {
        let script = """
            (function() {
                try {
                    if (typeof CURRENT_USER !== 'undefined') {
                        return JSON.stringify({
                            name: CURRENT_USER.FullName || CURRENT_USER.Name,
                            email: CURRENT_USER.Email || CURRENT_USER.PrimaryEmail
                        });
                    }
                    return null;
                } catch (e) {
                    return null;
                }
            })();
        """
        
        do {
            if let result = try await webView.evaluateJavaScript(script) as? String,
               let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return (json["name"], json["email"])
            }
        } catch {
            // Ignore - user info is optional
        }
        
        return (nil, nil)
    }
}

// MARK: - WKNavigationDelegate

extension TdxSsoLoginViewModel: WKNavigationDelegate {
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow all navigation - we need redirects for SSO flow
        if let url = navigationAction.request.url {
            let logMsg = "[DECISION] Allowing: \(url.absoluteString)"
            print("[TdxSsoLogin] \(logMsg)")
            navigationLog.append(logMsg)
        }
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Allow all responses
        if let url = navigationResponse.response.url {
            let logMsg = "[RESPONSE] Status: \((navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0) - \(url.absoluteString)"
            print("[TdxSsoLogin] \(logMsg)")
            navigationLog.append(logMsg)
        }
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isNavigating = true
        if let url = webView.url {
            currentUrl = url.host ?? ""
            let logMsg = "[NAV] \(url.absoluteString)"
            print("[TdxSsoLogin] \(logMsg)")
            navigationLog.append(logMsg)
            
            // After initial redirects, show the WebView even if still "loading"
            if navigationLog.count >= 3 {
                isLoading = false
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        isNavigating = false
        
        guard let url = webView.url else { return }
        currentUrl = url.host ?? ""
        let logMsg = "[DONE] \(url.absoluteString)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        // Check if we've reached a success page
        if checkForSuccessfulAuth(url: url) {
            let successMsg = "[SUCCESS] Pattern detected, completing auth"
            print("[TdxSsoLogin] \(successMsg)")
            navigationLog.append(successMsg)
            completeAuthentication()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        isNavigating = false
        let logMsg = "[ERROR] Navigation failed: \(error.localizedDescription)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        errorMessage = error.localizedDescription
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        
        let logMsg = "[ERROR] Provisional failed: \(error.localizedDescription) (code: \(nsError.code))"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        // NSURLErrorCancelled is not an actual error (e.g., redirect)
        if nsError.code == NSURLErrorCancelled {
            let ignoreMsg = "[INFO] Ignoring cancelled error (redirect)"
            print("[TdxSsoLogin] \(ignoreMsg)")
            navigationLog.append(ignoreMsg)
            return
        }
        
        // Frame load interrupted can happen with TDX redirects - not always an error
        if nsError.code == 102 { // kCFURLErrorFileDoesNotExist / frame load interrupted
            let ignoreMsg = "[INFO] Ignoring frame load interrupted (102)"
            print("[TdxSsoLogin] \(ignoreMsg)")
            navigationLog.append(ignoreMsg)
            // Try to continue - the redirect might still work
            return
        }
        
        isLoading = false
        isNavigating = false
        errorMessage = error.localizedDescription
    }
    
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protectionSpace = challenge.protectionSpace
        let authMethod = protectionSpace.authenticationMethod
        
        let logMsg = "[AUTH] Challenge: \(authMethod) from \(protectionSpace.host)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        // Handle server trust (SSL)
        if authMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        
        // For Negotiate (Kerberos) / NTLM - use default handling which uses system credentials
        if authMethod == NSURLAuthenticationMethodNegotiate ||
           authMethod == NSURLAuthenticationMethodNTLM ||
           authMethod == NSURLAuthenticationMethodDefault {
            let defaultMsg = "[AUTH] Using system credentials for \(authMethod)"
            print("[TdxSsoLogin] \(defaultMsg)")
            navigationLog.append(defaultMsg)
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // For other challenges, use default handling
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Kerberos Auth Delegate for URLSession

/// URLSession delegate that handles Kerberos/Negotiate authentication using system credentials
class KerberosAuthDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        let authMethod = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        
        print("[KerberosAuth] Challenge: \(authMethod) from \(host)")
        
        // Handle server trust
        if authMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        
        // For Kerberos/Negotiate - use default credentials (system Kerberos ticket)
        if authMethod == NSURLAuthenticationMethodNegotiate {
            print("[KerberosAuth] Using default Kerberos credentials")
            // Use default handling which will use the system's Kerberos ticket cache
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // For NTLM - use default credentials
        if authMethod == NSURLAuthenticationMethodNTLM {
            print("[KerberosAuth] Using default NTLM credentials")
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Default handling for other methods
        completionHandler(.performDefaultHandling, nil)
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        let authMethod = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        
        print("[KerberosAuth] Session challenge: \(authMethod) from \(host)")
        
        // Handle server trust
        if authMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        
        // Use default handling for everything else
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Preview

#Preview {
    TdxSsoLoginView(config: FleetMateConfig()) { result in
        print("Auth result: \(result)")
    }
}
