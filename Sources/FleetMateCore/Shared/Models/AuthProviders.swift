import Foundation

/// Where a connected system's credential comes from. Settings ▸ Authentication
/// shows one card per provider, listing the systems that depend on it, so a
/// single expired sign-in reads as one problem rather than several.
public enum CredentialProvider: String, CaseIterable, Sendable, Identifiable {
    // Declaration order is display order.
    /// Single sign-on with the operator's organizational identity: headless
    /// browser SSO, or an OIDC bearer issued for their own sign-in.
    case browserSso
    /// The operator's own `az` sign-in: delegated tokens, and the trust
    /// anchor for every elevation session.
    case azureCli
    /// The `gh` CLI's sign-in.
    case githubCli
    /// Credentials stored in FleetMate: API keys, tokens, service accounts.
    case storedCredential

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .azureCli: "Azure CLI sign-in"
        case .githubCli: "GitHub CLI sign-in"
        case .browserSso: "Single sign-on"
        case .storedCredential: "Stored credentials"
        }
    }

    public var summary: String {
        switch self {
        case .azureCli: "Your command-line cloud sign-in. Systems below act as you, or through elevation sessions that start from it."
        case .githubCli: "Your command-line code-hosting sign-in, managed by the gh CLI."
        case .browserSso: "Your organizational identity, used silently. No password is stored and actions show as you."
        case .storedCredential: "Keys and service accounts saved in FleetMate. Actions run as that credential, not as you."
        }
    }

    public var icon: String {
        switch self {
        case .azureCli: "terminal"
        case .githubCli: "chevron.left.forwardslash.chevron.right"
        case .browserSso: "person.badge.key"
        case .storedCredential: "key"
        }
    }
}

/// How each system authenticates, for grouping and per-row detail. Pure
/// functions of the configuration, so the grouping is unit-testable.
public enum AuthProviderGrouping {

    /// The provider a system's credential comes from under this configuration.
    public static func provider(for system: AuthSystemId, config: FleetMateConfig) -> CredentialProvider {
        switch system {
        case .intune, .graph, .entra:
            // Elevation and break-glass direct mode both start from `az`;
            // only legacy service-principal secrets are stored here.
            if config.graphUsesAze { return .azureCli }
            let hasSecret = (config.devicesGraphSecret?.isEmpty == false) || (config.systemsGraphSecret?.isEmpty == false)
                || (config.graphClientSecret?.isEmpty == false)
            return hasSecret ? .storedCredential : .azureCli
        case .devops:
            return .azureCli
        case .snipe:
            // An OIDC bearer is single sign-on with your own identity.
            if config.snipeOidcAudience?.isEmpty == false { return .browserSso }
            if config.snipeAuthMethod == .apiKey { return .storedCredential }
            if config.snipeSsoEnabled || config.snipeAuthMethod == .browserSSO { return .browserSso }
            return .storedCredential
        case .tdx:
            switch config.tdxAuthMethod {
            case .serviceAccount, .userPassword: return .storedCredential
            case .browserSSO, .auto: return .browserSso
            }
        case .github:
            return .githubCli
        case .gitea:
            return .storedCredential
        }
    }

    /// The elevation domain a system's calls run in, when it rides an
    /// elevation session rather than the operator's own token.
    public static func elevationDomain(for system: AuthSystemId, config: FleetMateConfig) -> GraphDomain? {
        guard config.graphUsesAze else { return nil }
        switch system {
        case .intune, .graph: return .devices
        case .entra: return .identity
        default: return nil
        }
    }

    /// Group systems by provider, in provider order, each group in the order
    /// given. Providers with no systems are left out, except the Azure CLI,
    /// which is listed whenever anything at all is configured because it is
    /// also how the operator signs in.
    public static func group(_ systems: [AuthSystemId], config: FleetMateConfig) -> [(provider: CredentialProvider, systems: [AuthSystemId])] {
        var buckets: [CredentialProvider: [AuthSystemId]] = [:]
        for system in systems {
            buckets[provider(for: system, config: config), default: []].append(system)
        }
        return CredentialProvider.allCases.compactMap { provider in
            guard let members = buckets[provider], !members.isEmpty else { return nil }
            return (provider, members)
        }
    }

    /// A short description of the method, for the system's row.
    public static func methodDescription(for system: AuthSystemId, config: FleetMateConfig) -> String {
        switch system {
        case .intune, .graph, .entra:
            if config.graphUsesAze { return "Elevation session" }
            return provider(for: system, config: config) == .storedCredential ? "Service principal" : "Your token (direct)"
        case .devops: return "Your token"
        case .snipe:
            if config.snipeOidcAudience?.isEmpty == false { return "OIDC bearer" }
            return provider(for: system, config: config) == .browserSso ? "Browser SSO" : "API key"
        case .tdx:
            switch config.tdxAuthMethod {
            case .serviceAccount: return "Service account"
            case .userPassword: return "Username and password"
            case .browserSSO: return "Browser SSO"
            case .auto: return config.tdxBeid != nil ? "SSO, service account fallback" : "Browser SSO"
            }
        case .github: return "gh token"
        case .gitea: return "API token"
        }
    }
}

