import SwiftUI
import MarkdownUI
import AppKit
import FleetMateCore

// MARK: - Shared Markdown / HTML Renderer

/// Renders rich text content — auto-detects HTML vs Markdown.
/// Used globally across FleetMate for all description, comment, and paragraph fields.
///
/// - **HTML content** (from Azure DevOps): converted by `HtmlToMarkdown`, then MarkdownUI.
/// - **Markdown content** (from GitHub, Gitea, user input): rendered via `MarkdownUI`.
struct MarkdownTextView: View {
    let content: String
    /// A whole document (a Handbook page, a SKILL.md) rather than a comment:
    /// real heading sizes and paragraph spacing.
    var document: Bool = false
    /// Where a clicked link goes. Documents (Handbook pages, skills) come from
    /// repositories many people edit, so without a handler they open only
    /// http(s) links, in the browser; file:, custom app schemes and the rest
    /// are dropped (see `HandbookLinks`).
    var onLink: ((URL) -> OpenURLAction.Result)? = nil
    /// For documents, the one host images may load from (the Handbook site).
    /// Without it a document shows no remote images.
    var imageSite: String? = nil

    private var theme: MarkdownUI.Theme { document ? .fleetMateDocument : .fleetMate }

    var body: some View {
        if document {
            rendered
                .markdownImageProvider(SiteImageProvider(siteURL: imageSite))
                .environment(\.openURL, OpenURLAction { url in
                    if let onLink { return onLink(url) }
                    return HandbookLinks.external(url) != nil ? .systemAction : .discarded
                })
        } else {
            rendered
        }
    }

    @ViewBuilder
    private var rendered: some View {
        if content.isEmpty {
            Text("No content")
                .appFont(.body)
                .foregroundColor(.secondary)
                .italic()
        } else if isHtml(content) {
            // ADO HTML is converted to Markdown and rendered by the same
            // renderer as everything else. The old path (NSAttributedString →
            // SwiftUI Text) discarded paragraph styles: tables flattened to a
            // line per cell, bullets lost their indent, paragraphs their air.
            Markdown(HtmlToMarkdown.convert(content))
                .markdownTheme(theme)
                .textSelection(.enabled)
        } else {
            Markdown(content)
                .markdownTheme(theme)
                .textSelection(.enabled)
        }
    }

    /// Detect HTML by checking for common HTML tags (not just any angle brackets).
    private func isHtml(_ text: String) -> Bool {
        let htmlPattern = #"<\s*(div|p|br|h[1-6]|ul|ol|li|span|a|img|table|tr|td|th|pre|code|em|strong|b|i|hr)\b"#
        return text.range(of: htmlPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Images in a document load only over http(s) from the Handbook site's own
/// host; anything else renders as nothing.
private struct SiteImageProvider: ImageProvider {
    let siteURL: String?

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if HandbookLinks.allowsImage(url, siteURL: siteURL) {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            EmptyView()
        }
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

extension MarkdownUI.Theme {
    /// For full documents: the comment theme plus a heading scale, air
    /// between blocks, padded table cells and a rule under the top headings.
    static let fleetMateDocument = Theme.fleetMate
        .heading1 { configuration in
            VStack(alignment: .leading, spacing: 6) {
                configuration.label
                    .markdownTextStyle { FontWeight(.bold); FontSize(24) }
                Divider()
            }
            .markdownMargin(top: 20, bottom: 10)
        }
        .heading2 { configuration in
            VStack(alignment: .leading, spacing: 5) {
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(19) }
                Divider()
            }
            .markdownMargin(top: 22, bottom: 8)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(16) }
                .markdownMargin(top: 16, bottom: 6)
        }
        .heading4 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(14) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .paragraph { configuration in
            configuration.label
                .lineSpacing(3)
                .markdownMargin(top: 0, bottom: 12)
        }
        .list { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 12)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 3, bottom: 3)
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.secondary.opacity(0.06), Color.clear)
                )
                .markdownMargin(top: 0, bottom: 14)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .codeBlock { configuration in
            CodeBlockWithCopy(configuration: configuration)
                .markdownMargin(top: 0, bottom: 14)
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
