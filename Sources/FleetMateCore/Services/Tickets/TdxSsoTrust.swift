import Foundation

/// Which hosts the TDX single sign-on chain may hand a SAML assertion to, and
/// which pages may hand one over.
///
/// The sign-in runs in a web view that loads pages from the identity
/// provider. The assertion it produces is posted natively with the app's
/// cookies, so a page that could steer that POST could send the session's
/// cookies anywhere. Only the main frame of a page served over https from an
/// allowed identity provider may hand over an assertion, and only to an
/// allowed service provider host over https. Both lists come from settings,
/// with the TDX host and the Microsoft sign-in hosts as defaults.
public struct TdxSsoTrust: Equatable, Sendable {
    /// Microsoft Entra ID's sign-in hosts.
    public static let defaultIdentityProviderHosts: Set<String> = [
        "login.microsoftonline.com",
        "login.microsoft.com",
        "login.windows.net",
        "login.microsoftonline.us",
    ]

    public let serviceProviderHosts: Set<String>
    public let identityProviderHosts: Set<String>

    public init(serviceProviderHosts: Set<String>, identityProviderHosts: Set<String>) {
        self.serviceProviderHosts = Set(serviceProviderHosts.map { $0.lowercased() })
        self.identityProviderHosts = Set(identityProviderHosts.map { $0.lowercased() })
    }

    /// The TDX host plus `tdxSsoServiceProviderHosts`; the Microsoft hosts
    /// plus `tdxSsoIdentityProviderHosts`.
    public init(config: FleetMateConfig) {
        var sp = Set(Self.hosts(config.tdxSsoServiceProviderHosts))
        if let raw = config.tdxBaseUrl?.trimmingCharacters(in: .whitespaces),
           let host = URL(string: raw)?.host?.lowercased(), !host.isEmpty {
            sp.insert(host)
        }
        let idp = Self.defaultIdentityProviderHosts.union(Self.hosts(config.tdxSsoIdentityProviderHosts))
        self.init(serviceProviderHosts: sp, identityProviderHosts: idp)
    }

    /// Whether the assertion may be posted to `url`: https, no credentials
    /// in the URL, and a host on the service provider list exactly.
    public func allowsAssertion(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return serviceProviderHosts.contains(host)
    }

    /// Whether a page served from `scheme://host` may hand over an assertion.
    public func allowsSender(scheme: String, host: String) -> Bool {
        scheme.lowercased() == "https" && identityProviderHosts.contains(host.lowercased())
    }

    /// Whether `url` is the configured loginSSO endpoint, the one place a
    /// bearer token is taken from.
    public static func isLoginSso(_ url: URL, expected: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == expected.host?.lowercased()
            && url.port == expected.port
            && url.path.lowercased() == expected.path.lowercased()
    }

    static func hosts(_ list: [String]?) -> [String] {
        (list ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
