import Foundation

/// The `---` YAML block at the top of a Markdown page, read as flat
/// `key: value` pairs — enough for titles, slugs and descriptions without a
/// YAML dependency for nested values nobody here needs.
public enum FrontMatter {
    public static func split(_ text: String) -> (fields: [String: String], body: String) {
        guard text.hasPrefix("---") else { return ([:], text) }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fields, body)
    }
}
