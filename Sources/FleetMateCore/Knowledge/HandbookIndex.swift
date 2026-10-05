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
    /// True when `body` is only the catalog's summary and keywords; the full
    /// text is read from disk when the page is opened.
    public var isSummary: Bool = false

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

    /// Folders never indexed: retired systems, kept on the site as history.
    static let skippedSections: Set<String> = ["legacy"]

    /// Read the pipeline-built catalog (`website/data/catalog.json`) — one
    /// small file instead of every page. Bodies are left out; the reader loads
    /// a page's text from disk when it opens. Nil when there is no catalog.
    public static func loadCatalog(_ url: URL) -> HandbookIndex? {
        struct Catalog: Decodable {
            struct Page: Decodable {
                let path: String
                let title: String
                let url: String
                let section: String
                let headings: [String]?
                let summary: String?
                let keywords: [String]?
                let lastmod: String?
                let lastmod_by: String?
            }
            let pages: [Page]
        }
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return nil }
        let pages = catalog.pages
            .filter { !skippedSections.contains(String($0.path.split(separator: "/").first ?? "")) }
            .map { p in
                HandbookPage(path: p.path, title: p.title,
                             sections: p.section.split(separator: "/").map(String.init),
                             sitePath: p.url, headings: p.headings ?? [],
                             // Searchable text until the page is opened.
                             body: ([p.summary ?? ""] + (p.keywords ?? [])).joined(separator: "\n"),
                             lastModified: p.lastmod.flatMap { $0.isEmpty ? nil : $0 },
                             lastModifiedBy: p.lastmod_by.flatMap { $0.isEmpty ? nil : $0 },
                             isSummary: true)
            }
        return HandbookIndex(pages: pages)
    }

    /// Read every `.md` page under `contentRoot`.
    public static func load(contentRoot: URL) -> HandbookIndex {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: contentRoot, includingPropertiesForKeys: nil) else { return HandbookIndex(pages: []) }
        var pages: [HandbookPage] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(contentRoot.path.count + 1))
            if skippedSections.contains(String(relative.split(separator: "/").first ?? "")) { continue }
            if let page = page(relativePath: relative, text: text) { pages.append(page) }
        }
        return HandbookIndex(pages: pages.sorted { $0.path < $1.path })
    }

    /// The full page, parsed from its Markdown file.
    public static func fullPage(relativePath: String, contentRoot: URL) -> HandbookPage? {
        let url = contentRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return page(relativePath: relativePath, text: text)
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
