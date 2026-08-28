import Foundation
import Security

// MARK: - macOS Keychain helpers

private let keychainService = "FleetMate"
private let keychainAccount = "github-token"

private func keychainRead() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

private func keychainWrite(_ token: String) {
    guard let data = token.data(using: .utf8) else { return }
    let attrs: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecValueData as String: data
    ]
    SecItemDelete(attrs as CFDictionary)
    SecItemAdd(attrs as CFDictionary, nil)
}

// MARK: - GitHubTokenSource

/// Centralized GitHub token resolution for all GitHub API clients.
///
/// Priority order (first source to return a non-empty token wins):
/// 1. **config token** — explicit override in config.yaml; always respected
/// 2. **gh CLI** — `gh auth token`; zero-config on any developer machine; OS-keychain-backed
/// 3. **GITHUB_TOKEN / GH_TOKEN** — environment variables; CI/devcontainers/automation
/// 4. **macOS Keychain** — token persisted from a previous Device Flow session
/// 5. **OAuth Device Flow** — interactive first-run; requires `oauth_client_id` in config;
///    stores the resulting token in Keychain for all future runs
public actor GitHubTokenSource {
    private let config: GitHubProviderConfig
    private var cachedToken: String?

    /// Called during Device Flow with `(user_code, verification_url)`.
    /// Open the URL in a browser and show the code to the user.
    /// Set this at construction time to enable Device Flow.
    public var deviceFlowPrompt: ((String, URL) async -> Void)?

    public init(
        config: GitHubProviderConfig,
        deviceFlowPrompt: ((String, URL) async -> Void)? = nil
    ) {
        self.config = config
        self.deviceFlowPrompt = deviceFlowPrompt
    }

    /// Returns a valid token, trying all sources in priority order.
    /// Returns `nil` if no token could be found or Device Flow was declined/expired.
    public func token() async -> String? {
        if let cached = cachedToken, !cached.isEmpty { return cached }

        // 1. Explicit config token (user override — always wins)
        if let t = config.token, !t.isEmpty { return cache(t) }

        // 2. gh CLI — seamless; wraps OS keychain internally
        if config.useGhCli, let t = await tokenFromGhCli(), !t.isEmpty { return cache(t) }

        // 3. Environment variables (CI / devcontainers)
        if let t = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ??
                   ProcessInfo.processInfo.environment["GH_TOKEN"],
           !t.isEmpty { return cache(t) }

        // 4. macOS Keychain (token stored from a previous Device Flow)
        if let t = keychainRead(), !t.isEmpty { return cache(t) }

        // 5. OAuth Device Flow (interactive first-run)
        if let clientId = config.oauthClientId, !clientId.isEmpty,
           let prompt = deviceFlowPrompt,
           let t = await performDeviceFlow(clientId: clientId, prompt: prompt),
           !t.isEmpty {
            keychainWrite(t)
            return cache(t)
        }

        return nil
    }

    /// Clears the in-memory cached token (call after a 401 to force re-auth).
    public func invalidate() {
        cachedToken = nil
    }

    // MARK: - Private

    private func cache(_ token: String) -> String {
        cachedToken = token
        return token
    }

    /// Asks the `gh` CLI for the current token.
    private func tokenFromGhCli() async -> String? {
        await ProcessRunner.trimmedOutput("gh", ["auth", "token"])
    }

    /// Executes GitHub's OAuth Device Flow.
    /// Calls `prompt` to display the user code, then polls until authorized or expired.
    private func performDeviceFlow(
        clientId: String,
        prompt: (String, URL) async -> Void
    ) async -> String? {
        // Step 1: Request device & user codes
        var codeReq = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        codeReq.httpMethod = "POST"
        codeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        codeReq.setValue("application/json", forHTTPHeaderField: "Accept")
        codeReq.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": clientId,
            "scope": "repo read:org"
        ])

        guard let (codeData, _) = try? await URLSession.shared.data(for: codeReq),
              let codeJson = try? JSONSerialization.jsonObject(with: codeData) as? [String: Any],
              let deviceCode = codeJson["device_code"] as? String,
              let userCode = codeJson["user_code"] as? String,
              let uriStr = codeJson["verification_uri"] as? String,
              let verificationURL = URL(string: uriStr)
        else { return nil }

        let interval = (codeJson["interval"] as? Int) ?? 5
        let expiresIn = (codeJson["expires_in"] as? Int) ?? 900

        // Step 2: Notify caller — open browser, show code
        await prompt(userCode, verificationURL)

        // Step 3: Poll until authorized, denied, or expired
        var pollInterval = interval
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

            var pollReq = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            pollReq.httpMethod = "POST"
            pollReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            pollReq.setValue("application/json", forHTTPHeaderField: "Accept")
            pollReq.httpBody = try? JSONSerialization.data(withJSONObject: [
                "client_id": clientId,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            guard let (pollData, _) = try? await URLSession.shared.data(for: pollReq),
                  let pollJson = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any]
            else { continue }

            if let accessToken = pollJson["access_token"] as? String, !accessToken.isEmpty {
                return accessToken
            }

            switch pollJson["error"] as? String {
            case "slow_down":
                pollInterval += (pollJson["interval"] as? Int) ?? 5
            case "expired_token", "access_denied":
                return nil
            default:
                break // "authorization_pending" — keep polling
            }
        }

        return nil
    }
}
