import Foundation

public struct WorkItemAttachment: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public var id: String { url.absoluteString }

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    /// GitHub embeds uploaded files in issue and comment Markdown, including HTML images.
    public static func github(in markdown: String) -> [WorkItemAttachment] {
        guard let expression = try? NSRegularExpression(pattern: #"https://(?:github\.com/(?:user-attachments/(?:assets|files)/|[^\s/]+/[^\s/]+/(?:files|assets)/)|(?:user-images\.githubusercontent\.com|private-user-images\.githubusercontent\.com|github-production-user-asset-[a-z0-9-]+\.s3\.amazonaws\.com)/)[^\s<>\"')]+"#, options: .caseInsensitive) else { return [] }
        var seen = Set<URL>()
        return expression.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).compactMap { match in
            guard let range = Range(match.range, in: markdown),
                  let url = URL(string: String(markdown[range]).replacingOccurrences(of: "&amp;", with: "&")),
                  seen.insert(url).inserted else { return nil }
            let component = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            return WorkItemAttachment(url: url, name: component.isEmpty ? "Attachment" : component)
        }
    }
}

/// Restricts credentials to the configured provider. Redirects never carry credentials.
public enum AttachmentAccess: Sendable {
    case azureDevOps(organization: URL)
    case github

    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, !url.pathComponents.contains(".."), let host = url.host?.lowercased() else { return false }
        switch self {
        case .azureDevOps(let organization):
            guard host == organization.host?.lowercased() else { return false }
            let base = organization.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let path = url.path.lowercased()
            return path.hasPrefix("/" + base + "/") && path.contains("/_apis/wit/attachments/")
        case .github:
            if host == "github.com" {
                let path = url.path.lowercased()
                return path.hasPrefix("/user-attachments/assets/") || path.hasPrefix("/user-attachments/files/")
                    || path.range(of: #"^/[^/]+/[^/]+/(files|assets)/"#, options: .regularExpression) != nil
            }
            return host == "user-images.githubusercontent.com" || host == "private-user-images.githubusercontent.com"
                || host.range(of: #"^github-production-user-asset-[a-z0-9-]+\.s3\.amazonaws\.com$"#, options: .regularExpression) != nil
        }
    }

    public func mayAuthorize(_ url: URL) -> Bool {
        guard allows(url) else { return false }
        switch self {
        case .azureDevOps: return true
        case .github: return url.host?.lowercased() == "github.com"
        }
    }
}
