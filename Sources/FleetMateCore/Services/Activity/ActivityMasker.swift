import Foundation

/// Replaces device identifiers with stable placeholders so an activity log can
/// be attached to a bug report: serial numbers become SERIAL-1, SERIAL-2…,
/// UDIDs and hardware UUIDs UDID-n, hardware (MAC) addresses MAC-n, email
/// addresses USER-n and every host outside a short public list host-n. The
/// same value always maps to the same placeholder within one masker.
public final class ActivityMasker {
    /// Hosts that say nothing about the organization using FleetMate.
    public static let publicHosts: Set<String> = [
        "graph.microsoft.com", "login.microsoftonline.com", "management.azure.com",
        "api.github.com", "github.com",
        "api-school.apple.com", "api-business.apple.com", "mdmenrollment.apple.com",
    ]

    private var placeholders: [String: String] = [:]
    private var counters: [String: Int] = [:]
    private let knownSerials: [String]

    public init(knownSerials: [String] = []) {
        // Longest first, so a serial that contains another is replaced whole.
        self.knownSerials = Array(Set(knownSerials.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }

    private static let patterns: [(kind: String, regex: NSRegularExpression)] = [
        ("USER", try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)),
        ("MAC", try! NSRegularExpression(pattern: #"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#)),
        ("UDID", try! NSRegularExpression(pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)),
        ("UDID", try! NSRegularExpression(pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#)),
        ("UDID", try! NSRegularExpression(pattern: #"\b[0-9A-Fa-f]{40}\b"#)),
    ]

    /// Upper-case letters and digits, 8 to 14 long, with at least one of
    /// each: the shape of Apple and most PC serial numbers.
    private static let serialShape = try! NSRegularExpression(
        pattern: #"\b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*[0-9])[A-Z0-9]{8,14}\b"#)

    public func mask(_ text: String) -> String {
        var result = text
        for (kind, regex) in Self.patterns {
            result = replace(regex, in: result, kind: kind)
        }
        for serial in knownSerials {
            result = result.replacingOccurrences(of: serial, with: placeholder(for: serial.uppercased(), kind: "SERIAL"),
                                                 options: .caseInsensitive)
        }
        return replace(Self.serialShape, in: result, kind: "SERIAL")
    }

    public func maskHost(_ host: String) -> String {
        let lower = host.lowercased()
        if lower.isEmpty || Self.publicHosts.contains(lower) { return host }
        return placeholder(for: lower, kind: "host")
    }

    private func replace(_ regex: NSRegularExpression, in text: String, kind: String) -> String {
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let value = ns.substring(with: match.range)
            let key = kind == "MAC" ? value.uppercased().replacingOccurrences(of: "-", with: ":") : value.uppercased()
            output += placeholders.values.contains(value) ? value : placeholder(for: key, kind: kind)
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private func placeholder(for value: String, kind: String) -> String {
        let key = "\(kind):\(value)"
        if let existing = placeholders[key] { return existing }
        let next = (counters[kind] ?? 0) + 1
        counters[kind] = next
        let label = "\(kind)-\(next)"
        placeholders[key] = label
        return label
    }

    // MARK: - Serials named in a URL

    private static let querySerial = try! NSRegularExpression(
        pattern: #"serial(?:Number|_number)?\s*(?:=|eq\s*)\s*'?([A-Za-z0-9-]{5,20})'?"#, options: .caseInsensitive)

    /// Serial numbers a request's query names, read before the query is
    /// dropped: `$filter=serialNumber eq 'X'`, `serial=X`.
    public static func serialsInQuery(_ url: URL?) -> [String] {
        guard let query = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.query }) else { return [] }
        let ns = query as NSString
        return querySerial.matches(in: query, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).uppercased()
        }
    }

    // MARK: - Export

    /// The log as plain text with every identifier masked.
    public static func export(_ actions: [ActivityAction], at date: Date = Date()) -> String {
        let masker = ActivityMasker(knownSerials: actions.flatMap(\.serials))
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var lines = ["FleetMate Activity Log (masked), exported \(ISO8601DateFormatter().string(from: date))", ""]
        for action in actions {
            let serials = action.serials.isEmpty ? "" : " [" + action.serials.map { masker.mask($0) }.joined(separator: ", ") + "]"
            lines.append("\(time.string(from: action.startedAt))  \(action.service)  \(masker.mask(action.title))  \(masker.mask(action.result))\(serials)")
            for request in action.requests {
                let status = masker.mask(request.statusText)
                let ms = Int((request.duration * 1000).rounded())
                lines.append("    \(request.method) \(masker.maskHost(request.host))\(masker.mask(request.path))  \(status)  \(ms) ms")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
