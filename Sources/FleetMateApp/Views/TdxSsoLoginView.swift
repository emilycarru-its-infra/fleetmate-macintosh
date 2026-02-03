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
            
            // WebView
            if viewModel.isLoading {
                loadingView
            } else if let errorMessage = viewModel.errorMessage {
                errorView(message: errorMessage)
            } else {
                webViewContainer
            }
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
    
    let webView: WKWebView
    private let ssoService: TdxSsoService
    private let config: FleetMateConfig
    
    /// Patterns indicating successful authentication
    private let successPatterns = [
        "/SBTDClient/",
        "/TDClient/",
        "/TDNext/",
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
        self.webView = ssoService.createSsoWebView()
        super.init()
    }
    
    func startAuthentication() {
        isLoading = true
        errorMessage = nil
        
        guard let url = ssoService.ssoLoginUrl else {
            errorMessage = "TDX base URL not configured"
            isLoading = false
            return
        }
        
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
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isNavigating = true
        if let url = webView.url {
            currentUrl = url.host ?? ""
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        isNavigating = false
        
        guard let url = webView.url else { return }
        currentUrl = url.host ?? ""
        
        // Check if we've reached a success page
        if checkForSuccessfulAuth(url: url) {
            completeAuthentication()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        isNavigating = false
        errorMessage = error.localizedDescription
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // NSURLErrorCancelled is not an actual error (e.g., redirect)
        if (error as NSError).code == NSURLErrorCancelled {
            return
        }
        
        isLoading = false
        isNavigating = false
        errorMessage = error.localizedDescription
    }
}

// MARK: - Preview

#Preview {
    TdxSsoLoginView(config: FleetMateConfig()) { result in
        print("Auth result: \(result)")
    }
}
