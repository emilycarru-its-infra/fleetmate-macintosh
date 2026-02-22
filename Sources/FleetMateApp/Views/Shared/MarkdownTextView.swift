import SwiftUI
import MarkdownUI
import AppKit

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
                .font(.body)
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
                .font(.body)
                .textSelection(.enabled)
        } else {
            // Fallback: strip tags
            Text(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func htmlToAttributedString(_ html: String) -> AttributedString? {
        let wrapped = """
        <html><head><style>
        body { font-family: -apple-system, sans-serif; font-size: 13px; }
        pre, code { font-family: Menlo, monospace; font-size: 12px; background: #f5f5f5; padding: 2px 4px; border-radius: 3px; }
        img { max-width: 100%; height: auto; }
        a { color: #0366d6; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; }
        th { background: #f0f0f0; font-weight: 600; }
        blockquote { border-left: 3px solid #ddd; padding-left: 12px; color: #555; }
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
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            BackgroundColor(.secondary.opacity(0.1))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                    }
                    .padding(12)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                .font(.system(size: 14))
        }
}

// MARK: - Editable Markdown Field

/// A markdown field with Write/Preview toggle — used for editing descriptions, comments, etc.
struct EditableMarkdownField: View {
    let label: String
    @Binding var text: String
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $showPreview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                Spacer()
                Text("Markdown supported")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if showPreview {
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
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 400)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
        }
    }
}
