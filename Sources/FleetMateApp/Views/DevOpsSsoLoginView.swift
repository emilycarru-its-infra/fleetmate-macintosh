import SwiftUI
import WebKit
import FleetMateCore
import CryptoKit

// MARK: - DevOps SSO Result

struct DevOpsSsoResult: Equatable {
    let success: Bool
    let token: String?
    let expiresIn: Int?
    let userName: String?
    let error: String?

    static func success(token: String, expiresIn: Int?, userName: String?) -> DevOpsSsoResult {
        DevOpsSsoResult(success: true, token: token, expiresIn: expiresIn, userName: userName, error: nil)
    }

    static func failure(_ error: String) -> DevOpsSsoResult {
        DevOpsSsoResult(success: false, token: nil, expiresIn: nil, userName: nil, error: error)
    }
}

// MARK: - DevOps SSO Login View

/// Browser-based OAuth2 authorization code flow with PKCE for Azure DevOps
struct DevOpsSsoLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: DevOpsSsoLoginViewModel

    let onComplete: (DevOpsSsoResult) -> Void

    init(config: FleetMateConfig, onComplete: @escaping (DevOpsSsoResult) -> Void) {
        self._viewModel = StateObject(wrappedValue: DevOpsSsoLoginViewModel(config: config))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Azure DevOps")
                        .font(.headline)
                    Text("Authenticate with your Microsoft account")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.isNavigating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            // Content
            if let errorMessage = viewModel.errorMessage {
                errorView(message: errorMessage)
            } else {
                ZStack {
                    DevOpsWebViewRepresentable(webView: viewModel.webView)

                    if viewModel.isLoading {
                        Color.black.opacity(0.5)
                            .overlay {
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .controlSize(.large)
                                    Text("Initializing OAuth2 login...")
                                        .foregroundColor(.white)
                                }
                            }
                    }
                }
            }

            // Status bar
            Divider()
            HStack(spacing: 8) {
                if viewModel.isNavigating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
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
                Button("Try Again") { viewModel.startAuthentication() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { dismiss() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WebView Representable

struct DevOpsWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - View Model

@MainActor
class DevOpsSsoLoginViewModel: NSObject, ObservableObject {
    @Published var isLoading = true
    @Published var isNavigating = false
    @Published var errorMessage: String?
    @Published var authResult: DevOpsSsoResult?
    @Published var statusText = "Waiting..."

    let webView: WKWebView
    private let config: FleetMateConfig

    // OAuth2 PKCE parameters
    private var codeVerifier: String = ""
    private var codeChallenge: String = ""
    private var state: String = ""
    private let redirectUri = "https://login.microsoftonline.com/common/oauth2/nativeclient"
    private let adoScope = "499b84ac-1321-427f-aa17-267ca6975798/.default offline_access"

    init(config: FleetMateConfig) {
        self.config = config

        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: webConfig)
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"

        super.init()
    }

    func startAuthentication() {
        isLoading = true
        isNavigating = false
        errorMessage = nil
        authResult = nil

        guard let clientId = config.devopsClientId, !clientId.isEmpty,
              let tenantId = config.devopsTenantId, !tenantId.isEmpty else {
            errorMessage = "Azure DevOps OAuth2 not configured. Set DEVOPS_CLIENT_ID and DEVOPS_TENANT_ID."
            isLoading = false
            return
        }

        // Generate PKCE parameters
        codeVerifier = generateCodeVerifier()
        codeChallenge = generateCodeChallenge(from: codeVerifier)
        state = UUID().uuidString

        // Build authorization URL
        var components = URLComponents(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: adoScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]

        guard let url = components.url else {
            errorMessage = "Failed to build authorization URL"
            isLoading = false
            return
        }

        statusText = "Loading sign-in page..."
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String) {
        guard let clientId = config.devopsClientId,
              let tenantId = config.devopsTenantId else { return }

        statusText = "Exchanging authorization code..."

        Task {
            let tokenUrl = URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token")!

            var request = URLRequest(url: tokenUrl)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let bodyParams = [
                "client_id=\(clientId)",
                "code=\(code)",
                "redirect_uri=\(redirectUri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectUri)",
                "grant_type=authorization_code",
                "code_verifier=\(codeVerifier)",
                "scope=\(adoScope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? adoScope)"
            ].joined(separator: "&")

            request.httpBody = bodyParams.data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    errorMessage = "Invalid token response"
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let desc = errorJson["error_description"] as? String {
                        errorMessage = "Token exchange failed: \(desc)"
                    } else {
                        errorMessage = "Token exchange failed (HTTP \(httpResponse.statusCode))"
                    }
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String else {
                    errorMessage = "Failed to parse access token"
                    return
                }

                let expiresIn = json["expires_in"] as? Int ?? 3600

                // Extract user info from ID token if available
                var userName: String?
                if let idToken = json["id_token"] as? String {
                    let parts = idToken.split(separator: ".")
                    if parts.count >= 2 {
                        var payload = String(parts[1])
                        payload = payload.replacingOccurrences(of: "-", with: "+")
                                         .replacingOccurrences(of: "_", with: "/")
                        let remainder = payload.count % 4
                        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
                        if let data = Data(base64Encoded: payload),
                           let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            userName = claims["name"] as? String
                                ?? claims["preferred_username"] as? String
                        }
                    }
                }

                authResult = .success(token: accessToken, expiresIn: expiresIn, userName: userName)

            } catch {
                errorMessage = "Token exchange error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension DevOpsSsoLoginViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let urlString = url.absoluteString

        // Check for the redirect URI with authorization code
        if urlString.hasPrefix(redirectUri) {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []

            // Check state matches
            if let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
               returnedState != state {
                errorMessage = "OAuth2 state mismatch — possible CSRF attack"
                decisionHandler(.cancel)
                return
            }

            if let code = queryItems.first(where: { $0.name == "code" })?.value {
                // Got authorization code — exchange for token
                decisionHandler(.cancel)
                exchangeCodeForToken(code: code)
                return
            }

            if let error = queryItems.first(where: { $0.name == "error" })?.value {
                let desc = queryItems.first(where: { $0.name == "error_description" })?.value ?? error
                errorMessage = "Authorization failed: \(desc)"
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isNavigating = true
        if let host = webView.url?.host {
            statusText = host
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        isNavigating = false
        if let host = webView.url?.host {
            statusText = host
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        isNavigating = false
        let nsError = error as NSError
        if nsError.code != NSURLErrorCancelled {
            errorMessage = error.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code != NSURLErrorCancelled && nsError.code != 102 {
            isLoading = false
            isNavigating = false
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    DevOpsSsoLoginView(config: FleetMateConfig()) { result in
        print("Auth result: \(result)")
    }
}
