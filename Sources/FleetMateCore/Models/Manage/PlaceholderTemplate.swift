import Foundation

/// A command with `<PLACEHOLDER>` tokens that must be filled in before it
/// runs. Placeholders are upper-case words in angle brackets, for example
/// `<USERNAME>` or `<PACKAGE_IDENTIFIER>`. Any placeholder whose name contains
/// PASSWORD, SECRET or TOKEN is sensitive: it is entered masked and redacted
/// in previews.
public struct PlaceholderTemplate: Identifiable, Hashable, Sendable {
    public let label: String
    public let command: String
    public let placeholders: [String]

    public var id: String { command }

    private static let tokenPattern = try! NSRegularExpression(pattern: "<([A-Z][A-Z0-9_]*)>")

    private init(label: String, command: String, placeholders: [String]) {
        self.label = label
        self.command = command
        self.placeholders = placeholders
    }

    /// Nil when the command has no placeholders.
    public static func detect(label: String, command: String) -> PlaceholderTemplate? {
        var found: [String] = []
        let range = NSRange(command.startIndex..., in: command)
        for match in tokenPattern.matches(in: command, range: range) {
            guard let tokenRange = Range(match.range, in: command) else { continue }
            let token = String(command[tokenRange])
            if !found.contains(token) { found.append(token) }
        }
        return found.isEmpty ? nil : PlaceholderTemplate(label: label, command: command, placeholders: found)
    }

    public static func isSensitive(_ placeholder: String) -> Bool {
        let upper = placeholder.uppercased()
        return upper.contains("PASSWORD") || upper.contains("SECRET") || upper.contains("TOKEN")
    }

    public var hasSensitive: Bool { placeholders.contains(where: Self.isSensitive) }

    /// Human label for a prompt field: USERNAME becomes "Username", PACKAGE_IDENTIFIER "Package identifier".
    public static func fieldLabel(_ placeholder: String) -> String {
        let name = placeholder
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        guard let first = name.first else { return placeholder }
        return first.uppercased() + name.dropFirst()
    }

    public func isComplete(_ values: [String: String]) -> Bool {
        placeholders.allSatisfy { !(values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Substitute values. A bare placeholder becomes a single-quoted shell
    /// literal; a placeholder the author already wrapped in quotes keeps those
    /// quotes and is escaped for them, so the library can write either
    /// `'<USERNAME>'` or `<USERNAME>`. With `redactSensitive` the sensitive
    /// values are replaced by bullets for display.
    public func resolve(_ values: [String: String], redactSensitive: Bool = false) -> String {
        var result = command
        for placeholder in placeholders {
            let value = values[placeholder] ?? ""
            let replacement = redactSensitive && Self.isSensitive(placeholder) ? "••••••••" : value
            result = result.replacingOccurrences(
                of: "'\(placeholder)'", with: "'\(Self.escapeSingleQuoted(replacement))'")
            result = result.replacingOccurrences(
                of: "\"\(placeholder)\"", with: "\"\(Self.escapeDoubleQuoted(replacement))\"")
            result = result.replacingOccurrences(
                of: placeholder, with: "'\(Self.escapeSingleQuoted(replacement))'")
        }
        return result
    }

    /// Inside single quotes only the quote itself needs care: close, escape, reopen.
    static func escapeSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Inside double quotes the shell still expands `$`, backticks and backslashes.
    static func escapeDoubleQuoted(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\", "\"", "$", "`": out.append("\\"); out.append(ch)
            default: out.append(ch)
            }
        }
        return out
    }
}
