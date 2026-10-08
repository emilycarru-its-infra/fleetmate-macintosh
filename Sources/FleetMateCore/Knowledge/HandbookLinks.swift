import Foundation

/// What clicking a link inside Handbook or skill text does.
public enum HandbookLinkAction: Equatable, Sendable {
    case ignore
    case openPage(HandbookPage)
    case openInBrowser(URL)
}

/// The allow-list for links in Handbook and skill text. Content comes from a
/// repository many people edit, so a link is never handed to the system as
/// written: only http and https open, a link to another Handbook page opens
/// in FleetMate's reader, and everything else (file:, smb:, custom app
/// schemes, javascript:, data:, bare paths) is dropped.
public enum HandbookLinks {
    /// Stands in for the site when no address is configured, so relative links still resolve to pages.
    static let placeholderSite = URL(string: "https://handbook.invalid/")!

    public static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// The configured site as an absolute http(s) root ending in "/", or nil.
    public static func siteRoot(_ siteURL: String?) -> URL? {
        guard let text = siteURL?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let withSlash = text.hasSuffix("/") ? text : text + "/"
        guard let root = URL(string: withSlash), isWeb(root) else { return nil }
        return root
    }

    /// The page's address on the site; nil unless it stays an http(s)
    /// address on the site's own host, whatever the catalog or front matter says.
    public static func pageURL(siteURL: String?, page: HandbookPage) -> URL? {
        guard let root = siteRoot(siteURL) else { return nil }
        let path = page.sitePath.drop(while: { $0 == "/" })
        guard !path.hasPrefix("/"), !path.contains(":"), !path.contains("\\"),
              let url = URL(string: String(path), relativeTo: root)?.absoluteURL,
              isWeb(url), url.host?.lowercased() == root.host?.lowercased() else { return nil }
        return url
    }

    /// What clicking `link` on `page` does. Relative links resolve against the page's place on the site.
    public static func classify(_ link: URL, from page: HandbookPage?, index: HandbookIndex?, siteURL: String?) -> HandbookLinkAction {
        let text = link.absoluteString.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { return .ignore }
        // A Windows path or network share is never a link, whatever it resolves to.
        if text.hasPrefix("\\\\") || text.hasPrefix("//") { return .ignore }

        let site = siteRoot(siteURL)
        let root = site ?? placeholderSite
        var base = root
        if let page, let pageBase = URL(string: String(page.sitePath.drop(while: { $0 == "/" })), relativeTo: root)?.absoluteURL,
           isWeb(pageBase) {
            base = pageBase
        }
        let resolved: URL?
        if link.scheme != nil {
            resolved = link
        } else {
            resolved = URL(string: text, relativeTo: base)?.absoluteURL
        }
        guard let url = resolved, isWeb(url) else { return .ignore }

        if url.host?.lowercased() == root.host?.lowercased() {
            if let found = index?.page(bySitePath: url.path) { return .openPage(found) }
            // A site page FleetMate's copy doesn't have: the site itself, when there is one.
            return site != nil ? .openInBrowser(url) : .ignore
        }
        return .openInBrowser(url)
    }

    /// For text that is not a Handbook page (a skill): only http(s) opens, in the browser.
    public static func external(_ link: URL) -> URL? { link.scheme != nil && isWeb(link) ? link : nil }

    /// Images in Handbook and skill text load only over http(s) from the site's own host.
    public static func allowsImage(_ url: URL?, siteURL: String?) -> Bool {
        guard let url, isWeb(url), let host = siteRoot(siteURL)?.host?.lowercased() else { return false }
        return url.host?.lowercased() == host
    }
}

extension HandbookIndex {
    /// The page published at `sitePath`, trailing slash or not.
    public func page(bySitePath sitePath: String) -> HandbookPage? {
        let decoded = sitePath.removingPercentEncoding ?? sitePath
        let wanted = "/" + decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return pages.first { "/" + $0.sitePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == wanted }
    }
}
