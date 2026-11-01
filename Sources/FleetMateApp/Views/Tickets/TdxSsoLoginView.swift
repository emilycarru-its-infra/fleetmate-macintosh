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
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to TeamDynamix")
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
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading SSO login...")
                .foregroundColor(.secondary)
            
            if !viewModel.currentUrl.isEmpty {
                VStack(spacing: 4) {
                    Text("Current URL:")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    Text(viewModel.currentUrl)
                        .appFont(.caption, design: .monospaced)
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }
            }
            
            if let ssoUrl = viewModel.ssoService.ssoLoginUrl {
                VStack(spacing: 4) {
                    Text("Login endpoint:")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    Text(ssoUrl.absoluteString)
                        .appFont(.caption, design: .monospaced)
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
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                        ForEach(viewModel.navigationLog, id: \.self) { log in
                            Text(log)
                                .appFont(.caption, design: .monospaced)
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

// MARK: - Preview

#if DEBUG
#Preview {
    TdxSsoLoginView(config: FleetMateConfig()) { result in
        print("Auth result: \(result)")
    }
}
#endif
