import Foundation

/// What rendered rich text (ticket feeds, work item descriptions) may load
/// and open. Ticket HTML comes from anyone who can comment, so a remote image
/// is a tracking pixel until shown otherwise, and a link may name any scheme.
public enum MarkdownContentPolicy {
    /// Links open only in the browser or mail client.
    public static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    public static func allowsLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return linkSchemes.contains(scheme)
    }

    /// Whether an image may load: https only, and from the TDX host, from
    /// `site`, or from anywhere once the person has chosen to load images
    /// from other sites.
    public static func allowsImage(_ url: URL?, tdxBase: URL?, site: String?, allowExternal: Bool) -> Bool {
        guard let url, TdxImageAuthPolicy.mayLoad(url), let host = url.host?.lowercased() else { return false }
        if TdxImageAuthPolicy.sendsTdxCredentials(to: url, tdxBase: tdxBase) { return true }
        if let site, let siteHost = (URL(string: site)?.host ?? site).lowercased() as String?,
           !siteHost.isEmpty, host == siteHost { return true }
        return allowExternal
    }
}
