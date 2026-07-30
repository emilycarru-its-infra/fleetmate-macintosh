import Foundation
import AuthenticationServices
import FleetMateCore

/// Asks the Microsoft Enterprise SSO plug-in for this device's PRT cookie.
///
/// Why this exists: the plug-in does not passively intercept traffic. A signed,
/// allow-listed app still gets Entra's interactive "Sign in to your account"
/// page from both WKWebView *and* URLSession — proven by log, not assumed. The
/// `AppPrefixAllowList` in the Extensible SSO profile authorises an app to *ask*
/// the broker; it doesn't make the broker act on requests nobody made. MSAL
/// works because it asks. This is that request, made directly.
///
/// The returned `x-ms-RefreshTokenCredential` cookie is what lets Entra
/// recognise the device-bound Primary Refresh Token and complete a SAML sign-in
/// with no prompt and no window — which is the only shape of TDX SSO that meets
/// FleetMate's no-interaction rule.
@MainActor
final class EntraPrtCookieProvider: NSObject {

    /// Entra hosts the plug-in services. Must match a `URLs` entry in the
    /// Extensible SSO payload or the broker won't claim the request.
    private static let identityProvider = URL(string: "https://login.microsoftonline.com")!

    private var continuation: CheckedContinuation<[HTTPCookie], Never>?

    /// Held for the duration of the request. `ASAuthorizationController` does
    /// not retain itself, and a local one deallocates before the broker answers
    /// — which reads exactly like a broker that never responds.
    private var controller: ASAuthorizationController?

    /// The broker may also simply never answer, so the request is raced against
    /// a deadline. Silent SSO is on the launch path; it must not be blockable.
    private let timeout: Duration = .seconds(5)

    /// PRT cookies for `url`, or empty if the broker declines, errors or stalls.
    ///
    /// Never shows UI: `isUserInterfaceEnabled = false` means a broker that
    /// would need to prompt fails instead, which is the correct outcome here.
    func ssoCookies(for url: URL) async -> [HTTPCookie] {
        let cookies = await withTaskGroup(of: [HTTPCookie].self, returning: [HTTPCookie].self) { group in
            group.addTask { @MainActor in await self.requestCookies(for: url) }
            group.addTask { @MainActor in
                try? await Task.sleep(for: self.timeout)
                // Cancelled means the broker already answered. Logging a
                // timeout here anyway would report a stall that never happened.
                guard !Task.isCancelled else { return [] }
                dbg.warn("[PRT] Broker did not answer within \(self.timeout) — continuing without a PRT cookie",
                         category: "tdx-sso")
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        controller = nil
        return cookies
    }

    private func requestCookies(for url: URL) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationSingleSignOnProvider(
                identityProvider: Self.identityProvider
            )
            let request = provider.createRequest()
            // The broker's own operation name, not one of the OpenID cases —
            // this is the request MSAL makes for an embedded webview's PRT.
            request.requestedOperation = ASAuthorization.OpenIDOperation(
                rawValue: "get_sso_cookies"
            )
            request.isUserInterfaceEnabled = false
            request.authorizationOptions = [
                URLQueryItem(name: "sso_url", value: url.absoluteString),
                // 0 asks for the PRT header form (x-ms-RefreshTokenCredential).
                URLQueryItem(name: "types_of_header", value: "0"),
                URLQueryItem(name: "correlation_id", value: UUID().uuidString),
                URLQueryItem(name: "msal_version", value: "1.0"),
            ]

            guard provider.canPerformAuthorization else {
                dbg.warn("[PRT] SSO provider can't perform authorization — extension not handling \(Self.identityProvider.host ?? "")",
                         category: "tdx-sso")
                self.finish(with: [])
                return
            }

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            self.controller = controller
            dbg.info("[PRT] Requesting SSO cookies from the Entra broker for \(url.host ?? "")", category: "tdx-sso")
            controller.performRequests()
        }
    }

    /// One-shot: the delegate can still fire after the deadline, and resuming a
    /// continuation twice traps.
    private func finish(with cookies: [HTTPCookie]) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: cookies)
    }

    /// Turn whatever the broker hands back into cookies.
    ///
    /// The response shape isn't publicly documented, so this reads every place
    /// the cookies are known to travel and logs the rest. Anything unrecognised
    /// shows up in the log rather than being silently dropped.
    private func cookies(from credential: ASAuthorizationSingleSignOnCredential, url: URL) -> [HTTPCookie] {
        var found: [HTTPCookie] = []

        if let response = credential.authenticatedResponse {
            dbg.info("[PRT] Broker responded \(response.statusCode) with \(response.allHeaderFields.count) headers", category: "tdx-sso")
            for (key, value) in response.allHeaderFields {
                let name = String(describing: key)
                dbg.debug("[PRT] header \(name)", category: "tdx-sso")
                guard name.lowercased().contains("refreshtokencredential")
                        || name.lowercased() == "set-cookie" else { continue }
                if let cookie = Self.makeCookie(name: name, value: String(describing: value), url: url) {
                    found.append(cookie)
                }
            }
        } else {
            dbg.warn("[PRT] Broker returned no authenticatedResponse", category: "tdx-sso")
        }

        if found.isEmpty, let state = credential.state {
            dbg.debug("[PRT] credential.state present (\(state.count) chars) but no cookie headers", category: "tdx-sso")
        }
        return found
    }

    private static func makeCookie(name: String, value: String, url: URL) -> HTTPCookie? {
        // Entra reads the PRT off the request as a cookie of the same name as
        // the header the broker returns it in.
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: ".login.microsoftonline.com",
            .path: "/",
            .secure: "TRUE",
        ])
    }
}

extension EntraPrtCookieProvider: ASAuthorizationControllerDelegate {

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationSingleSignOnCredential else {
            dbg.warn("[PRT] Unexpected credential type: \(type(of: authorization.credential))", category: "tdx-sso")
            finish(with: [])
            return
        }
        let url = EntraPrtCookieProvider.identityProvider
        let cookies = self.cookies(from: credential, url: url)
        dbg.info("[PRT] Broker returned \(cookies.count) usable cookie(s)", category: "tdx-sso")
        finish(with: cookies)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        // Expected when the device has no PRT, or when the app isn't allowed to
        // ask. Either way it must not become a prompt.
        let nsError = error as NSError
        dbg.warn("[PRT] Broker request failed: \(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)",
                 category: "tdx-sso")
        finish(with: [])
    }
}
