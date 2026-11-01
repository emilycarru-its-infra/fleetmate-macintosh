import Foundation
import AppKit
import WebKit

/// The silent TDX sign-in, with no window the user can see, usable from both
/// the app and the command-line tool.
///
/// It tries, in order: the device's PRT cookie from the Entra broker, the
/// silent URLSession chain, then a WKWebView in an off-screen window. It never
/// shows a sign-in page. A result whose identity was refused is final.
@MainActor
public enum TdxHeadlessSignIn {

    /// Run the chain and return the outcome, or nil if every step failed.
    ///
    /// - Parameter upn: the address the session must belong to. When given it
    ///   seeds `TdxSsoLoginViewModel.fallbackUpn`, which Entra needs to advance
    ///   and the identity check compares against.
    public static func run(config: FleetMateConfig, upn: String? = nil, timeout: TimeInterval = 95) async -> TdxSsoResult? {
        TdxSsoLoginViewModel.fallbackUpn = upn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // A command-line process has no NSApplication until something asks
        // for one, and an NSWindow needs it. Prohibited keeps it out of the Dock.
        if NSApp == nil {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }

        await primePrtCookies(config: config)

        let silent = TdxSsoLoginViewModel(config: config)
        if await silent.performSilentAuthentication(), let result = silent.authResult, result.success, result.token != nil {
            dbg.info("[SSO headless] Silent chain succeeded — user=\(result.userName ?? "unknown")", category: "tdx-sso")
            return result
        }
        if let result = silent.authResult, result.isIdentityRefused {
            return result
        }

        dbg.info("[SSO headless] Silent chain failed — trying the hidden web view", category: "tdx-sso")
        let viewModel = TdxSsoLoginViewModel(config: config)
        let window = NSWindow(
            contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.orderOut(nil)
        window.contentView = viewModel.webView
        viewModel.webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        defer { window.close() }

        viewModel.startAuthentication()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = viewModel.authResult {
                if result.success, result.token != nil {
                    dbg.info("[SSO headless] Hidden web view succeeded — user=\(result.userName ?? "unknown")", category: "tdx-sso")
                }
                return result
            }
            await pump()
        }
        dbg.warn("[SSO headless] Hidden web view timed out after \(Int(timeout))s", category: "tdx-sso")
        return nil
    }

    /// Hand a successful result to `service` the same way the app does: a JWT
    /// as a token, anything else as the cookie session left in shared storage.
    public static func apply(_ result: TdxSsoResult, to service: TdxService, config: FleetMateConfig) {
        if result.isIdentityRefused {
            service.refuseSso(reason: result.error ?? "TeamDynamix identity could not be confirmed")
            return
        }
        guard result.success, let token = result.token, !token.isEmpty else {
            service.refuseSso(reason: result.error ?? "Silent TeamDynamix sign-in failed")
            return
        }
        let expiry = TdxCliSessionCache.tokenExpiry(token) ?? Date().addingTimeInterval(23 * 60 * 60)
        guard expiry > Date() else {
            service.refuseSso(reason: "TeamDynamix returned an expired session")
            return
        }
        if token.hasPrefix("eyJ"), token.split(separator: ".").count == 3 {
            service.setSsoToken(token, expiry: expiry, userId: result.userEmail, userName: result.userName)
        } else if let base = config.tdxBaseUrl, let url = URL(string: base),
                  let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            service.setSsoCookies(cookies, userName: result.userName)
        } else {
            service.refuseSso(reason: "TeamDynamix returned no usable user session")
        }
    }

    /// Put the device's Entra PRT cookie into shared cookie storage so the
    /// silent SAML chain authenticates without a prompt.
    public static func primePrtCookies(config: FleetMateConfig) async {
        guard let url = URL(string: "https://login.microsoftonline.com/\(config.effectiveAzureTenantId)/saml2") else { return }
        let cookies = await EntraPrtCookieProvider().ssoCookies(for: url)
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        if !cookies.isEmpty {
            dbg.info("[PRT] Installed \(cookies.count) PRT cookie(s) for the silent SAML chain", category: "tdx-sso")
        }
    }

    /// Let WebKit make progress. Inside the app the main run loop is already
    /// turning; a command-line process only has the main queue, so spin the
    /// run loop by hand there.
    private static func pump() async {
        if NSApp?.isRunning == true {
            try? await Task.sleep(nanoseconds: 250_000_000)
        } else {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
            await Task.yield()
        }
    }
}
