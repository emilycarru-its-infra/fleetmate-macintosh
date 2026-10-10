import Foundation

// Adapted from MunkiStudio (Apache-2.0):
// Sources/Core/Models/ScriptLanguage.swift and the ScriptHighlighter in
// Sources/App/Components/HighlightedTextEditor.swift. Same lightweight
// approach — comments, strings, keywords and numbers by regular expression,
// no grammar — extended with detection by file extension for the languages
// a repository holds, and with comments and strings resolved in one
// left-to-right pass so a quote inside a comment (or a comment marker inside
// a string) no longer paints the wrong span.

/// A language the editor colours.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case shell, python, ruby, perl, swift, csharp, powershell, javascript, go, hcl, yaml, json, xml, plainText

    /// By file name first, then by shebang.
    public static func detect(path: String, source: String) -> CodeLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "sh", "bash", "zsh", "command": return .shell
        case "py": return .python
        case "rb": return .ruby
        case "pl", "pm": return .perl
        case "swift": return .swift
        case "cs", "csx": return .csharp
        case "ps1", "psm1", "psd1": return .powershell
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
        case "go": return .go
        case "tf", "tfvars", "hcl": return .hcl
        case "yml", "yaml": return .yaml
        case "json", "jsonc": return .json
        case "xml", "plist", "csproj", "props", "targets", "xaml", "recipe", "pkginfo", "mobileconfig": return .xml
        case "md", "markdown", "txt": return .plainText
        default: break
        }
        if name == "makefile" || name == "dockerfile" || name.hasPrefix(".") && ext.isEmpty { return .shell }
        let firstLine = source.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if firstLine.hasPrefix("#!") {
            let lower = firstLine.lowercased()
            if lower.contains("python") { return .python }
            if lower.contains("ruby") { return .ruby }
            if lower.contains("perl") { return .perl }
            if lower.contains("swift") { return .swift }
            if lower.contains("pwsh") { return .powershell }
            if lower.contains("node") { return .javascript }
            return .shell
        }
        let trimmed = source.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<plist") { return .xml }
        return .plainText
    }

    public var lineCommentPrefix: String? {
        switch self {
        case .shell, .python, .ruby, .perl, .powershell, .yaml: "#"
        case .swift, .csharp, .javascript, .go: "//"
        case .hcl: "#"
        case .json, .xml, .plainText: nil
        }
    }

    public var keywords: [String] {
        switch self {
        case .shell:
            ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function",
             "return", "in", "until", "exit", "export", "local", "readonly", "set", "unset", "shift", "source"]
        case .python:
            ["def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "as",
             "import", "from", "return", "yield", "pass", "break", "continue", "raise", "lambda", "and", "or",
             "not", "in", "is", "True", "False", "None", "global", "nonlocal", "async", "await"]
        case .ruby:
            ["def", "class", "module", "if", "elsif", "else", "unless", "case", "when", "while", "until", "for",
             "in", "do", "end", "begin", "rescue", "ensure", "raise", "return", "yield", "self", "nil", "true",
             "false", "and", "or", "not", "require", "include"]
        case .perl:
            ["use", "my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until", "for",
             "foreach", "do", "return", "die", "warn", "print", "printf"]
        case .swift:
            ["import", "func", "var", "let", "class", "struct", "enum", "protocol", "extension", "if", "else",
             "guard", "for", "while", "do", "try", "throws", "throw", "return", "switch", "case", "default", "break",
             "continue", "true", "false", "nil", "self", "Self", "async", "await", "actor", "where", "in",
             "private", "public", "internal", "fileprivate", "static", "final", "init", "some", "any"]
        case .csharp:
            ["using", "namespace", "class", "struct", "interface", "enum", "record", "public", "private",
             "protected", "internal", "static", "readonly", "const", "var", "new", "return", "if", "else", "for",
             "foreach", "while", "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally",
             "throw", "async", "await", "true", "false", "null", "this", "void", "string", "int", "bool", "in"]
        case .powershell:
            ["function", "param", "if", "elseif", "else", "foreach", "for", "while", "do", "switch", "return",
             "try", "catch", "finally", "throw", "begin", "process", "end", "in"]
        case .javascript:
            ["import", "export", "from", "const", "let", "var", "function", "return", "if", "else", "for", "while",
             "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally", "throw", "new",
             "class", "extends", "async", "await", "true", "false", "null", "undefined", "this", "type", "interface"]
        case .go:
            ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "if",
             "else", "for", "range", "switch", "case", "default", "return", "go", "defer", "select", "true",
             "false", "nil"]
        case .hcl:
            ["resource", "data", "variable", "output", "locals", "module", "provider", "terraform", "for_each",
             "count", "depends_on", "lifecycle", "dynamic", "true", "false", "null", "for", "in", "if"]
        case .yaml, .json:
            ["true", "false", "null"]
        case .xml, .plainText:
            []
        }
    }
}

/// What a highlighted span is.
public enum CodeTokenKind: Sendable, Equatable {
    case comment, string, keyword, number
}

public struct CodeToken: Sendable, Equatable {
    public let kind: CodeTokenKind
    /// UTF-16 range, ready for an `NSTextStorage`.
    public let range: NSRange
}

/// Finds the spans the editor colours. Pure, so it is tested without a view.
public enum CodeHighlighter {
    /// Sources larger than this are shown uncoloured: re-colouring on every
    /// keystroke has to stay instant.
    public static let sizeLimit = 300_000

    public static func tokens(in source: String, language: CodeLanguage) -> [CodeToken] {
        let text = source as NSString
        guard language != .plainText, text.length <= sizeLimit else { return [] }
        let whole = NSRange(location: 0, length: text.length)
        var tokens: [CodeToken] = []
        var claimed = IndexSet()

        // Comments and strings in one pass: the leftmost match wins, so a
        // quote inside a comment and a comment marker inside a string are
        // both read correctly.
        var alternatives = [#""(?:\\.|[^"\\\n])*""#, #"'(?:\\.|[^'\\\n])*'"#]
        if let prefix = language.lineCommentPrefix {
            alternatives.insert(NSRegularExpression.escapedPattern(for: prefix) + ".*$", at: 0)
        }
        if language == .xml { alternatives.insert(#"<!--[\s\S]*?-->"#, at: 0) }
        if [.swift, .csharp, .javascript, .go].contains(language) { alternatives.insert(#"/\*[\s\S]*?\*/"#, at: 0) }
        let combined = alternatives.map { "(\($0))" }.joined(separator: "|")
        if let regex = try? NSRegularExpression(pattern: combined, options: [.anchorsMatchLines]) {
            for match in regex.matches(in: source, range: whole) {
                let matched = text.substring(with: match.range)
                let isString = matched.hasPrefix("\"") || matched.hasPrefix("'")
                tokens.append(CodeToken(kind: isString ? .string : .comment, range: match.range))
                claimed.insert(integersIn: match.range.location..<NSMaxRange(match.range))
            }
        }

        func addUnclaimed(_ pattern: String, _ kind: CodeTokenKind) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: source, range: whole)
            where !claimed.intersects(integersIn: match.range.location..<NSMaxRange(match.range)) {
                tokens.append(CodeToken(kind: kind, range: match.range))
            }
        }
        let keywords = language.keywords
        if !keywords.isEmpty {
            addUnclaimed("\\b(" + keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b", .keyword)
        }
        addUnclaimed(#"\b\d+(?:\.\d+)?\b"#, .number)
        return tokens.sorted { $0.range.location < $1.range.location }
    }
}
