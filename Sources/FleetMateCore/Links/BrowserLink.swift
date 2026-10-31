import Foundation

/// Web links FleetMate opens in the browser on purpose.
///
/// A managed browser extension can hand Azure DevOps pages back to FleetMate.
/// When FleetMate itself sends one to the browser — "Open in Browser" — that
/// would bounce straight back, so the link carries `fleetmate=browser`, which
/// the extension leaves alone. Every other URL is returned unchanged.
public enum BrowserLink {
    public static let optOutName = "fleetmate"
    public static let optOutValue = "browser"

    public static func forBrowser(_ url: URL) -> URL {
        guard isAzureDevOpsPage(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == optOutName && $0.value == optOutValue }) else { return url }
        items.append(URLQueryItem(name: optOutName, value: optOutValue))
        components.queryItems = items
        return components.url ?? url
    }

    /// Recognised by path shape, as `FleetMateLink.parseWeb` does, so any
    /// Azure DevOps server name works.
    static func isAzureDevOpsPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() != "github.com" else { return false }
        let parts = url.path.split(separator: "/")
        return parts.contains("_git") || parts.contains("_workitems") || parts.contains { $0.hasPrefix("_build") }
    }
}
