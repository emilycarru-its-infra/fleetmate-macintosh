import Foundation

/// Links and text in Teams search results come from message content, which
/// anyone in a channel can write. Before the app opens a link or shows a
/// name, it goes through here.
public enum TeamsLinkPolicy {
    /// Hosts allowed by default: Teams itself and SharePoint, where channel
    /// files live. A leading `*.` allows subdomains only.
    public static let defaultHosts = ["teams.microsoft.com", "teams.cloud.microsoft", "*.sharepoint.com"]

    /// The allowed host patterns: the defaults plus any configured extras.
    /// A bare configured domain (`example.edu`) allows itself and its
    /// subdomains.
    public static func hosts(extra: String?) -> [String] {
        let configured = (extra ?? "")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        return defaultHosts + configured
    }

    /// The URL, only when it is https and its host is allowed; nil otherwise,
    /// and the caller shows the text instead of a link.
    public static func safeURL(_ string: String?, allowedHosts: [String]) -> URL? {
        guard let string,
              let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              let url = components.url
        else { return nil }
        return allowedHosts.contains { matches(host: host, pattern: $0) } ? url : nil
    }

    static func matches(host: String, pattern: String) -> Bool {
        let pattern = pattern.lowercased()
        if pattern.hasPrefix("*.") {
            let domain = String(pattern.dropFirst(2))
            return host.hasSuffix("." + domain)
        }
        if pattern == "teams.microsoft.com" || pattern == "teams.cloud.microsoft" {
            return host == pattern
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}

extension TeamsText {
    /// A name or title for one line: control and format characters removed
    /// (bidirectional overrides, zero-width characters, line breaks) and
    /// whitespace collapsed.
    public static func line(_ value: String?) -> String {
        oneLine(value ?? "")
    }

    /// Message text with the same characters removed, line breaks and tabs kept.
    public static func body(_ value: String?) -> String {
        terminalSafe(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
