import Foundation

/// Converts Azure DevOps description HTML to Markdown.
///
/// Why convert instead of rendering the HTML: the app's HTML path went through
/// `NSAttributedString` into SwiftUI `Text`, and `Text` ignores paragraph
/// styles — tables flattened to one line per cell, bullets lost their hanging
/// indent, paragraphs lost their spacing. The Markdown path (MarkdownUI with
/// the fleetMate theme) already renders real tables, indented lists, and
/// gray-chip `code`, so ADO content is translated into what that renderer
/// speaks rather than teaching a second renderer the same tricks.
///
/// Scope: the tag set ADO's editor and API actually emit — div/p/br/span,
/// b/strong/i/em/u, code/pre, ul/ol/li, table/tr/th/td, a/img, h1–h6,
/// blockquote, hr. Unknown tags are dropped, their text kept.
public enum HtmlToMarkdown {

    public static func convert(_ html: String) -> String {
        var state = State()
        var index = html.startIndex

        while index < html.endIndex {
            if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                let rawTag = String(html[html.index(after: index)..<close])
                handleTag(rawTag, state: &state)
                index = html.index(after: close)
            } else {
                let nextTag = html[index...].firstIndex(of: "<") ?? html.endIndex
                appendText(String(html[index..<nextTag]), state: &state)
                index = nextTag
            }
        }

        state.closeDanglingInlineMarkers()
        return state.output
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - State

    private struct ListContext {
        let ordered: Bool
        var itemNumber = 0
    }

    private struct State {
        var output = ""
        var listStack: [ListContext] = []
        var inPre = false
        var boldDepth = 0
        var italicDepth = 0
        var inInlineCode = false
        var linkHref: String?
        var linkText = ""

        /// True right after `**`, `*` or `` ` `` opens — the next text's
        /// leading whitespace would detach the marker from its content.
        /// (A *closing* marker must keep the following space: "**bold** and".)
        var justOpenedInlineMarker = false

        // Tables collect until </table>, then render in one piece.
        var tableRows: [[String]] = []
        var currentRow: [String]?
        var currentCell: String?
        var headerRowSeen = false
        var inTable: Bool { currentRow != nil || !tableRows.isEmpty }

        /// Append visible text to whichever sink is active (table cell, link
        /// label, or the document).
        mutating func emit(_ text: String) {
            if currentCell != nil {
                currentCell! += text
            } else if linkHref != nil {
                linkText += text
            } else {
                output += text
            }
        }

        /// End the line if there is a partial one.
        mutating func newline() {
            if currentCell != nil { return }
            if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
        }

        /// Separate blocks with exactly one blank line.
        mutating func blankLine() {
            if currentCell != nil { return }
            newline()
            if !output.isEmpty && !output.hasSuffix("\n\n") { output += "\n" }
        }

        /// A `**` or `*` closing right after a space renders literally; move
        /// the marker inside the whitespace.
        mutating func trimTrailingSpaces() -> String {
            if currentCell != nil {
                let trimmed = String(currentCell!.reversed().drop(while: { $0 == " " }).reversed())
                let moved = String(repeating: " ", count: currentCell!.count - trimmed.count)
                currentCell = trimmed
                return moved
            }
            let trimmed = String(output.reversed().drop(while: { $0 == " " }).reversed())
            let moved = String(repeating: " ", count: output.count - trimmed.count)
            output = trimmed
            return moved
        }

        mutating func closeDanglingInlineMarkers() {
            if inInlineCode { emit("`") }
            if boldDepth > 0 { emit("**") }
            if italicDepth > 0 { emit("*") }
        }
    }

    // MARK: - Tags

