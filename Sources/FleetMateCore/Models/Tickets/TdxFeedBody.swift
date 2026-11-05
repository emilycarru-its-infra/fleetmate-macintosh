import Foundation

/// A TeamDynamix feed entry's HTML body, split into what the app can show:
/// runs of text (with their links) and the images between them.
///
/// TDX stores comments as rich HTML. Stripping the tags left a comment made of
/// nothing but a pasted screenshot as an empty card, and dropped the link
/// targets the web client shows. This keeps both: an `<img>` becomes an image
/// segment, an `<a href>` keeps its target, and bare URLs and email addresses
/// in the text are detected the way the web client links them.
public struct TdxFeedBody: Equatable, Sendable {

    public enum Segment: Equatable, Sendable {
        case text([TdxTextRun])
        case image(TdxBodyImage)
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public var isEmpty: Bool { segments.isEmpty }

    public var images: [TdxBodyImage] {
        segments.compactMap { if case .image(let image) = $0 { return image } else { return nil } }
    }

    /// The text alone, as the clipboard and quoting want it.
    public var plainText: String {
        segments.compactMap { segment -> String? in
            if case .text(let runs) = segment { return runs.map(\.text).joined() }
            return nil
        }
        .joined(separator: "\n\n")
    }

    /// Parse `html`, resolving relative image sources against `webRoot` — the
    /// TDX web client's origin, which is where `/TDNext/…` paths live.
    public static func parse(_ html: String, webRoot: URL?) -> TdxFeedBody {
        var parser = Parser(webRoot: webRoot)
        parser.run(html)
        return TdxFeedBody(segments: parser.finish())
    }
}

/// A stretch of text, optionally a link.
public struct TdxTextRun: Equatable, Sendable {
    public let text: String
    public let link: URL?

    public init(_ text: String, link: URL? = nil) {
        self.text = text
        self.link = link
    }
}

/// An image embedded in a feed entry's body.
public struct TdxBodyImage: Equatable, Sendable, Hashable {
    public enum Source: Equatable, Sendable, Hashable {
        /// Bytes carried in the HTML itself, from a `data:` URI.
        case inline(data: Data, mimeType: String)
        /// An http(s) image to fetch.
        case remote(URL)
    }

    /// What to show: the full-size image when the HTML names one.
    public let source: Source
    /// The `src` the HTML displays, when `source` is a different, full-size
    /// image (TDX's own uploader writes a thumbnail as `src` and the original
    /// as `data-image-url`). Tried if the full-size image fails to load.
    public let fallback: Source?
    public let alt: String?

    public init(source: Source, fallback: Source? = nil, alt: String?) {
        self.source = source
        self.fallback = fallback
        self.alt = alt
    }

    /// A stable key for caching and view identity.
    public var cacheKey: String {
        switch source {
        case .remote(let url): return url.absoluteString
        case .inline(let data, _): return "inline:\(data.count):\(data.hashValue)"
        }
    }

    public var remoteURL: URL? {
        if case .remote(let url) = source { return url }
        return nil
    }

    /// A filename for drags and saves: the URL's last path component when it
    /// has a usable one, otherwise "image" with an extension for its type.
    public var suggestedFileName: String {
        if let url = remoteURL {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/", last.contains(".") { return last }
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            where (item.value ?? "").contains(".") {
                let value = item.value ?? ""
                if ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff"]
                    .contains((value as NSString).pathExtension.lowercased()) {
                    return (value as NSString).lastPathComponent
                }
            }
            return "image.png"
        }
        if case .inline(_, let mime) = source {
            return "image.\(Self.fileExtension(forMimeType: mime))"
        }
        return "image.png"
    }

    static func fileExtension(forMimeType mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/bmp": return "bmp"
        case "image/tiff": return "tiff"
        case "image/svg+xml": return "svg"
        default: return "png"
        }
    }
}

// MARK: - Source resolution

public enum TdxBodyImageResolver {

    /// The largest inline image accepted, decoded. A pasted screenshot is a
    /// few hundred KB; anything far past that is not worth holding per card.
    public static let maxInlineBytes = 20 * 1024 * 1024

    /// Turn an `<img src>` into something loadable, or nil when it is not:
    /// `cid:` parts of an email that never made it into the body, `file:`,
    /// `javascript:` and anything else that isn't http(s) or `data:image/…`.
    ///
    /// Protocol-relative (`//host/x.png`) becomes https. A relative path is
    /// resolved against the TDX web root, because that is the page the HTML
    /// was written for.
    public static func resolve(_ rawSrc: String, webRoot: URL?) -> TdxBodyImage.Source? {
        let src = rawSrc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return nil }