/// Who a CLI is signed in as. Parsed from `az account show -o json` and
/// `gh auth status`, shared by the Settings cards and the setup wizard.
public struct CliAccount: Equatable, Sendable {
    public var user: String
    /// "user" or "servicePrincipal" for az; "user" for gh.
    public var type: String
    public var tenantId: String?
    public var subscription: String?

    public init(user: String, type: String = "user", tenantId: String? = nil, subscription: String? = nil) {
        self.user = user
        self.type = type
        self.tenantId = tenantId
        self.subscription = subscription
    }

    public var isServicePrincipal: Bool { type == "servicePrincipal" }
}

public enum CliAccountProbe {
    /// Parse `az account show -o json`. Nil when the output is not an account.
    public static func parseAzAccount(_ json: String) -> CliAccount? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = obj["user"] as? [String: Any],
              let name = user["name"] as? String, !name.isEmpty else { return nil }
        return CliAccount(
            user: name,
            type: user["type"] as? String ?? "user",
            tenantId: obj["tenantId"] as? String,
            subscription: obj["name"] as? String
        )
    }

    /// Parse `gh auth status` (stdout + stderr). Nil when not signed in.
    public static func parseGhStatus(_ output: String) -> CliAccount? {
        guard output.contains("Logged in") else { return nil }
        // "✓ Logged in to github.com account octocat (keyring)"
        // Older gh: "✓ Logged in to github.com as octocat (oauth_token)"
        for line in output.split(whereSeparator: \.isNewline) where line.contains("Logged in") {
            let words = line.split(separator: " ").map(String.init)
            if let i = words.firstIndex(where: { $0 == "account" || $0 == "as" }), i + 1 < words.count {
                return CliAccount(user: words[i + 1])
            }
        }
        return CliAccount(user: "signed in")
    }

    /// Who `az` is signed in as, or nil.
    public static func azAccount() async -> CliAccount? {
        let result = await ProcessRunner.run(ProcessRunner.resolve("az"), ["account", "show", "-o", "json"])
        guard result.succeeded else { return nil }
        return parseAzAccount(result.stdout)
    }

    /// Who `gh` is signed in as, or nil. gh reports on stderr and exits
    /// non-zero when logged out, so both streams are read.
    public static func ghAccount() async -> CliAccount? {
        let result = await ProcessRunner.run(ProcessRunner.resolve("gh"), ["auth", "status", "--active"])
        return parseGhStatus(result.stdout + result.stderr)
    }
}

/// The one status model every authentication row and group uses, so the same
/// condition always reads and colours the same way. Never red: nothing here
/// is an emergency, and orange appears only when the person has to act.
public enum AuthDisplayStatus: Equatable, Sendable {
    /// Being verified, neutral, with a spinner. The optional text says what
    /// is happening ("Starting elevation session…").
    case checking(String?)
    /// Verified and working.
    case valid
    /// Needs the person to sign in; one action button.
    case needsSignIn
    /// Nothing set up, shown grey.
    case notConfigured
    /// Verification failed; the message is shown in full on the row.
    case failed(String)

    public enum Tone: Sendable { case positive, neutral, attention, inactive }

    /// Map a probe state. `.configured` is never terminal: before its first
    /// check it reads as checking, after one it means a sign-in is missing.
    public init(state: AuthTokenState, lastChecked: Date?) {
        switch state {
        case .notConfigured: self = .notConfigured
        case .configured: self = lastChecked == nil ? .checking(nil) : .needsSignIn
        case .authenticating: self = .checking(nil)
        case .valid: self = .valid
        case .expired: self = .needsSignIn
        case .failed(let message): self = .failed(message)
        case .servicePrincipal(let name): self = .failed("Signed in as the service principal \(name), so actions will not show as you.")
        }
    }

    public var label: String {
        switch self {
        case .checking(let text): text ?? "Checking…"
        case .valid: "Valid"
        case .needsSignIn: "Needs sign-in"
        case .notConfigured: "Not configured"
        case .failed: "Failed"
        }
    }

    public var tone: Tone {
        switch self {
        case .checking: .neutral
        case .valid: .positive
        case .needsSignIn, .failed: .attention
        case .notConfigured: .inactive
        }
    }

    public var isChecking: Bool { if case .checking = self { return true }; return false }

    /// The pill for a group: green only when every member is valid; "n of m
    /// need attention" when any must be acted on; otherwise still checking.
    public static func summary(_ members: [AuthDisplayStatus]) -> (label: String, tone: Tone) {
        let active = members.filter { $0 != .notConfigured }
        guard !active.isEmpty else { return ("Not configured", .inactive) }
        let attention = active.filter { $0.tone == .attention }.count
        if attention > 0 {
            return attention == 1 && active.count == 1 ? (active[0].label, .attention) : ("\(attention) of \(active.count) need attention", .attention)
        }
        if active.contains(where: \.isChecking) { return ("Checking…", .neutral) }
        return ("All valid", .positive)
    }
}
