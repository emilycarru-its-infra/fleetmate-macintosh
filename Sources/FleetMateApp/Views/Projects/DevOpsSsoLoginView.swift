import SwiftUI
import WebKit
import FleetMateCore
import AuthenticationServices

// MARK: - SSO Login View

/// SwiftUI view for Azure DevOps OAuth2 SSO authentication.
/// Presents a WKWebView that navigates through the Entra ID OAuth2 + PKCE flow.
/// Platform SSO Extension handles auth silently when available.
struct DevOpsSsoLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: DevOpsSsoLoginViewModel

    let onComplete: (DevOpsSsoResult) -> Void

    init(ssoService: DevOpsSsoService, config: FleetMateConfig, onComplete: @escaping (DevOpsSsoResult) -> Void) {
        self._viewModel = StateObject(wrappedValue: DevOpsSsoLoginViewModel(ssoService: ssoService, config: config))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Azure DevOps")
                        .appFont(.headline)
                    Text("Authenticate with your organization's identity provider")
                        .appFont(.caption)
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

            Divider()

            // WebView or error
            if let errorMessage = viewModel.errorMessage {
                errorView(message: errorMessage)
            } else {
                ZStack {
                    DevOpsWebViewRepresentable(webView: viewModel.webView)
                        .onAppear {
                            viewModel.webView.navigationDelegate = viewModel
                        }

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
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(viewModel.navigationLog.count) events")
                    .appFont(.caption)
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

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Authentication Error")
                .appFont(.headline)
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
}

// MARK: - WebView Representable

struct DevOpsWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - View Model

/// Manages WKWebView-based OAuth2 Authorization Code + PKCE flow for Azure DevOps.
/// Mirrors TdxSsoLoginViewModel patterns: UPN detection, Entra auto-fill,
/// FIDO fallback, and Platform SSO Extension support.
@MainActor
class DevOpsSsoLoginViewModel: NSObject, ObservableObject {
    @Published var isLoading = true
    @Published var isNavigating = false
    @Published var errorMessage: String?
    @Published var authResult: DevOpsSsoResult?
    @Published var currentUrl: String = ""
    @Published var navigationLog: [String] = []

    let webView: WKWebView
    private let ssoService: DevOpsSsoService
    private let config: FleetMateConfig

    /// The user's Platform SSO UPN (e.g. user@domain.ca)
    private var platformSsoUpn: String? {
        didSet {
            if let upn = platformSsoUpn, !upn.isEmpty, !usernameAutoFilled {
                if let host = webView.url?.host, host.contains("login.microsoftonline.com") {
                    ssoLog("[PSSO] UPN now available (\(upn)) — triggering auto-fill")
                    autoFillEntraLogin()
                }
            }
        }
    }
    private var usernameAutoFilled = false
    private var fidoPageLoadedAt: Date?
    private var fidoFallbackInjected = false
    private let fidoTimeoutSeconds: TimeInterval = 2
    private var ssoExtensionAvailable = false

    private func ssoLog(_ message: String) {
        dbg.info(message, category: "devops-sso")
    }

    nonisolated private static func ssoLogStatic(_ message: String) {
        dbg.info(message, category: "devops-sso")
    }

    // MARK: - Entra Auto-Login JavaScript (same pattern as TDX)

    private static func entraAutoLoginScript(upn: String) -> String {
        let escaped = upn
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            var filled = false;
            function tryAutoLogin() {
                if (filled) return;
                var input = document.querySelector('input[name="loginfmt"]');
                if (!input) input = document.querySelector('input[type="email"]');
                if (!input) return;
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                nativeSetter.call(input, '\(escaped)');
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                filled = true;
                console.log('[FleetMate] Auto-filled username: \(escaped)');
                setTimeout(function() {
                    var nextBtn = document.querySelector('input[type="submit"]');
                    if (!nextBtn) nextBtn = document.querySelector('button[type="submit"]');
                    if (!nextBtn) {
                        var btns = document.querySelectorAll('input, button');
                        for (var i = 0; i < btns.length; i++) {
                            var t = (btns[i].value || btns[i].textContent || '').trim().toLowerCase();
                            if (t === 'next' || t === 'sign in') { nextBtn = btns[i]; break; }
                        }
                    }
                    if (nextBtn) { console.log('[FleetMate] Clicking Next'); nextBtn.click(); }
                    window.__fleetmateFidoFallback = false;
                    setTimeout(function() {
                        try { eval(window.__fleetmateFidoScript || ''); } catch(e) {}
                    }, 3000);
                }, 300);
            }
            tryAutoLogin();
            [200, 500, 1000, 2000].forEach(function(d) { setTimeout(tryAutoLogin, d); });
            if (document.body) {
                var observer = new MutationObserver(function() { tryAutoLogin(); });
                observer.observe(document.body, { childList: true, subtree: true });
                setTimeout(function() { observer.disconnect(); }, 5000);
            }
        })();
        """
    }

    // MARK: - FIDO Fallback JavaScript (same pattern as TDX)

    private static let fidoFallbackScript = """
    (function() {
        if (window.__fleetmateFidoFallback) return;
        window.__fleetmateFidoFallback = true;
        var acted = false;
        function tryFallback() {
            if (acted) return true;
            var elems = document.querySelectorAll('a, button, [role="link"], [role="button"], input[type="submit"], span[tabindex], div[tabindex], li[tabindex]');
            for (var i = 0; i < elems.length; i++) {
                var text = (elems[i].textContent || elems[i].value || '').trim().toLowerCase();
                if (text.indexOf('sign in another way') !== -1 ||
                    text.indexOf('other ways to sign in') !== -1 ||
                    text.indexOf('use another method') !== -1 ||
                    text.indexOf('use a different method') !== -1 ||
                    text.indexOf('try another way') !== -1 ||
                    text.indexOf('try a different way') !== -1 ||
                    text.indexOf('choose another') !== -1 ||
                    text.indexOf("i can't use") !== -1) {
                    console.log('[FleetMate] FIDO fallback - clicking: ' + text);
                    elems[i].click();
                    acted = true;
                    return true;
                }
            }
            var bodyText = (document.body && document.body.innerText) || '';
            var isErrorPage = bodyText.indexOf("couldn\\u2019t sign you in") !== -1 ||
                              bodyText.indexOf("couldn't sign you in") !== -1 ||
                              bodyText.indexOf("sign-in was unsuccessful") !== -1 ||
                              bodyText.indexOf("Something went wrong") !== -1;
            var isFidoPage = bodyText.indexOf('passkey') !== -1 ||
                             bodyText.indexOf('security key') !== -1 ||
                             bodyText.indexOf('FIDO') !== -1;
            if (!isErrorPage && !isFidoPage) return false;
            var tiles = document.querySelectorAll('[data-value]');
            if (tiles.length > 0) {
                var preferred = ['PhoneAppNotification', 'PhoneAppOTP', 'OneWaySMS',
                               'TwoWayVoiceMobile', 'Password', 'PhoneAppPassword'];
                for (var p = 0; p < preferred.length; p++) {
                    for (var t = 0; t < tiles.length; t++) {
                        var val = tiles[t].getAttribute('data-value') || '';
                        if (val === preferred[p]) {
                            console.log('[FleetMate] Selecting alt method: ' + val);
                            tiles[t].click();
                            acted = true;
                            setTimeout(function() {
                                var btns = document.querySelectorAll('input[type="submit"], button[type="submit"], button');
                                for (var j = 0; j < btns.length; j++) {
                                    var bt = (btns[j].textContent || btns[j].value || '').trim().toLowerCase();
                                    if (bt === 'next' || bt === 'verify' || bt === 'sign in' ||
                                        bt === 'send code' || bt === 'yes' || bt === 'send notification') {
                                        btns[j].click(); break;
                                    }
                                }
                            }, 500);
                            return true;
                        }
                    }
                }
            }
            if (isErrorPage) {
                for (var i = 0; i < elems.length; i++) {
                    var text = (elems[i].textContent || elems[i].value || '').trim().toLowerCase();
                    if (text === 'back' || text === 'go back') {
                        console.log('[FleetMate] Error page - clicking: ' + text);
                        elems[i].click();
                        acted = true;
                        return true;
                    }
                }
            }
            return false;
        }
        if (document.body) {
            var observer = new MutationObserver(function() { tryFallback(); });
            observer.observe(document.body, { childList: true, subtree: true });
            setTimeout(function() { observer.disconnect(); }, 45000);
        }
        var delays = [200, 500, 1000, 1500, 2000, 3000, 4000, 6000, 8000, 10000, 13000, 16000, 20000];
        delays.forEach(function(d) { setTimeout(tryFallback, d); });
    })();
    """

    // MARK: - Init

    init(ssoService: DevOpsSsoService, config: FleetMateConfig) {
        self.ssoService = ssoService
        self.config = config

        // Create WKWebView with default data store (for Platform SSO Extension interception)
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = WKWebsiteDataStore.default()
        wkConfig.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: .zero, configuration: wkConfig)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
        self.webView = wv

        super.init()

        // Detect Platform SSO UPN in the background
        Task { [weak self] in
            let upn = await Self.detectPlatformSsoUpn()
            await MainActor.run { self?.platformSsoUpn = upn }
        }
    }

    // MARK: - Start Authentication

    func startAuthentication() {
        isLoading = true
        errorMessage = nil
        navigationLog.removeAll()
        fidoPageLoadedAt = nil
        fidoFallbackInjected = false
        usernameAutoFilled = false

        detectSsoExtension()

        guard let url = ssoService.buildAuthorizeUrl(loginHint: platformSsoUpn) else {
            errorMessage = "Failed to build OAuth2 authorize URL"
            isLoading = false
            return
        }

        let logMsg = "[START] Loading OAuth2 authorize URL..."
        ssoLog(logMsg)
        navigationLog.append(logMsg)

        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    /// Attempt silent authentication using the refresh token only (no WebView needed).
    /// Returns true if a valid access token was obtained.
    func performSilentAuthentication() async -> Bool {
        guard ssoService.hasRefreshToken else {
            ssoLog("[SILENT] No refresh token available")
            return false
        }

        ssoLog("[SILENT] Attempting token refresh...")
        do {
            let result = try await ssoService.refreshAccessToken()
            if result.success, result.accessToken != nil {
                ssoLog("[SILENT] Token refresh succeeded — user=\(result.userName ?? "unknown")")
                authResult = result
                return true
            }
        } catch {
            ssoLog("[SILENT] Token refresh error: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: - Platform SSO Detection

    private static func detectPlatformSsoUpn() async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = ProcessRunner.runSync("/usr/bin/app-sso", ["platform", "-s"])
                guard result.exitCode != -1 else {
                    ssoLogStatic("[PSSO] Failed to run app-sso: \(result.stderr)")
                    continuation.resume(returning: nil)
                    return
                }
                let output = result.stdout

                var bestUpn: String?
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains("upn") {
                        if let range = trimmed.range(of: #""([^"]+@[^"]+)""#, options: .regularExpression) {
                            let candidate = String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            if candidate.uppercased().contains("KERBEROS.MICROSOFTONLINE.COM") { continue }
                            if candidate.contains("@") { bestUpn = candidate.lowercased() }
                        }
                    }
                }

                if let upn = bestUpn {
                    ssoLogStatic("[PSSO] Detected UPN: \(upn)")
                }
                continuation.resume(returning: bestUpn)
            }
        }
    }

    private func detectSsoExtension() {
        let entraUrl = URL(string: "https://login.microsoftonline.com")!
        let provider = ASAuthorizationSingleSignOnProvider(identityProvider: entraUrl)
        ssoExtensionAvailable = provider.canPerformAuthorization
        let status = ssoExtensionAvailable ? "available" : "not available"
        ssoLog("[PSSO] Enterprise SSO Extension: \(status)")
        navigationLog.append("[PSSO] SSO Extension: \(status)")
    }

    // MARK: - Entra Auto-Fill

    private func autoFillEntraLogin() {
        guard !usernameAutoFilled else { return }
        guard let upn = platformSsoUpn else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !self.usernameAutoFilled, self.platformSsoUpn != nil {
                    self.autoFillEntraLogin()
                }
            }
            return
        }

        usernameAutoFilled = true
        ssoLog("[PSSO] Auto-filling Entra sign-in with: \(upn)")
        navigationLog.append("[PSSO] Auto-fill: \(upn)")

        let script = Self.entraAutoLoginScript(upn: upn)
        Task {
            _ = try? await webView.evaluateJavaScript(script)
            for delay in [500, 1000, 2000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                _ = try? await webView.evaluateJavaScript(script)
            }

            ssoLog("[PSSO] Scheduling FIDO fallback after auto-fill")
            scheduleFidoTimeout()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.authResult == nil {
                ssoLog("[PSSO] Injecting FIDO fallback after auto-fill timeout")
                _ = try? await webView.evaluateJavaScript(Self.fidoFallbackScript)
            }
        }
    }

    // MARK: - FIDO Timeout

    private func scheduleFidoTimeout() {
        guard fidoPageLoadedAt == nil else { return }
        fidoPageLoadedAt = Date()
        ssoLog("[PSSO] FIDO page detected — waiting \(Int(fidoTimeoutSeconds))s for Platform SSO...")
        navigationLog.append("[PSSO] FIDO wait \(Int(fidoTimeoutSeconds))s...")

        Task {
            try? await Task.sleep(nanoseconds: UInt64(fidoTimeoutSeconds * 1_000_000_000))
            if authResult == nil && !fidoFallbackInjected {
                injectFidoFallback()
            }
        }
    }

    private func injectFidoFallback() {
        guard !fidoFallbackInjected else { return }
        fidoFallbackInjected = true
        ssoLog("[PSSO] FIDO timeout — injecting fallback")
        navigationLog.append("[PSSO] FIDO fallback injected")
        Task {
            _ = try? await webView.evaluateJavaScript(Self.fidoFallbackScript)
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

        // Check if this is the OAuth2 redirect URI with an auth code
        if DevOpsSsoService.isRedirectUri(url) {
            decisionHandler(.cancel) // Don't actually navigate to this URL

            if let code = DevOpsSsoService.extractCode(from: url) {
                let logMsg = "[OAUTH2] Authorization code received — exchanging for tokens..."
                ssoLog(logMsg)
                navigationLog.append(logMsg)

                Task {
                    do {
                        let result = try await ssoService.exchangeCode(code)
                        if result.success {
                            ssoLog("[OAUTH2] Token exchange succeeded — user=\(result.userName ?? "unknown")")
                            navigationLog.append("[OAUTH2] Authenticated: \(result.userName ?? "unknown")")
                        } else {
                            ssoLog("[OAUTH2] Token exchange failed: \(result.error ?? "unknown")")
                            navigationLog.append("[OAUTH2] Exchange failed: \(result.error ?? "")")
                        }
                        authResult = result
                    } catch {
                        let errMsg = "Token exchange error: \(error.localizedDescription)"
                        ssoLog("[OAUTH2] \(errMsg)")
                        authResult = .failure(errMsg)
                    }
                }
            } else if let error = DevOpsSsoService.extractError(from: url) {
                let logMsg = "[OAUTH2] Authorization error: \(error)"
                ssoLog(logMsg)
                navigationLog.append(logMsg)
                authResult = .failure(error)
            } else {
                authResult = .failure("Unexpected redirect without code or error")
            }
            return
        }

        // Allow autologon (Seamless SSO / Platform SSO)
        if urlString.contains("autologon.microsoftazuread-sso.com") {
            ssoLog("[DECISION] Allowing autologon (Platform SSO)")
            navigationLog.append("[DECISION] autologon")
        }

        // FIDO/passkey handling
        if urlString.contains("/fido/get") || urlString.contains("/fido2/") {
            ssoLog("[DECISION] Allowing FIDO (Platform SSO)")
            navigationLog.append("[DECISION] FIDO")
            scheduleFidoTimeout()
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let urlString = url.absoluteString

        isLoading = false
        isNavigating = false
        currentUrl = urlString

        ssoLog("[NAV] Finished: \(urlString)")
        navigationLog.append("[NAV] \(url.host ?? "?")\(url.path)")

        // Auto-fill Entra login page
        if let host = url.host, host.contains("login.microsoftonline.com") {
            autoFillEntraLogin()
        }

        // Detect FIDO/passkey pages (SPA transitions don't trigger decidePolicyFor)
        Task {
            if let pageText = try? await webView.evaluateJavaScript("document.body.innerText") as? String {
                if pageText.contains("passkey") || pageText.contains("security key") || pageText.contains("FIDO") {
                    scheduleFidoTimeout()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isNavigating = true
        if let url = webView.url {
            currentUrl = url.absoluteString
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        let logMsg = "[NAV] Failed: \(error.localizedDescription)"
        ssoLog(logMsg)
        navigationLog.append(logMsg)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // NSURLErrorCancelled is not a real error (e.g., redirect interception)
        if (error as NSError).code == NSURLErrorCancelled { return }
        isNavigating = false
        let logMsg = "[NAV] Provisional failed: \(error.localizedDescription)"
        ssoLog(logMsg)
        navigationLog.append(logMsg)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let authMethod = challenge.protectionSpace.authenticationMethod

        if authMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // Negotiate (Kerberos) / NTLM — use default handling (system credentials)
        if authMethod == NSURLAuthenticationMethodNegotiate ||
           authMethod == NSURLAuthenticationMethodNTLM {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