        if src.lowercased().hasPrefix("data:") {
            return decodeDataURI(src)
        }

        if src.hasPrefix("//") {
            return remote(URL(string: "https:" + src))
        }

        if let url = URL(string: src) ?? URL(string: src.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
           let scheme = url.scheme?.lowercased() {
            return (scheme == "http" || scheme == "https") ? remote(url) : nil
        }

        guard let webRoot else { return nil }
        let encoded = src.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? src
        // A root-relative path replaces the web root's own path; a bare one
        // sits under it.
        let base = webRoot.absoluteString.hasSuffix("/") ? webRoot : URL(string: webRoot.absoluteString + "/")
        return remote(URL(string: encoded, relativeTo: base)?.absoluteURL)
    }

    private static func remote(_ url: URL?) -> TdxBodyImage.Source? {
        guard let url, let host = url.host, !host.isEmpty else { return nil }
        return .remote(url)
    }

    /// `data:image/png;base64,iVBOR…` → bytes. Non-image media types are
    /// refused: an `<img>` that claims to be HTML is not an image.
    static func decodeDataURI(_ uri: String) -> TdxBodyImage.Source? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        let payload = String(uri[uri.index(after: comma)...])
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let mime = (parts.first ?? "").lowercased()
        guard mime.hasPrefix("image/") else { return nil }
        let isBase64 = parts.dropFirst().contains { $0.lowercased() == "base64" }

        let data: Data?
        if isBase64 {
            let compact = payload.filter { !$0.isWhitespace }
                .replacingOccurrences(of: "%2B", with: "+")
                .replacingOccurrences(of: "%2F", with: "/")
                .replacingOccurrences(of: "%3D", with: "=")
            data = Data(base64Encoded: compact, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty, data.count <= maxInlineBytes else { return nil }
        return .inline(data: data, mimeType: mime)
    }
}

// MARK: - Which requests carry TDX credentials

public enum TdxImageAuthPolicy {

    /// True when an image at `url` may be fetched with the TDX session —
    /// cookies or bearer token. Only the TDX host itself, over https, on the
    /// same port, qualifies. Every other image loads anonymously, so a
    /// comment that embeds a third-party image can't make the app hand that
    /// host the operator's TeamDynamix session.
    public static func sendsTdxCredentials(to url: URL, tdxBase: URL?) -> Bool {
        guard let tdxBase,
              url.scheme?.lowercased() == "https",
              tdxBase.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              host == tdxBase.host?.lowercased()
        else { return false }
        return effectivePort(url) == effectivePort(tdxBase)
    }

    /// Whether an image at `url` may be fetched at all. Remote images load
    /// only over https; plain http is refused rather than leaking the request.
    public static func mayLoad(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// A redirect followed while loading a credentialed image must stay on the
    /// TDX host. One that leaves (to a sign-in page, a CDN) is not followed,
    /// so the session never rides along to it.
    public static func mayFollowRedirect(to url: URL, tdxBase: URL?) -> Bool {
        sendsTdxCredentials(to: url, tdxBase: tdxBase)
    }

    /// True when `data` is an image: the server says so, or its first bytes
    /// are a known image signature. HTML (a sign-in page) is never an image.
    public static func looksLikeImage(_ data: Data, contentType: String?) -> Bool {
        guard !data.isEmpty else { return false }
        let type = (contentType ?? "").lowercased()
        if type.hasPrefix("text/html") { return false }
        if type.hasPrefix("image/") { return true }
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        return starts([0x89, 0x50, 0x4E, 0x47])                 // PNG
            || starts([0xFF, 0xD8, 0xFF])                          // JPEG
            || starts(Array("GIF8".utf8))                          // GIF
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8))
            || starts(Array("ftyp".utf8), at: 4)                   // HEIC/AVIF
            || starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) // TIFF
            || starts(Array("BM".utf8))                            // BMP
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
    }
}

// MARK: - Link detection

