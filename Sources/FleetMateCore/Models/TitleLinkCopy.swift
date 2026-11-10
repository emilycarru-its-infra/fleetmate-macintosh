import Foundation

/// Plain text for terminals and an HTML anchor for rich-text destinations.
public struct TitleLinkCopy: Sendable {
    public let text: String
    public let html: String

    public init?(title: String, link: String) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        text = title + "\n" + url.absoluteString
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        html = "<a href=\"" + escape(url.absoluteString) + "\">" + escape(title) + "</a>"
    }
}
