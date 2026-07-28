import SwiftUI
import MarkdownUI
import AppKit
import FleetMateCore

// MARK: - NSColor Hex Helper

private extension NSColor {
    /// Convert NSColor to CSS hex string, adapting to current appearance.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

// MARK: - Shared Markdown / HTML Renderer

/// Renders rich text content — auto-detects HTML vs Markdown.
/// Used globally across FleetMate for all description, comment, and paragraph fields.
///
/// - **HTML content** (from Azure DevOps): rendered via `NSAttributedString` (AppKit).
/// - **Markdown content** (from GitHub, Gitea, user input): rendered via `MarkdownUI`.
struct MarkdownTextView: View {
    let content: String

    var body: some View {
        if content.isEmpty {
            Text("No content")
                .appFont(.body)
                .foregroundColor(.secondary)
                .italic()
        } else if isHtml(content) {
            HtmlRenderedView(html: content)
        } else {
            Markdown(content)
                .markdownTheme(.fleetMate)
                .textSelection(.enabled)
        }
    }

    /// Detect HTML by checking for common HTML tags (not just any angle brackets).
    private func isHtml(_ text: String) -> Bool {
        let htmlPattern = #"<\s*(div|p|br|h[1-6]|ul|ol|li|span|a|img|table|tr|td|th|pre|code|em|strong|b|i|hr)\b"#
        return text.range(of: htmlPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - HTML Renderer (reuses HtmlTextView logic)

/// Renders HTML as styled NSAttributedString text.
private struct HtmlRenderedView: View {
    let html: String

    var body: some View {
        if let attributed = htmlToAttributedString(html) {
            Text(attributed)
                .appFont(.body)
                .textSelection(.enabled)
        } else {
            // Fallback: strip tags
            Text(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .appFont(.body)
                .textSelection(.enabled)
        }
    }

    private func htmlToAttributedString(_ html: String) -> AttributedString? {
        // Use system colors that adapt to light/dark mode
        let textColor = NSColor.labelColor.hexString
        let bgColor = NSColor.textBackgroundColor.hexString
        let codeFg = NSColor.secondaryLabelColor.hexString
        let linkColor = NSColor.controlAccentColor.hexString
        let borderColor = NSColor.separatorColor.hexString
        let headerBg = NSColor.unemphasizedSelectedContentBackgroundColor.hexString
        let secondaryText = NSColor.secondaryLabelColor.hexString

        let wrapped = """
        <html><head><style>
        body { font-family: -apple-system, sans-serif; font-size: 14px; color: \(textColor); background: \(bgColor); }
        pre { font-family: Menlo, monospace; font-size: 13px; color: \(codeFg); padding: 8px 12px; overflow-x: auto; }
        code { font-family: Menlo, monospace; font-size: 13px; color: \(codeFg); }
        pre code { padding: 0; }
        img { max-width: 100%; height: auto; }
        a { color: \(linkColor); }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid \(borderColor); padding: 6px 8px; text-align: left; }
        th { background: \(headerBg); font-weight: 600; }
        blockquote { border-left: 3px solid \(borderColor); padding-left: 12px; color: \(secondaryText); }
        </style></head><body>\(html)</body></html>
        """
        guard let data = wrapped.data(using: .utf8) else { return nil }
        guard let nsAttr = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else { return nil }
        return try? AttributedString(nsAttr, including: \.appKit)
    }
}

// MARK: - FleetMate Markdown Theme

extension MarkdownUI.Theme {
    /// FleetMate's standard Markdown theme — system font, proper spacing, styled code blocks.
    static let fleetMate = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            BackgroundColor(Color(NSColor.quaternaryLabelColor))
        }
        .codeBlock { configuration in
            CodeBlockWithCopy(configuration: configuration)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 12)
            }
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .image { configuration in
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color.secondary.opacity(0.05))
                )
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isCompleted ? .accentColor : .secondary)
                .appFont(fixed: 14)
        }
}

// MARK: - Code Block with Copy Button

/// A code block that overlays a copy button in the top-right corner.
private struct CodeBlockWithCopy: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                        ForegroundColor(Color(NSColor.labelColor))
                    }
                    .padding(12)
                    .padding(.trailing, 28) // make room for copy button
            }
            .background(Color(NSColor.quaternaryLabelColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button(action: copyCode) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .appFont(fixed: 11)
                    .foregroundColor(copied ? .green : .secondary)
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Copy code")
            .padding(6)
        }
    }

    private func copyCode() {
        let code = configuration.content
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Editable Markdown Field

/// A markdown field with Edit/Preview toggle — used for editing descriptions, comments, etc.
/// Set `hideToggle: true` and pass `showPreview` when the toggle is rendered externally (e.g., in a heading row).
struct EditableMarkdownField: View {
    var label: String? = nil
    @Binding var text: String
    var showPreview: Bool = false
    var hideToggle: Bool = false
    @State private var internalShowPreview = false

    private var isPreview: Bool { hideToggle ? showPreview : internalShowPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hideToggle {
                HStack {
                    Picker("", selection: $internalShowPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .controlSize(.small)
                    Spacer()
                }
            }

            if isPreview {
                ScrollView {
                    MarkdownTextView(content: text.isEmpty ? "*No content*" : text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 400)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            } else {
                TextEditor(text: $text)
                    .appFont(.body, design: .monospaced)
                    .frame(minHeight: 120, maxHeight: 400)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
        }
    }
}

// MARK: - Mention Text Editor (@ tagging)

/// A TextEditor with `@` mention popup. When user types `@`, shows a filtered list of team members.
/// Selecting a member inserts `@DisplayName` into the text.
struct MentionTextEditor: View {
    @Binding var text: String
    var members: [IdentityRef]
    var height: CGFloat = 80

    @State private var showMentionPopup = false
    @State private var mentionQuery = ""
    @State private var cursorTriggerIndex: String.Index?

    private var filteredMembers: [IdentityRef] {
        if mentionQuery.isEmpty {
            return members
        }
        let query = mentionQuery.lowercased()
        return members.filter {
            ($0.displayName ?? "").lowercased().contains(query) ||
            ($0.uniqueName ?? "").lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $text)
                .appFont(.body)
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: text) { _, newValue in
                    detectMentionTrigger(in: newValue)
                }

            if showMentionPopup && !filteredMembers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredMembers.prefix(8), id: \.uniqueName) { member in
                            Button(action: { insertMention(member) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.circle.fill")
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(member.displayName ?? "Unknown")
                                            .appFont(.body)
                                        if let email = member.uniqueName, email != member.displayName {
                                            Text(email)
                                                .appFont(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
        }
    }

    private func detectMentionTrigger(in value: String) {
        // Find the last `@` that isn't preceded by a word character
        guard let atIndex = value.lastIndex(of: "@") else {
            showMentionPopup = false
            return
        }
        let afterAt = value[value.index(after: atIndex)...]
        // If there's a space or newline after the query started, close the popup
        if afterAt.contains(" ") || afterAt.contains("\n") {
            showMentionPopup = false
            return
        }
        mentionQuery = String(afterAt)
        cursorTriggerIndex = atIndex
        showMentionPopup = !members.isEmpty
    }

    private func insertMention(_ member: IdentityRef) {
        guard let atIndex = cursorTriggerIndex else { return }
        let name = member.displayName ?? member.uniqueName ?? "Unknown"
        // Replace from @ to end-of-query with @Name
        let before = String(text[text.startIndex..<atIndex])
        text = before + "@\(name) "
        showMentionPopup = false
        mentionQuery = ""
        cursorTriggerIndex = nil
    }
}
