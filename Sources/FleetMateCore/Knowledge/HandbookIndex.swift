import Foundation

/// One Handbook page, read from FleetMate's copy of the Handbook repository.
public struct HandbookPage: Identifiable, Hashable, Sendable {
    /// Path under the content folder, e.g. `devices/enrollment/cimian.md`.
    public let path: String
    public let title: String
    /// Breadcrumb of section folders: ["devices", "enrollment"].
    public let sections: [String]
    /// Where the page is published, relative to the site root: `/devices/enrollment/cimian/`.
    public let sitePath: String
    public let headings: [String]
    /// The Markdown body with Hugo shortcodes removed.
    public let body: String
    public let lastModified: String?
    public let lastModifiedBy: String?

    public var id: String { path }
    public var breadcrumb: String { sections.map(Self.humanize).joined(separator: " › ") }

    static func humanize(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Every Handbook page, searchable. Built from the Hugo content folder of
/// FleetMate's own always-current copy of the Handbook.
public struct HandbookIndex: Sendable {
    public let pages: [HandbookPage]
    private let lowered: [(title: String, headings: String, path: String, body: String)]

    public init(pages: [HandbookPage]) {
        self.pages = pages
        self.lowered = pages.map {
            ($0.title.lowercased(), $0.headings.joined(separator: "\n").lowercased(),
             $0.path.lowercased(), $0.body.lowercased())
        }
    }

    /// Read every `.md` page under `contentRoot`.
    public static func load(contentRoot: URL) -> HandbookIndex {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: contentRoot, includingPropertiesForKeys: nil) else { return HandbookIndex(pages: []) }
        var pages: [HandbookPage] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(contentRoot.path.count + 1))
            if let page = page(relativePath: relative, text: text) { pages.append(page) }
        }
        return HandbookIndex(pages: pages.sorted { $0.path < $1.path })
    }

    static func page(relativePath: String, text: String) -> HandbookPage? {
        let (fields, rawBody) = FrontMatter.split(text)
        var components = relativePath.split(separator: "/").map(String.init)
        guard let file = components.popLast() else { return nil }
        let isIndex = file == "_index.md" || file == "index.md"
        // Separators and other title-less stubs are navigation, not pages.
        guard let title = fields["title"], !title.isEmpty else { return nil }
        let slug = fields["slug"] ?? String(file.dropLast(3))
        let sitePath = "/" + (isIndex ? components : components + [slug]).joined(separator: "/") + (components.isEmpty && isIndex ? "" : "/")
        let body = rawBody
            .replacingOccurrences(of: #"\{\{[<%].*?[%>]\}\}"#, with: "", options: .regularExpression)
        let headings = body.split(separator: "\n")
            .filter { $0.hasPrefix("#") }
            .map { $0.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
        return HandbookPage(path: relativePath, title: title, sections: components, sitePath: sitePath,
                            headings: headings, body: body,
                            lastModified: fields["lastmod_date"] ?? fields["lastmod"] ?? fields["date"],
                            lastModifiedBy: fields["lastmod_by"])
    }

    /// Pages for a typed query: every word must appear somewhere; titles
    /// count most, then headings, path, and body.
    public func search(_ query: String, limit: Int = 8) -> [HandbookPage] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        var scored: [(Int, Int)] = []
        for (i, l) in lowered.enumerated() {
            var total = 0
            var allFound = true
            for word in words {
                let s = (l.title.contains(word) ? 12 : 0) + (l.headings.contains(word) ? 5 : 0)
                    + (l.path.contains(word) ? 3 : 0) + (l.body.contains(word) ? 1 : 0)
                if s == 0 { allFound = false; break }
                total += s
            }
            if allFound { scored.append((i, total)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { pages[$0.0] }
    }

    /// Pages about a thing, given the words that describe it — a model,
    /// a platform, a repository name. Unlike `search`, any term may match;
    /// a page needs a title or heading hit to count, so a passing mention in
    /// a long page does not surface it.
    public func related(to terms: [String], limit: Int = 5) -> [HandbookPage] {
        let wanted = Set(terms.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })
        guard !wanted.isEmpty else { return [] }
        var scored: [(Int, Int)] = []
        for (i, l) in lowered.enumerated() {
            var strong = 0, weak = 0, distinct = 0
            for term in wanted {
                let hit = (l.title.contains(term) ? 10 : 0) + (l.headings.contains(term) ? 4 : 0)
                    + (l.path.contains(term) ? 3 : 0)
                if hit > 0 { distinct += 1 }
                strong += hit
                if l.body.contains(term) { weak += 1 }
            }
            // Pages that touch more of the item's terms beat pages that
            // repeat one of them.
            if strong > 0 { scored.append((i, distinct * 100 + strong + weak)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { pages[$0.0] }
    }
}