public enum TdxLinkDetector {

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Split plain text into runs, linking web addresses and email addresses
    /// the way the TDX web client does. Only http(s) and mailto links are made;
    /// anything else the detector finds stays text.
    public static func runs(in text: String) -> [TdxTextRun] {
        guard let detector, !text.isEmpty else { return text.isEmpty ? [] : [TdxTextRun(text)] }
        let ns = text as NSString
        var runs: [TdxTextRun] = []
        var cursor = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { continue }
            if match.range.location > cursor {
                runs.append(TdxTextRun(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            runs.append(TdxTextRun(ns.substring(with: match.range), link: url))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            runs.append(TdxTextRun(ns.substring(from: cursor)))
        }
        return runs
    }

    /// An `<a href>` target worth making clickable: http(s) or mailto only.
    /// A relative href resolves against the TDX web root.
    public static func linkTarget(_ href: String, webRoot: URL?) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "mailto"].contains(scheme) ? url : nil
        }
        if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
        guard let webRoot else { return nil }
        let base = webRoot.absoluteString.hasSuffix("/") ? webRoot : URL(string: webRoot.absoluteString + "/")
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}

// MARK: - Parser

extension TdxFeedBody {

    fileprivate struct Parser {
        let webRoot: URL?
        var segments: [Segment] = []
        /// Runs gathered since the last image. Link runs are final; plain
        /// runs are scanned for bare URLs when the block is flushed.
        var pending: [TdxTextRun] = []
        var linkHref: URL?
        var linkText = ""
        var skipDepth = 0
        var listDepth = 0

        init(webRoot: URL?) { self.webRoot = webRoot }

        mutating func run(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                    let raw = html[html.index(after: index)..<close]
                    if raw.hasPrefix("!--") {
                        // A comment may itself contain ">"; skip to its end.
                        if let end = html.range(of: "-->", range: index..<html.endIndex) {
                            index = end.upperBound
                        } else {
                            index = html.endIndex
                        }
                        continue
                    }
                    handleTag(String(raw))
                    index = html.index(after: close)
                } else {
                    let next = html[html.index(after: index)...].firstIndex(of: "<") ?? html.endIndex
                    if skipDepth == 0 {
                        appendText(TdxFeedBody.decodeEntities(String(html[index..<next])))
                    }
                    index = next
                }
            }
        }

        mutating func finish() -> [Segment] {
            closeLink()
            flushText()
            return segments
        }

        private mutating func handleTag(_ raw: String) {
            let isClosing = raw.hasPrefix("/")
            let body = isClosing ? String(raw.dropFirst()) : raw
            let name = body.prefix(while: { $0.isLetter || $0.isNumber }).lowercased()

            switch (name, isClosing) {
            case ("script", false), ("style", false), ("head", false), ("title", false):
                if !body.hasSuffix("/") { skipDepth += 1 }
            case ("script", true), ("style", true), ("head", true), ("title", true):
                skipDepth = max(0, skipDepth - 1)

            case ("br", _):
                appendText("\n")
            case ("p", true), ("div", true), ("tr", true), ("blockquote", true), ("pre", true),
                 ("h1", true), ("h2", true), ("h3", true), ("h4", true), ("h5", true), ("h6", true):
                appendText("\n")
            case ("p", false), ("div", false), ("blockquote", false), ("pre", false), ("table", false),
                 ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
                breakLineIfNeeded()
            case ("ul", false), ("ol", false):
                listDepth += 1
                breakLineIfNeeded()
            case ("ul", true), ("ol", true):
                listDepth = max(0, listDepth - 1)
                appendText("\n")
            case ("li", false):
                breakLineIfNeeded()
                appendText(String(repeating: "    ", count: max(0, listDepth - 1)) + "• ")
            case ("li", true):
                appendText("\n")
            case ("td", true), ("th", true):
                appendText("  ")
            case ("hr", _):
                breakLineIfNeeded()
                appendText("—\n")

            case ("a", false):
                closeLink()
                linkHref = TdxFeedBody.attribute("href", in: body)
                    .flatMap { TdxLinkDetector.linkTarget(TdxFeedBody.decodeEntities($0), webRoot: webRoot) }
                linkText = ""
            case ("a", true):
                closeLink()

            case ("img", false):
                guard skipDepth == 0 else { return }
                let shown = TdxFeedBody.attribute("src", in: body)
                    .flatMap { TdxBodyImageResolver.resolve(TdxFeedBody.decodeEntities($0), webRoot: webRoot) }
                // TDX's image uploader puts a 200px thumbnail in `src` and the
                // original in `data-image-url`; a card wants the original.
                let full = TdxFeedBody.attribute("data-image-url", in: body)
                    .flatMap { TdxBodyImageResolver.resolve(TdxFeedBody.decodeEntities($0), webRoot: webRoot) }
                guard let source = full ?? shown else { return }
                let alt = TdxFeedBody.attribute("alt", in: body)
                    .map { TdxFeedBody.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                // An image inside a link is still shown as an image; the link
                // text so far stays with the text before it.
                closeLink()
                flushText()
                segments.append(.image(TdxBodyImage(source: source, fallback: source == shown ? nil : shown, alt: alt)))

            default:
                break
            }
        }

        private mutating func appendText(_ text: String) {
            guard skipDepth == 0, !text.isEmpty else { return }
            if linkHref != nil {
                linkText += text
            } else if let last = pending.last, last.link == nil {
                pending[pending.count - 1] = TdxTextRun(last.text + text)
            } else {
                pending.append(TdxTextRun(text))
            }
        }

        private mutating func breakLineIfNeeded() {
            let tail = linkHref != nil ? linkText : (pending.last?.text ?? "")
            if !tail.isEmpty, !tail.hasSuffix("\n") { appendText("\n") }
        }

        private mutating func closeLink() {
            guard let href = linkHref else { return }
            linkHref = nil
            let text = linkText
            linkText = ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !text.isEmpty { appendText(text) }
                return
            }
            pending.append(TdxTextRun(text, link: href))
        }

        /// Close off the text gathered so far as one segment: tidy its
        /// whitespace, then link bare URLs and addresses in its plain runs.
        private mutating func flushText() {
            defer { pending = [] }
            let runs = TdxFeedBody.tidy(pending)
            guard !runs.isEmpty else { return }
            var linked: [TdxTextRun] = []
            for run in runs {
                if run.link != nil {
                    linked.append(run)
                } else {
                    linked.append(contentsOf: TdxLinkDetector.runs(in: run.text))
                }
            }
            segments.append(.text(linked))
        }
    }

    /// Collapse runs of blank lines, trim the block's ends, and strip the
    /// spaces HTML source indentation leaves at the start of lines.
    fileprivate static func tidy(_ runs: [TdxTextRun]) -> [TdxTextRun] {
        var cleaned = runs.map { run -> TdxTextRun in
            var text = run.text.replacingOccurrences(of: "\r\n", with: "\n")
            text = text.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            return TdxTextRun(text, link: run.link)
        }
        // Trim leading whitespace off the first run and trailing off the last,
        // dropping runs that become empty.
        while let first = cleaned.first {
            let trimmed = String(first.text.drop(while: { $0.isWhitespace }))
            if trimmed.isEmpty { cleaned.removeFirst(); continue }
            cleaned[0] = TdxTextRun(trimmed, link: first.link)
            break
        }
        while let last = cleaned.last {
            var text = last.text
            while let c = text.last, c.isWhitespace { text.removeLast() }
            if text.isEmpty { cleaned.removeLast(); continue }
            cleaned[cleaned.count - 1] = TdxTextRun(text, link: last.link)
            break
        }
        // Blank lines across a run boundary still collapse.
        return cleaned
    }

    /// Decode HTML entities in one pass, so `&amp;lt;` stays `&lt;`.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
            "rdquo": "”", "ldquo": "“", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
        ]
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "&", let semi = text[index...].prefix(12).firstIndex(of: ";") {
                let entity = text[text.index(after: index)..<semi]
                var replacement: String?
                if entity.hasPrefix("#") {
                    let digits = entity.dropFirst()
                    let scalar = (digits.first == "x" || digits.first == "X")
                        ? UInt32(digits.dropFirst(), radix: 16)
                        : UInt32(digits)
                    replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[String(entity)]
                }
                if let replacement {
                    out += replacement
                    index = text.index(after: semi)
                    continue
                }
            }
            out.append(c)
            index = text.index(after: index)
        }
        return out
    }

    /// An attribute's value from a tag body: double-quoted, single-quoted or
    /// unquoted. Matches the name as a whole word, so `data-src` is not `src`.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?:^|[\\s/])\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...3 {
            let range = match.range(at: group)
            if range.location != NSNotFound { return ns.substring(with: range) }
        }
        return nil
    }
}

extension FleetMateConfig {
    /// The TDX web client's root — the configured base with any API suffix
    /// removed. Relative image and link paths in feed HTML resolve against it.
    public var tdxWebRootUrl: URL? {
        var web = (tdxBaseUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/api", "/TDWebApi"] where web.lowercased().hasSuffix(suffix.lowercased()) {
            web = String(web.dropLast(suffix.count))
        }
        guard !web.isEmpty, let url = URL(string: web), url.host != nil else { return nil }
        return url
    }
}
