import SwiftUI
import WebKit
import FleetMateCore
import AuthenticationServices

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

// MARK: - SAML Form Data

/// Parsed SAML auto-submit form (SAMLResponse + RelayState) extracted from HTML.
struct SamlFormData {
    let actionUrl: URL
    let fields: [String: String]
}

// MARK: - SAML Form Interceptor

/// Handles intercepted SAML form submissions from WKWebView.
/// WKWebView silently strips POST bodies on cross-origin form submissions,
/// so we intercept the SAML assertion and submit it via URLSession instead.
class SamlMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewModel: TdxSsoLoginViewModel?
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let viewModel = viewModel else { return }
        Task { @MainActor in
            viewModel.handleSamlInterception(message)
        }
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
    
    /// Log a message to both console and the unified log (visible via `log show`)
    private func ssoLog(_ message: String) {
        let full = "[TdxSsoLogin] \(message)"
        print(full)
        NSLog("%@", full)
    }
    
    /// Log a message from a static context (for background detection)
    nonisolated private static func ssoLogStatic(_ message: String) {
        let full = "[TdxSsoLogin] \(message)"
        print(full)
        NSLog("%@", full)
    }
    
    let webView: WKWebView
    let ssoService: TdxSsoService
    private let config: FleetMateConfig
    private var urlSession: URLSession?
    private var samlHandler: SamlMessageHandler?
    /// Timestamp when a FIDO/passkey page was first loaded.
    /// Used for timeout-based fallback: if Platform SSO doesn't complete
    /// the FIDO ceremony within `fidoTimeoutSeconds`, inject fallback scripts.
    private var fidoPageLoadedAt: Date?
    /// Whether the FIDO timeout fallback has already been injected
    private var fidoFallbackInjected = false
    /// How long to wait for Platform SSO to complete FIDO before falling back (seconds)
    private let fidoTimeoutSeconds: TimeInterval = 2
    /// Whether the Enterprise SSO Extension is available on this system
    private var ssoExtensionAvailable = false
    /// The user's Platform SSO UPN (e.g. user@domain.ca), detected from macOS identity
    private var platformSsoUpn: String? {
        didSet {
            // When UPN becomes available, check if we're already on the Entra page
            // and need to auto-fill. This handles the race where the page loaded
            // before app-sso detection completed.
            if let upn = platformSsoUpn, !upn.isEmpty, !usernameAutoFilled {
                if let host = webView.url?.host, host.contains("login.microsoftonline.com") {
                    let logMsg = "[PSSO] UPN now available (\(upn)) — triggering auto-fill on current page"
                    ssoLog(logMsg)
                    navigationLog.append(logMsg)
                    autoFillEntraLogin()
                }
            }
        }
    }
    /// Whether we've already auto-submitted the username on the Entra sign-in page
    private var usernameAutoFilled = false
    
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
    
    /// JavaScript injected at document-start to intercept SAML form submissions.
    /// WKWebView drops POST bodies on cross-origin requests, so we capture
    /// the SAMLResponse + RelayState and handle the POST natively.
    private static let samlInterceptorScript = """
    (function() {
        var originalSubmit = HTMLFormElement.prototype.submit;
        HTMLFormElement.prototype.submit = function() {
            var action = this.action || '';
            if (action.indexOf('Shibboleth.sso') !== -1 || action.indexOf('SAML2/POST') !== -1) {
                var formData = {};
                for (var i = 0; i < this.elements.length; i++) {
                    var el = this.elements[i];
                    if (el.name && el.name.length > 0) {
                        formData[el.name] = el.value;
                    }
                }
                try {
                    window.webkit.messageHandlers.samlInterceptor.postMessage({
                        action: action,
                        data: formData
                    });
                } catch(e) {
                    originalSubmit.call(this);
                }
                return;
            }
            originalSubmit.call(this);
        };
    })();
    """
    
    /// JavaScript injected as a fallback when the SSO Extension can't complete the
    /// FIDO/passkey ceremony. Handles three scenarios:
    /// 1. "Sign in another way" link on FIDO or error pages — always preferred
    /// 2. Method selection page — picks a non-FIDO method (Authenticator, SMS, etc.)
    /// 3. "Back" button as last resort on error pages
    /// NEVER clicks "Try again" — that retries the failing passkey in a loop.
    private static let fidoFallbackScript = """
    (function() {
        if (window.__fleetmateFidoFallback) return;
        window.__fleetmateFidoFallback = true;
        var acted = false;
        function tryFallback() {
            if (acted) return true;
            var bodyText = (document.body && document.body.innerText) || '';
            var isErrorPage = bodyText.indexOf("couldn\u{2019}t sign you in") !== -1 ||
                              bodyText.indexOf("couldn't sign you in") !== -1 ||
                              bodyText.indexOf("sign-in was unsuccessful") !== -1 ||
                              bodyText.indexOf("Something went wrong") !== -1 ||
                              bodyText.indexOf("couldn't verify") !== -1 ||
                              bodyText.indexOf("error occurred") !== -1;
            var isFidoPage = bodyText.indexOf('passkey') !== -1 ||
                             bodyText.indexOf('security key') !== -1 ||
                             bodyText.indexOf('FIDO') !== -1;
            if (!isErrorPage && !isFidoPage) return false;
            var elems = document.querySelectorAll('a, button, [role="link"], [role="button"], input[type="submit"], span, div[tabindex]');
            // Priority 1: Click "Sign in another way" — best escape from passkey flow
            for (var i = 0; i < elems.length; i++) {
                var text = (elems[i].textContent || elems[i].value || '').trim().toLowerCase();
                if (text.indexOf('sign in another way') !== -1 ||
                    text.indexOf('other ways to sign in') !== -1 ||
                    text.indexOf('use another method') !== -1 ||
                    text.indexOf('use a different method') !== -1 ||
                    text.indexOf('try another way') !== -1 ||
                    text.indexOf('try a different way') !== -1 ||
                    text.indexOf("i can't use") !== -1) {
                    console.log('[FleetMate] FIDO fallback - clicking: ' + text);
                    elems[i].click();
                    acted = true;
                    return true;
                }
            }
            // Priority 2: Select a non-FIDO auth method tile
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
                                        btns[j].click();
                                        break;
                                    }
                                }
                            }, 500);
                            return true;
                        }
                    }
                }
            }
            // Priority 3: "Back" on error pages only (goes back to username/method selection)
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
            setTimeout(function() { observer.disconnect(); }, 15000);
        }
        var delays = [100, 300, 600, 1000, 1500, 2500, 4000, 6000, 8000, 10000];
        delays.forEach(function(d) { setTimeout(tryFallback, d); });
    })();
    """
    
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
        
        // Start UPN detection on a background thread immediately.
        // This runs `app-sso platform -s` off the main thread so it doesn't
        // block SwiftUI's AttributeGraph. The result will be available
        // before the WebView reaches login.microsoftonline.com.
        Task { [weak self] in
            let upn = await Self.detectPlatformSsoUpn()
            await MainActor.run {
                self?.platformSsoUpn = upn
            }
        }
        
        // Set up SAML form interception (fixes WKWebView cross-origin POST issue)
        setupSamlInterception()
        
        // Sync cookies from shared storage to WKWebView
        Task {
            await syncCookiesToWebView()
        }
    }
    
    private func setupSamlInterception() {
        let samlScript = WKUserScript(
            source: Self.samlInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        
        let handler = SamlMessageHandler()
        handler.viewModel = self
        self.samlHandler = handler
        
        // Only inject the SAML interceptor — let Platform SSO / WebAuthn work natively.
        // FIDO fallback scripts are injected on-demand after a timeout if PSSO isn't available.
        webView.configuration.userContentController.addUserScript(samlScript)
        webView.configuration.userContentController.add(handler, name: "samlInterceptor")
        
        print("[TdxSsoLogin] SAML interceptor installed (WebAuthn/FIDO allowed for Platform SSO)")
    }
    
    /// Detect the current user's Platform SSO UPN via `app-sso platform -s`.
    /// Parses the AD TGT ticket entry to find the user's UPN.
    /// Runs on a background thread to avoid blocking the main/UI thread.
    /// Returns the UPN (e.g. "user@domain.ca") or nil if not enrolled.
    private static func detectPlatformSsoUpn() async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/app-sso")
                process.arguments = ["platform", "-s"]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Self.ssoLogStatic("[PSSO] Failed to run app-sso platform -s: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Parse the output for UPN entries.
                // The AD TGT ticket has ticketKeyPath "tgt_ad" and a clean UPN.
                // We skip Kerberos-format UPNs (contain KERBEROS.MICROSOFTONLINE.COM).
                var bestUpn: String?
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Match lines like:  upn = "user@DOMAIN.CA"  or  "upn" : "user@DOMAIN.CA"
                    if trimmed.contains("upn") {
                        // Extract the quoted value after upn
                        if let range = trimmed.range(of: #""([^"]+@[^"]+)""#, options: .regularExpression) {
                            let candidate = String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            // Skip Kerberos-format entries
                            if candidate.uppercased().contains("KERBEROS.MICROSOFTONLINE.COM") {
                                continue
                            }
                            if candidate.contains("@") {
                                bestUpn = candidate.lowercased()
                            }
                        }
                    }
                }
                
                if let upn = bestUpn {
                    Self.ssoLogStatic("[PSSO] Detected Platform SSO UPN: \(upn)")
                    continuation.resume(returning: upn)
                } else {
                    Self.ssoLogStatic("[PSSO] No Platform SSO UPN found in app-sso output")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Generate JavaScript to auto-fill the username on the Entra sign-in page
    /// and click "Next" to proceed through SSO.
    private static func entraAutoLoginScript(upn: String) -> String {
        // Escape the UPN for safe embedding in JavaScript
        let escapedUpn = upn
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        
        return """
        (function() {
            var filled = false;
            function tryAutoLogin() {
                if (filled) return;
                // Find the username input field
                var input = document.querySelector('input[name="loginfmt"]');
                if (!input) input = document.querySelector('input[type="email"]');
                if (!input) return;
                
                // Set the value using native input setter to trigger React/Angular change detection
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                nativeSetter.call(input, '\(escapedUpn)');
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                
                filled = true;
                console.log('[FleetMate] Auto-filled username: \(escapedUpn)');
                
                // Click the Next button after a brief delay for the form to process
                setTimeout(function() {
                    var nextBtn = document.querySelector('input[type="submit"]');
                    if (!nextBtn) nextBtn = document.querySelector('button[type="submit"]');
                    if (!nextBtn) {
                        // Try finding by value/text
                        var btns = document.querySelectorAll('input, button');
                        for (var i = 0; i < btns.length; i++) {
                            var t = (btns[i].value || btns[i].textContent || '').trim().toLowerCase();
                            if (t === 'next' || t === 'sign in') {
                                nextBtn = btns[i];
                                break;
                            }
                        }
                    }
                    if (nextBtn) {
                        console.log('[FleetMate] Clicking Next button');
                        nextBtn.click();
                    }
                    // After submitting username, watch for passkey error pages
                    // (SPA transitions don't trigger WKWebView navigation events)
                    window.__fleetmateFidoFallback = false;
                    setTimeout(function() {
                        try { eval(window.__fleetmateFidoScript || ''); } catch(e) {}
                    }, 3000);
                }, 300);
            }
            
            // Try immediately, then retry with delays in case the form renders asynchronously
            tryAutoLogin();
            [200, 500, 1000, 2000].forEach(function(d) {
                setTimeout(tryAutoLogin, d);
            });
            
            // Also watch for DOM changes
            if (document.body) {
                var observer = new MutationObserver(function() { tryAutoLogin(); });
                observer.observe(document.body, { childList: true, subtree: true });
                // Auto-disconnect after 5 seconds
                setTimeout(function() { observer.disconnect(); }, 5000);
            }
        })();
        """
    }
    
    /// Inject the auto-login script on the Entra sign-in page.
    /// Called from multiple trigger points (didFinish, navigationResponse, etc.)
    /// to ensure it fires regardless of how the page loads.
    private func autoFillEntraLogin() {
        guard !usernameAutoFilled else { return }
        guard let upn = platformSsoUpn else {
            let logMsg = "[PSSO] No UPN available yet for auto-login — will retry when UPN is detected"
            print("[TdxSsoLogin] \(logMsg)")
            navigationLog.append(logMsg)
            // Schedule a retry — UPN detection may still be running
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                if !self.usernameAutoFilled, self.platformSsoUpn != nil {
                    self.autoFillEntraLogin()
                }
            }
            return
        }
        
        usernameAutoFilled = true
        let logMsg = "[PSSO] Auto-filling Entra sign-in with: \(upn)"
        ssoLog(logMsg)
        navigationLog.append(logMsg)
        
        let script = Self.entraAutoLoginScript(upn: upn)
        // Inject immediately, then retry with delays for SPA rendering
        Task {
            _ = try? await webView.evaluateJavaScript(script)
            // Retry after delays in case the form wasn't rendered yet
            for delay in [500, 1000, 2000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                _ = try? await webView.evaluateJavaScript(script)
            }
            
            // After username submission, proactively inject FIDO fallback.
            // The passkey challenge often happens as an SPA transition that
            // doesn't trigger WKWebView navigation events.
            ssoLog("[PSSO] Scheduling FIDO fallback injection after auto-fill")
            scheduleFidoTimeout()
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s for passkey to fail
            if self.authResult == nil {
                ssoLog("[PSSO] Injecting FIDO fallback after auto-fill timeout")
                _ = try? await webView.evaluateJavaScript(Self.fidoFallbackScript)
            }
        }
    }
    
    /// Detect if the Microsoft Enterprise SSO Extension is available.
    /// Uses ASAuthorizationSingleSignOnProvider to check for the Entra IdP.
    private func detectSsoExtension() {
        let entraUrl = URL(string: "https://login.microsoftonline.com")!
        let provider = ASAuthorizationSingleSignOnProvider(identityProvider: entraUrl)
        // If canPerformAuthorization is true, the SSO Extension is registered
        ssoExtensionAvailable = provider.canPerformAuthorization
        let status = ssoExtensionAvailable ? "available" : "not available"
        let logMsg = "[PSSO] Enterprise SSO Extension: \(status)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        if !ssoExtensionAvailable {
            let warnMsg = "[PSSO] Platform SSO not available — FIDO will timeout after \(Int(fidoTimeoutSeconds))s and fall back to interactive auth"
            print("[TdxSsoLogin] \(warnMsg)")
            navigationLog.append(warnMsg)
        }
    }
    
    /// Inject FIDO fallback scripts when Platform SSO wasn't able to complete the ceremony.
    /// This is called after `fidoTimeoutSeconds` has elapsed on a FIDO page.
    private func injectFidoFallback() {
        guard !fidoFallbackInjected else { return }
        fidoFallbackInjected = true
        
        let logMsg = "[PSSO] FIDO timeout elapsed — injecting fallback auth method selector"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        Task {
            _ = try? await webView.evaluateJavaScript(Self.fidoFallbackScript)
            let doneMsg = "[PSSO] Fallback script injected"
            print("[TdxSsoLogin] \(doneMsg)")
            await MainActor.run { navigationLog.append(doneMsg) }
        }
    }
    
    /// Schedule a FIDO timeout check. If Platform SSO hasn't completed
    /// authentication by the time the timeout fires, inject fallback scripts.
    private func scheduleFidoTimeout() {
        guard fidoPageLoadedAt == nil else { return } // Already scheduled
        fidoPageLoadedAt = Date()
        
        let timeout = fidoTimeoutSeconds
        let logMsg = "[PSSO] FIDO page detected — waiting \(Int(timeout))s for Platform SSO..."
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Check if auth completed while we were waiting
            if authResult == nil && !fidoFallbackInjected {
                injectFidoFallback()
            }
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
    
    // MARK: - SAML Interception Handling
    
    /// Called when JavaScript intercepts a SAML form submission
    func handleSamlInterception(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let actionUrlString = body["action"] as? String,
              let actionUrl = URL(string: actionUrlString),
              let formData = body["data"] as? [String: String] else {
            let logMsg = "[SAML] Invalid intercept message"
            print("[TdxSsoLogin] \(logMsg)")
            navigationLog.append(logMsg)
            return
        }
        
        let logMsg = "[SAML] Intercepted cross-origin form POST → \(actionUrl.host ?? "")\(actionUrl.path)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        let fieldNames = formData.keys.sorted().joined(separator: ", ")
        let dataLog = "[SAML] Form fields: \(fieldNames)"
        print("[TdxSsoLogin] \(dataLog)")
        navigationLog.append(dataLog)
        
        Task {
            await submitSamlViaURLSession(to: actionUrl, formData: formData)
        }
    }
    
    /// Submit the SAML assertion via URLSession (bypasses WKWebView cross-origin POST limitation)
    private func submitSamlViaURLSession(to url: URL, formData: [String: String]) async {
        // Build application/x-www-form-urlencoded body
        let bodyParts = formData.map { key, value in
            "\(Self.formURLEncode(key))=\(Self.formURLEncode(value))"
        }
        let bodyString = bodyParts.joined(separator: "&")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = true
        
        // Sync current WebView cookies to shared storage before the request
        let wkCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in wkCookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
        sessionConfig.httpShouldSetCookies = true
        sessionConfig.httpCookieAcceptPolicy = .always
        
        let delegate = KerberosAuthDelegate()
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        
        do {
            let submitLog = "[SAML] Submitting assertion via URLSession..."
            print("[TdxSsoLogin] \(submitLog)")
            await MainActor.run { navigationLog.append(submitLog) }
            
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run { errorMessage = "Invalid response from identity provider" }
                return
            }
            
            let finalUrl = httpResponse.url ?? url
            let respLog = "[SAML] Response: \(httpResponse.statusCode) → \(finalUrl.absoluteString)"
            print("[TdxSsoLogin] \(respLog)")
            await MainActor.run { navigationLog.append(respLog) }
            
            // Log relevant cookies
            if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
                let cookieNames = cookies.map(\.name).joined(separator: ", ")
                let cookieLog = "[SAML] Cookies for \(url.host ?? ""): \(cookieNames)"
                print("[TdxSsoLogin] \(cookieLog)")
                await MainActor.run { navigationLog.append(cookieLog) }
            }
            
            // Sync all cookies from URLSession to WebView
            if let allCookies = HTTPCookieStorage.shared.cookies {
                let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
                for cookie in allCookies {
                    await cookieStore.setCookie(cookie)
                }
                let syncLog = "[SAML] Synced \(allCookies.count) cookies to WebView"
                print("[TdxSsoLogin] \(syncLog)")
                await MainActor.run { navigationLog.append(syncLog) }
            }
            
            // Check if the SAML redirect chain landed on loginSSO and returned a JWT directly
            if let responseText = String(data: data, encoding: .utf8) {
                let cleanToken = responseText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                
                if cleanToken.hasPrefix("eyJ") && cleanToken.count > 20 {
                    let successLog = "[SAML] ✓ Got JWT directly from SAML redirect chain (\(cleanToken.prefix(20))...)"
                    print("[TdxSsoLogin] \(successLog)")
                    
                    let userInfo = Self.extractUserInfoFromJwt(cleanToken)
                    
                    await MainActor.run {
                        navigationLog.append(successLog)
                        
                        if let name = userInfo.name {
                            let userLog = "[JWT] User: \(name) (\(userInfo.email ?? ""))"
                            print("[TdxSsoLogin] \(userLog)")
                            navigationLog.append(userLog)
                        }
                        
                        authResult = TdxSsoResult.success(
                            token: cleanToken,
                            userName: userInfo.name,
                            userEmail: userInfo.email
                        )
                    }
                    return
                }
            }
            
            // Now try to get a JWT bearer token from TDX
            await MainActor.run {
                attemptJwtRetrieval(afterLandingOn: finalUrl)
            }
            
        } catch {
            let errLog = "[SAML] POST error: \(error.localizedDescription)"
            print("[TdxSsoLogin] \(errLog)")
            await MainActor.run {
                navigationLog.append(errLog)
                errorMessage = "SAML authentication failed: \(error.localizedDescription)"
            }
        }
    }
    
    /// After SAML assertion is accepted, call TDX loginSSO to get a JWT bearer token
    private func attemptJwtRetrieval(afterLandingOn landingUrl: URL) {
        let baseUrl = (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseUrl.isEmpty else {
            errorMessage = "TDX base URL not configured"
            return
        }
        
        let loginSsoUrlString = "\(baseUrl)/api/auth/loginSSO"
        guard let loginSsoUrl = URL(string: loginSsoUrlString) else {
            loadFinalPageInWebView(url: landingUrl)
            return
        }
        
        let logMsg = "[JWT] Requesting bearer token from \(loginSsoUrlString)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        Task {
            var request = URLRequest(url: loginSsoUrl)
            request.httpMethod = "GET"
            request.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = true
            
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
            sessionConfig.httpShouldSetCookies = true
            sessionConfig.httpCookieAcceptPolicy = .always
            
            let delegate = KerberosAuthDelegate()
            let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
            
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run { loadFinalPageInWebView(url: landingUrl) }
                    return
                }
                
                let tokenLog = "[JWT] loginSSO response: \(httpResponse.statusCode)"
                print("[TdxSsoLogin] \(tokenLog)")
                await MainActor.run { navigationLog.append(tokenLog) }
                
                if httpResponse.statusCode == 200,
                   let tokenText = String(data: data, encoding: .utf8) {
                    // Token comes back as a quoted JSON string
                    let cleanToken = tokenText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    
                    // Validate it's a JWT (starts with eyJ), not an HTML page
                    if cleanToken.hasPrefix("eyJ") && cleanToken.count > 20 {
                        let successLog = "[JWT] ✓ Got bearer token (\(cleanToken.prefix(20))...)"
                        print("[TdxSsoLogin] \(successLog)")
                        
                        // Try to extract user info from JWT payload
                        let userInfo = Self.extractUserInfoFromJwt(cleanToken)
                        
                        await MainActor.run {
                            navigationLog.append(successLog)
                            
                            if let name = userInfo.name {
                                let userLog = "[JWT] User: \(name) (\(userInfo.email ?? ""))"
                                print("[TdxSsoLogin] \(userLog)")
                                navigationLog.append(userLog)
                            }
                            
                            authResult = TdxSsoResult.success(
                                token: cleanToken,
                                userName: userInfo.name,
                                userEmail: userInfo.email
                            )
                        }
                        return
                    }
                }
                
                // JWT retrieval failed — fall back to cookie-based auth
                let fallbackLog = "[JWT] loginSSO didn't return a valid token, trying cookies"
                print("[TdxSsoLogin] \(fallbackLog)")
                await MainActor.run {
                    navigationLog.append(fallbackLog)
                    loadFinalPageInWebView(url: landingUrl)
                }
                
            } catch {
                let errLog = "[JWT] loginSSO error: \(error.localizedDescription)"
                print("[TdxSsoLogin] \(errLog)")
                await MainActor.run {
                    navigationLog.append(errLog)
                    loadFinalPageInWebView(url: landingUrl)
                }
            }
        }
    }
    
    /// Fall back to loading TDX in the WebView and extracting auth from cookies/page
    private func loadFinalPageInWebView(url: URL) {
        let logMsg = "[WEBVIEW] Loading authenticated page: \(url.absoluteString)"
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        let request = URLRequest(url: url)
        webView.load(request)
        // didFinish handler will detect success pattern and trigger completeAuthentication()
    }
    
    /// Extract user info from a JWT token's payload
    static func extractUserInfoFromJwt(_ token: String) -> (name: String?, email: String?) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        
        var payload = String(parts[1])
        // Base64URL → Base64 conversion
        payload = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        // Add padding
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        
        let name = json["given_name"] as? String
            ?? json["name"] as? String
            ?? json["unique_name"] as? String
        let email = json["email"] as? String
            ?? json["upn"] as? String
            ?? json["unique_name"] as? String
        
        return (name, email)
    }
    
    /// URL form encoding (application/x-www-form-urlencoded)
    private static func formURLEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._")
        var result = string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
        result = result.replacingOccurrences(of: "%20", with: "+")
        return result
    }
    
    func startAuthentication() {
        isLoading = true
        errorMessage = nil
        navigationLog.removeAll()
        fidoPageLoadedAt = nil
        fidoFallbackInjected = false
        usernameAutoFilled = false
        
        // Detect SSO Extension availability
        detectSsoExtension()
        
        let baseUrl = (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseUrl.isEmpty,
              let loginSsoUrl = URL(string: "\(baseUrl)/api/auth/loginSSO") else {
            errorMessage = "TDX base URL not configured"
            isLoading = false
            return
        }
        
        let logMsg = "[START] Attempting SSO authentication..."
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        
        // Try the full silent SAML flow first — if Platform SSO / SSO Extension
        // can handle auth at the URLSession level, we get a JWT with no WebView.
        Task {
            let gotJwt = await tryFullSilentSamlFlow()
            if !gotJwt {
                await MainActor.run {
                    let logMsg = "[START] Silent flow failed, loading SSO in WebView..."
                    print("[TdxSsoLogin] \(logMsg)")
                    navigationLog.append(logMsg)
                    continueWithWebView(url: loginSsoUrl)
                }
            }
        }
    }
    
    /// Attempt authentication using URLSession only (no WebView, no UI).
    /// Follows the full SAML redirect chain:
    ///   loginSSO → Shibboleth → Entra ID (SSO Extension handles auth) → SAMLResponse → Shibboleth → TDX session → JWT
    /// Returns true if a JWT was obtained silently.
    /// Returns false if interactive auth via WebView is required.
    func performSilentAuthentication() async -> Bool {
        isLoading = true
        errorMessage = nil
        navigationLog.removeAll()
        let logMsg = "[SILENT] Attempting silent SAML chain via URLSession..."
        print("[TdxSsoLogin] \(logMsg)")
        navigationLog.append(logMsg)
        let result = await tryFullSilentSamlFlow()
        isLoading = false
        if !result {
            let failMsg = "[SILENT] Silent SAML flow failed — interactive auth required"
            print("[TdxSsoLogin] \(failMsg)")
            navigationLog.append(failMsg)
        }
        return result
    }

    /// Execute the full SAML SSO flow via URLSession (no WebView).
    /// 1. GET loginSSO — if existing session, returns JWT directly
    /// 2. If redirect chain returns HTML with SAMLResponse, parse & POST it
    /// 3. After Shibboleth session is established, GET loginSSO again for JWT
    /// The Enterprise SSO Extension handles Entra ID auth at the network layer.
    private func tryFullSilentSamlFlow() async -> Bool {
        let baseUrl = (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseUrl.isEmpty else { return false }
        
        let rootUrl = baseUrl.replacingOccurrences(of: "/TDWebApi", with: "")
        guard let entryUrl = URL(string: "\(rootUrl)/TDWorkManagement/"),
              let loginSsoUrl = URL(string: "\(baseUrl)/api/auth/loginSSO") else { return false }
        
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
        sessionConfig.httpShouldSetCookies = true
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.timeoutIntervalForRequest = 15
        
        let delegate = KerberosAuthDelegate()
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        
        // ── Step 1: Quick check — does loginSSO already have a session? ──
        do {
            var req = URLRequest(url: loginSsoUrl)
            req.httpMethod = "GET"
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.httpShouldHandleCookies = true
            
            let (data, response) = try await session.data(for: req)
            if let jwt = Self.extractJwtFromResponse(data: data, response: response) {
                let logMsg = "[SILENT] ✓ JWT from existing session"
                print("[TdxSsoLogin] \(logMsg)")
                await MainActor.run { navigationLog.append(logMsg) }
                await handleSilentJwt(jwt)
                return true
            }
            
            // Check if the response already contains a SAMLResponse form
            if let html = String(data: data, encoding: .utf8),
               let saml = Self.parseSamlForm(html: html) {
                let logMsg = "[SILENT] SAMLResponse found in loginSSO response — posting to Shibboleth"
                print("[TdxSsoLogin] \(logMsg)")
                await MainActor.run { navigationLog.append(logMsg) }
                return await postSamlAndFetchJwt(session: session, saml: saml, loginSsoUrl: loginSsoUrl, userAgent: userAgent)
            }
            
            let logMsg = "[SILENT] loginSSO did not return JWT or SAML — trying entry URL"
            print("[TdxSsoLogin] \(logMsg)")
            await MainActor.run { navigationLog.append(logMsg) }
        } catch {
            let logMsg = "[SILENT] loginSSO error: \(error.localizedDescription)"
            print("[TdxSsoLogin] \(logMsg)")
            await MainActor.run { navigationLog.append(logMsg) }
        }
        
        // ── Step 2: Navigate the full SAML chain starting from TDWorkManagement ──
        do {
            var req = URLRequest(url: entryUrl)
            req.httpMethod = "GET"
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.httpShouldHandleCookies = true
            
            let logMsg = "[SILENT] GET \(entryUrl.absoluteString) (following SAML redirects...)"
            print("[TdxSsoLogin] \(logMsg)")
            await MainActor.run { navigationLog.append(logMsg) }
            
            let (data, response) = try await session.data(for: req)
            
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            let finalUrl = httpResponse.url ?? entryUrl
            let statusLog = "[SILENT] Response: \(httpResponse.statusCode) → \(finalUrl.absoluteString)"
            print("[TdxSsoLogin] \(statusLog)")
            await MainActor.run { navigationLog.append(statusLog) }
            
            guard let html = String(data: data, encoding: .utf8) else { return false }
            
            // Did the SSO Extension complete auth and we got a SAMLResponse?
            if let saml = Self.parseSamlForm(html: html) {
                let samlLog = "[SILENT] ✓ SAMLResponse captured — posting to \(saml.actionUrl.host ?? "")"
                print("[TdxSsoLogin] \(samlLog)")
                await MainActor.run { navigationLog.append(samlLog) }
                return await postSamlAndFetchJwt(session: session, saml: saml, loginSsoUrl: loginSsoUrl, userAgent: userAgent)
            }
            
            // Did we land on a TDX success page? (session already exists)
            let successPatterns = ["/SBTDClient/", "/TDClient/", "/TDNext/", "/TDWorkManagement/", "/Home/Desktop"]
            if successPatterns.contains(where: { finalUrl.absoluteString.contains($0) }) &&
               !html.contains("login.microsoftonline.com") {
                let successLog = "[SILENT] Landed on TDX success page — fetching JWT"
                print("[TdxSsoLogin] \(successLog)")
                await MainActor.run { navigationLog.append(successLog) }
                return await fetchJwtFromLoginSso(session: session, url: loginSsoUrl, userAgent: userAgent)
            }
            
            // If we're stuck at the Entra login page, silent auth failed
            let snippet = String(html.prefix(500))
            let failLog = "[SILENT] Response not a SAML form or TDX page (snippet: \(snippet.prefix(200))...)"
            print("[TdxSsoLogin] \(failLog)")
            await MainActor.run { navigationLog.append(failLog) }
            return false
            
        } catch {
            let logMsg = "[SILENT] SAML chain error: \(error.localizedDescription)"
            print("[TdxSsoLogin] \(logMsg)")
            await MainActor.run { navigationLog.append(logMsg) }
            return false
        }
    }
    
    /// POST the SAMLResponse to Shibboleth, then fetch the JWT from loginSSO.
    private func postSamlAndFetchJwt(session: URLSession, saml: SamlFormData, loginSsoUrl: URL, userAgent: String) async -> Bool {
        // Build form-encoded body
        let bodyParts = saml.fields.map { key, value in
            "\(Self.formURLEncode(key))=\(Self.formURLEncode(value))"
        }
        let bodyString = bodyParts.joined(separator: "&")
        
        var request = URLRequest(url: saml.actionUrl)
        request.httpMethod = "POST"
        request.httpBody = bodyString.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = true
        
        do {
            let postLog = "[SILENT] POSTing SAMLResponse to \(saml.actionUrl.absoluteString)"
            print("[TdxSsoLogin] \(postLog)")
            await MainActor.run { navigationLog.append(postLog) }
            
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            
            let finalUrl = httpResponse.url ?? saml.actionUrl
            let respLog = "[SILENT] POST response: \(httpResponse.statusCode) → \(finalUrl.absoluteString)"
            print("[TdxSsoLogin] \(respLog)")
            await MainActor.run { navigationLog.append(respLog) }
            
            // Check if the POST response itself returned a JWT (redirect chain ended at loginSSO)
            if let jwt = Self.extractJwtFromResponse(data: data, response: response) {
                let jwtLog = "[SILENT] ✓ JWT from SAML POST redirect chain"
                print("[TdxSsoLogin] \(jwtLog)")
                await MainActor.run { navigationLog.append(jwtLog) }
                await handleSilentJwt(jwt)
                return true
            }
            
            // Shibboleth session established — now fetch JWT
            return await fetchJwtFromLoginSso(session: session, url: loginSsoUrl, userAgent: userAgent)
            
        } catch {
            let errLog = "[SILENT] SAML POST error: \(error.localizedDescription)"
            print("[TdxSsoLogin] \(errLog)")
            await MainActor.run { navigationLog.append(errLog) }
            return false
        }
    }
    
    /// Fetch JWT from the loginSSO endpoint (assumes session cookies are already set).
    private func fetchJwtFromLoginSso(session: URLSession, url: URL, userAgent: String) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = true
        
        do {
            let (data, response) = try await session.data(for: req)
            if let jwt = Self.extractJwtFromResponse(data: data, response: response) {
                let logMsg = "[SILENT] ✓ JWT from loginSSO"
                print("[TdxSsoLogin] \(logMsg)")
                await MainActor.run { navigationLog.append(logMsg) }
                await handleSilentJwt(jwt)
                return true
            }
            
            let logMsg = "[SILENT] loginSSO did not return a JWT after SAML flow"
            print("[TdxSsoLogin] \(logMsg)")
            await MainActor.run { navigationLog.append(logMsg) }
            return false
        } catch {
            let errLog = "[SILENT] loginSSO fetch error: \(error.localizedDescription)"
            print("[TdxSsoLogin] \(errLog)")
            await MainActor.run { navigationLog.append(errLog) }
            return false
        }
    }
    
    /// Extract a JWT from an HTTP response (data + response).
    private static func extractJwtFromResponse(data: Data, response: URLResponse) -> String? {
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        
        let cleanToken = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        
        guard cleanToken.hasPrefix("eyJ"), cleanToken.count > 20 else { return nil }
        return cleanToken
    }
    
    /// Parse an HTML page for a SAML auto-submit form (SAMLResponse + RelayState).
    private static func parseSamlForm(html: String) -> SamlFormData? {
        // Find form action URL
        guard let actionRange = html.range(of: #"<form[^>]+action="([^"]+)"#, options: .regularExpression) else { return nil }
        let actionMatch = String(html[actionRange])
        guard let urlStart = actionMatch.range(of: #"action=""#, options: .regularExpression) else { return nil }
        let actionStr = String(actionMatch[urlStart.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // Decode HTML entities
        let decodedAction = actionStr
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x3a;", with: ":")
            .replacingOccurrences(of: "&#x2f;", with: "/")
        guard let actionUrl = URL(string: decodedAction) else { return nil }
        
        // Extract hidden input fields
        var fields: [String: String] = [:]
        let inputPattern = #"<input[^>]+type="hidden"[^>]*>"#
        let namePattern = #"name="([^"]+)""#
        let valuePattern = #"value="([^"]*)"#
        
        var searchRange = html.startIndex..<html.endIndex
        while let inputRange = html.range(of: inputPattern, options: .regularExpression, range: searchRange) {
            let inputTag = String(html[inputRange])
            if let nameRange = inputTag.range(of: namePattern, options: .regularExpression),
               let valRange = inputTag.range(of: valuePattern, options: .regularExpression) {
                let nameMatch = String(inputTag[nameRange])
                let valMatch = String(inputTag[valRange])
                // Extract the captured group value
                let name = String(nameMatch.dropFirst(6).dropLast(1)) // name="..."
                let value = String(valMatch.dropFirst(7).dropLast(1)) // value="..."
                fields[name] = value
            }
            searchRange = inputRange.upperBound..<html.endIndex
        }
        
        guard fields["SAMLResponse"] != nil else { return nil }
        return SamlFormData(actionUrl: actionUrl, fields: fields)
    }
    
    /// Handle a JWT obtained silently — set authResult.
    private func handleSilentJwt(_ jwt: String) async {
        let userInfo = Self.extractUserInfoFromJwt(jwt)
        let successLog = "[SILENT] ✓ Authenticated: \(userInfo.name ?? "unknown") (\(userInfo.email ?? ""))"
        print("[TdxSsoLogin] \(successLog)")
        await MainActor.run {
            navigationLog.append(successLog)
            authResult = TdxSsoResult.success(
                token: jwt,
                userName: userInfo.name,
                userEmail: userInfo.email
            )
        }
    }
    
    /// Extract JWT from WebView page content (when loginSSO returns JWT as text)
    private func extractJwtFromPageContent() async {
        do {
            guard let pageText = try await webView.evaluateJavaScript("document.body.innerText") as? String else { return }
            let cleanToken = pageText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            
            if cleanToken.hasPrefix("eyJ") && cleanToken.count > 20 {
                let successLog = "[JWT] ✓ Got JWT from page content (\(cleanToken.prefix(20))...)"
                print("[TdxSsoLogin] \(successLog)")
                
                let userInfo = Self.extractUserInfoFromJwt(cleanToken)
                
                await MainActor.run {
                    navigationLog.append(successLog)
                    
                    if let name = userInfo.name {
                        let userLog = "[JWT] User: \(name) (\(userInfo.email ?? ""))"
                        print("[TdxSsoLogin] \(userLog)")
                        navigationLog.append(userLog)
                    }
                    
                    authResult = TdxSsoResult.success(
                        token: cleanToken,
                        userName: userInfo.name,
                        userEmail: userInfo.email
                    )
                }
            } else {
                let logMsg = "[JWT] loginSSO page is not a JWT, waiting for SAML flow..."
                print("[TdxSsoLogin] \(logMsg)")
                await MainActor.run { navigationLog.append(logMsg) }
            }
        } catch {
            // Not a JWT page — SAML interceptor will handle the flow
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
            
            // First, try to get JWT from the loginSSO endpoint (most reliable)
            let baseUrl = (config.tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !baseUrl.isEmpty,
               let loginSsoUrl = URL(string: "\(baseUrl)/api/auth/loginSSO") {
                
                let logMsg = "[JWT] Requesting bearer token from loginSSO"
                print("[TdxSsoLogin] \(logMsg)")
                await MainActor.run { navigationLog.append(logMsg) }
                
                // Get all WebView cookies and sync to shared storage
                let wkCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                for cookie in wkCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                
                var request = URLRequest(url: loginSsoUrl)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = true
                
                let sessionConfig = URLSessionConfiguration.default
                sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
                sessionConfig.httpShouldSetCookies = true
                sessionConfig.httpCookieAcceptPolicy = .always
                
                let delegate = KerberosAuthDelegate()
                let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
                
                do {
                    let (data, _) = try await session.data(for: request)
                    
                    if let tokenText = String(data: data, encoding: .utf8) {
                        let cleanToken = tokenText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        
                        // Validate it's actually a JWT (starts with eyJ), not an HTML page
                        if cleanToken.hasPrefix("eyJ") && cleanToken.count > 20 {
                            let successLog = "[JWT] ✓ Got bearer token (\(cleanToken.prefix(20))...)"
                            print("[TdxSsoLogin] \(successLog)")
                            
                            let userInfo = Self.extractUserInfoFromJwt(cleanToken)
                            
                            await MainActor.run {
                                navigationLog.append(successLog)
                                
                                if let name = userInfo.name {
                                    let userLog = "[JWT] User: \(name) (\(userInfo.email ?? ""))"
                                    print("[TdxSsoLogin] \(userLog)")
                                    navigationLog.append(userLog)
                                }
                                
                                authResult = TdxSsoResult.success(
                                    token: cleanToken,
                                    userName: userInfo.name,
                                    userEmail: userInfo.email
                                )
                            }
                            return
                        } else {
                            let badLog = "[JWT] Response is not a JWT (starts with: \(cleanToken.prefix(30))...)"
                            print("[TdxSsoLogin] \(badLog)")
                            await MainActor.run { navigationLog.append(badLog) }
                        }
                    }
                } catch {
                    let errLog = "[JWT] loginSSO error: \(error.localizedDescription)"
                    print("[TdxSsoLogin] \(errLog)")
                    await MainActor.run { navigationLog.append(errLog) }
                }
            }
            
            // Fallback: Extract token from cookies
            let fallbackLog = "[JWT] Falling back to cookie extraction"
            print("[TdxSsoLogin] \(fallbackLog)")
            await MainActor.run { navigationLog.append(fallbackLog) }
            
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
        if let url = navigationAction.request.url {
            let urlString = url.absoluteString
            
            // Allow autologon (Seamless SSO) and FIDO/passkey URLs to proceed.
            // Platform SSO needs these endpoints to complete silent authentication.
            // The SSO Extension handles the FIDO ceremony via the platform authenticator.
            if urlString.contains("autologon.microsoftazuread-sso.com") {
                let logMsg = "[DECISION] Allowing autologon (Seamless SSO / Platform SSO)"
                print("[TdxSsoLogin] \(logMsg)")
                navigationLog.append(logMsg)
            }
            
            if urlString.contains("/fido/get") || urlString.contains("/fido2/") {
                let logMsg = "[DECISION] Allowing FIDO/passkey (Platform SSO will handle)"
                print("[TdxSsoLogin] \(logMsg)")
                navigationLog.append(logMsg)
                // Start the FIDO timeout — if Platform SSO doesn't complete
                // within the timeout, fallback scripts will be injected
                scheduleFidoTimeout()
            }
            
            // If this is the Shibboleth SAML2/POST, cancel it — our JS interceptor
            // will handle it via the samlInterceptor message handler instead.
            // WKWebView strips POST bodies on cross-origin requests, so we must
            // submit via URLSession.
            if urlString.contains("Shibboleth.sso/SAML2/POST") {
                let logMsg = "[DECISION] Cancelling native POST to Shibboleth (JS interceptor handles it)"
                print("[TdxSsoLogin] \(logMsg)")
                navigationLog.append(logMsg)
                decisionHandler(.cancel)
                return
            }
            
            let logMsg = "[DECISION] Allowing: \(urlString)"
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
            
            // Trigger auto-fill as early as possible when we see the Entra login page
            if let host = url.host, host.contains("login.microsoftonline.com"),
               !usernameAutoFilled {
                let logMsg2 = "[PSSO] Entra page detected in response — scheduling auto-fill"
                ssoLog(logMsg2)
                navigationLog.append(logMsg2)
                // Delay to let the page render before injecting
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                    self.autoFillEntraLogin()
                }
            }
        }
        decisionHandler(.allow)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isNavigating = true
        if let url = webView.url {
            currentUrl = url.host ?? ""
            let logMsg = "[NAV] \(url.absoluteString)"
            ssoLog(logMsg)
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
        ssoLog(logMsg)
        navigationLog.append(logMsg)
        
        // Check if loginSSO returned JWT as page content (when Shibboleth session already exists)
        if url.absoluteString.contains("/api/auth/loginSSO") {
            let jwtLog = "[DONE] Checking if loginSSO returned JWT..."
            print("[TdxSsoLogin] \(jwtLog)")
            navigationLog.append(jwtLog)
            Task {
                await extractJwtFromPageContent()
            }
            return
        }
        
        // On Entra sign-in page: auto-fill username from Platform SSO UPN
        // This is required because WKWebView doesn't get SSO Extension interception
        // on the initial sign-in form — only on Kerberos/Negotiate challenges after
        // the username is submitted and Seamless SSO kicks in.
        if let host = url.host, host.contains("login.microsoftonline.com"),
           !usernameAutoFilled && platformSsoUpn != nil {
            autoFillEntraLogin()
        }
        
        // On FIDO/passkey pages or any Entra page after username submission:
        // inject fallback to handle error pages and redirect to alt auth.
        // The script uses window.__fleetmateFidoFallback to prevent duplicate runs.
        let urlString = url.absoluteString
        if urlString.contains("/fido/") || urlString.contains("/fido2/") {
            scheduleFidoTimeout()
            ssoLog("[FIDO] Injecting fallback on FIDO page")
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Reset guard to allow re-injection on new page
                _ = try? await webView.evaluateJavaScript("window.__fleetmateFidoFallback = false;")
                _ = try? await webView.evaluateJavaScript(Self.fidoFallbackScript)
            }
        }
        
        // On resume pages or any login.microsoftonline.com page after FIDO attempt:
        // inject fallback to handle error pages ("Couldn't sign you in")
        if urlString.contains("/resume") ||
           (urlString.contains("login.microsoftonline.com") && fidoPageLoadedAt != nil) {
            ssoLog("[FIDO] Injecting fallback on resume/error page")
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                _ = try? await webView.evaluateJavaScript("window.__fleetmateFidoFallback = false;")
                _ = try? await webView.evaluateJavaScript(Self.fidoFallbackScript)
            }
        }
        
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
class KerberosAuthDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        
        let authMethod = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        
        print("[KerberosAuth] Challenge: \(authMethod) from \(host)")
        
        // Handle server trust
        if authMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: serverTrust))
            }
        }
        
        // For Kerberos/Negotiate - use default credentials (system Kerberos ticket)
        if authMethod == NSURLAuthenticationMethodNegotiate {
            print("[KerberosAuth] Using default Kerberos credentials")
            return (.performDefaultHandling, nil)
        }
        
        // For NTLM - use default credentials
        if authMethod == NSURLAuthenticationMethodNTLM {
            print("[KerberosAuth] Using default NTLM credentials")
            return (.performDefaultHandling, nil)
        }
        
        // Default handling for other methods
        return (.performDefaultHandling, nil)
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        
        let authMethod = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        
        print("[KerberosAuth] Session challenge: \(authMethod) from \(host)")
        
        // Handle server trust
        if authMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: serverTrust))
            }
        }
        
        // Use default handling for everything else
        return (.performDefaultHandling, nil)
    }
}

// MARK: - Preview

#Preview {
    TdxSsoLoginView(config: FleetMateConfig()) { result in
        print("Auth result: \(result)")
    }
}