    private static func handleTag(_ rawTag: String, state: inout State) {
        let isClosing = rawTag.hasPrefix("/")
        let body = isClosing ? String(rawTag.dropFirst()) : rawTag
        let name = body
            .split(separator: " ", maxSplits: 1)[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        switch (name, isClosing) {
        case ("br", _):
            if state.currentCell != nil { state.currentCell! += " " } else { state.emit("\n") }

        case ("p", false):
            state.blankLine()
        case ("p", true):
            state.blankLine()

        case ("div", false), ("div", true):
            state.newline()

        case ("b", false), ("strong", false):
            state.boldDepth += 1
            if state.boldDepth == 1 { state.emit("**"); state.justOpenedInlineMarker = true }
        case ("b", true), ("strong", true):
            guard state.boldDepth > 0 else { break }
            state.boldDepth -= 1
            if state.boldDepth == 0 {
                let spaces = state.trimTrailingSpaces()
                state.emit("**" + spaces)
            }

        case ("i", false), ("em", false):
            state.italicDepth += 1
            if state.italicDepth == 1 { state.emit("*"); state.justOpenedInlineMarker = true }
        case ("i", true), ("em", true):
            guard state.italicDepth > 0 else { break }
            state.italicDepth -= 1
            if state.italicDepth == 0 {
                let spaces = state.trimTrailingSpaces()
                state.emit("*" + spaces)
            }

        case ("code", false):
            // <pre><code> is one fence, not a fence plus backticks.
            if !state.inPre {
                state.inInlineCode = true
                state.emit("`")
                state.justOpenedInlineMarker = true
            }
        case ("code", true):
            if state.inInlineCode {
                state.inInlineCode = false
                let spaces = state.trimTrailingSpaces()
                state.emit("`" + spaces)
            }

        case ("pre", false):
            state.blankLine()
            state.emit("```\n")
            state.inPre = true
        case ("pre", true):
            state.inPre = false
            state.newline()
            state.emit("```")
            state.blankLine()

        case ("ul", false):
            // A top-level list needs a blank line before it, or Markdown fuses
            // it into the preceding paragraph. Nested lists must NOT get one.
            if state.listStack.isEmpty { state.blankLine() }
            state.listStack.append(ListContext(ordered: false))
        case ("ol", false):
            if state.listStack.isEmpty { state.blankLine() }
            state.listStack.append(ListContext(ordered: true))
        case ("ul", true), ("ol", true):
            if !state.listStack.isEmpty { state.listStack.removeLast() }
            if state.listStack.isEmpty { state.blankLine() }

        case ("li", false):
            state.newline()
            let depth = max(state.listStack.count - 1, 0)
            let indent = String(repeating: "    ", count: depth)
            if state.listStack.isEmpty {
                state.emit("- ")
            } else if state.listStack[state.listStack.count - 1].ordered {
                state.listStack[state.listStack.count - 1].itemNumber += 1
                state.emit(indent + "\(state.listStack[state.listStack.count - 1].itemNumber). ")
            } else {
                state.emit(indent + "- ")
            }
        case ("li", true):
            state.newline()

        case ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
            state.blankLine()
            let level = Int(String(name.dropFirst())) ?? 3
            state.emit(String(repeating: "#", count: level) + " ")
        case ("h1", true), ("h2", true), ("h3", true), ("h4", true), ("h5", true), ("h6", true):
            state.blankLine()

        case ("hr", _):
            state.blankLine()
            state.emit("---")
            state.blankLine()

        case ("blockquote", false):
            state.blankLine()
            state.emit("> ")
        case ("blockquote", true):
            state.blankLine()

        case ("a", false):
            state.linkHref = attribute("href", in: body)
            state.linkText = ""
        case ("a", true):
            if let href = state.linkHref {
                let text = state.linkText.trimmingCharacters(in: .whitespacesAndNewlines)
                state.linkHref = nil
                state.linkText = ""
                state.emit(text.isEmpty ? "<\(href)>" : "[\(text)](\(href))")
            }

        case ("img", _):
            if !isClosing, let src = attribute("src", in: body) {
                let alt = attribute("alt", in: body) ?? "image"
                state.emit("![\(alt)](\(src))")
            }

        // MARK: Tables

        case ("table", false):
            state.tableRows = []
            state.headerRowSeen = false
        case ("tr", false):
            state.currentRow = []
        case ("th", false):
            state.headerRowSeen = true
            state.currentCell = ""
        case ("td", false):
            state.currentCell = ""
        case ("th", true), ("td", true):
            if let cell = state.currentCell {
                state.currentRow?.append(
                    cell.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "|", with: "\\|")
                )
                state.currentCell = nil
            }
        case ("tr", true):
            if let row = state.currentRow {
                state.tableRows.append(row)
                state.currentRow = nil
            }
        case ("table", true):
            emitTable(state: &state)

        default:
            break
        }
    }

    private static func emitTable(state: inout State) {
        let rows = state.tableRows
        state.tableRows = []
        guard !rows.isEmpty else { return }

        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return }
        func line(_ row: [String]) -> String {
            let padded = row + Array(repeating: "", count: width - row.count)
            return "| " + padded.joined(separator: " | ") + " |"
        }

        state.blankLine()
        // Markdown tables require a header; without a <th> row the first row
        // serves, which matches how ADO's editor displays them anyway.
        state.emit(line(rows[0]) + "\n")
        state.emit("|" + String(repeating: " --- |", count: width) + "\n")
        for row in rows.dropFirst() {
            state.emit(line(row) + "\n")
        }
        state.blankLine()
    }

    // MARK: - Text

    private static func appendText(_ raw: String, state: inout State) {
        var text = decodeEntities(raw)
        if state.inPre {
            state.emit(text)
            return
        }
        // HTML collapses whitespace runs; keeping literal newlines from the
        // source would fake paragraph breaks that aren't there.
        text = text.replacingOccurrences(of: "[ \\t\\n\\r]+", with: " ", options: .regularExpression)
        if text == " " {
            // Pure inter-tag whitespace: meaningful between words, noise at a
            // line start.
            let sink = state.currentCell ?? (state.linkHref != nil ? state.linkText : state.output)
            if sink.isEmpty || sink.hasSuffix("\n") || sink.hasSuffix(" ") { return }
        }
        // Fresh lines and freshly opened inline markers don't want leading
        // spaces; a freshly *closed* marker does ("**bold** and").
        let sink = state.currentCell ?? (state.linkHref != nil ? state.linkText : state.output)
        if sink.hasSuffix("\n") || sink.isEmpty || state.justOpenedInlineMarker {
            text = String(text.drop(while: { $0 == " " }))
        }
        if !text.isEmpty { state.justOpenedInlineMarker = false }
        state.emit(text)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#160;": " ",
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities, decimal and hex.
        while let range = result.range(of: "&#x?[0-9a-fA-F]+;", options: .regularExpression) {
            let entity = result[range]
            let digits = entity.dropFirst(2).dropLast()
            let scalar: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                scalar = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(digits)
            }
            let replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(
            of: "\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let match = String(tag[range])
        guard let quote = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(match[match.index(after: quote)...].dropLast())
    }
}
