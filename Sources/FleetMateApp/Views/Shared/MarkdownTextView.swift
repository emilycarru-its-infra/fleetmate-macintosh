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
    #if !TICKETSMATE
    /// How a clicked link in a document is classified. Documents (Handbook
    /// pages, skills) come from repositories many people edit, so every link
    /// goes through `HandbookLinks`: the default opens only http(s) links. The
    /// view itself opens whatever the classification allows; a caller can
    /// choose which page opens, never which URL reaches the system.
    var linkPolicy: ((URL) -> HandbookLinkAction)? = nil
    /// Opens a Handbook page the policy matched.
    var openPage: ((HandbookPage) -> Void)? = nil
    #endif
    /// Ticket text: written by anyone who can comment, so remote images
    /// load from TeamDynamix and `imageSite` only, unless the person has
    /// chosen to load images from other sites.
    var ticketContent: Bool = false
    /// The one host images may load from beyond TeamDynamix: for a
    /// document, the Handbook site. Without it a document shows no remote
    /// images, and ticket text shows them from TeamDynamix only.
    var imageSite: String? = nil
    @Environment(\.remoteImageAccess) private var remoteImages
    @AppStorage(FeedBodyView.loadExternalImagesKey) private var loadExternalImages = false

    private var theme: MarkdownUI.Theme { document ? .fleetMateDocument : .fleetMate }

    var body: some View {
        #if TICKETSMATE
        inline
        #else
        if document {
            rendered
                .markdownImageProvider(SiteImageProvider(siteURL: imageSite))
                .environment(\.openURL, OpenURLAction { url in follow(url) })
        } else {
            inline
        }
        #endif
    }

    /// Links open only in the browser or mail client, whatever the text.
    private var inline: some View {
        policedImages
            .environment(\.openURL, OpenURLAction { url in
                MarkdownContentPolicy.allowsLink(url) ? .systemAction(url) : .discarded
            })
    }

    /// In ticket text a remote image is a tracking pixel until shown
    /// otherwise: it loads from TeamDynamix or `imageSite`, or from elsewhere
    /// once the person allows it, and always through the TDX image fetch's
    /// checks. Other text loads its images as MarkdownUI does.
    @ViewBuilder
    private var policedImages: some View {
        #if TICKETSMATE
        let restrict = true
        #else
        let restrict = ticketContent
        #endif
        if restrict {
            let policy = MarkdownImagePolicy(access: remoteImages, site: imageSite, allowExternal: loadExternalImages)
            rendered
                .markdownImageProvider(PolicedImageProvider(policy: policy))
                .markdownInlineImageProvider(PolicedInlineImageProvider(policy: policy))
        } else {
            rendered
        }
    }

    #if !TICKETSMATE
    private func follow(_ url: URL) -> OpenURLAction.Result {
        let action = linkPolicy?(url) ?? HandbookLinks.external(url).map(HandbookLinkAction.openInBrowser) ?? .ignore
        switch action {
        case .openPage(let page):
            guard let openPage else { return .discarded }
            openPage(page)
            return .handled
        case .openInBrowser(let web) where HandbookLinks.isWeb(web):
            // Exactly the address the allow-list produced, not the one clicked.
            return .systemAction(web)
        default:
            return .discarded
        }
    }
    #endif

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

#if !TICKETSMATE
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
#endif

// MARK: - Remote images

/// How rendered text reaches remote images: the TDX host's address, and a
/// loader that fetches through `TdxService.fetchBodyImage`, which sends the
/// TDX session only to that host and refuses non-public addresses. Set once
/// on the main window; without it no remote image loads.
struct RemoteImageAccess {
    var tdxBase: URL?
    var load: @MainActor (URL) async -> Data?
}

private struct RemoteImageAccessKey: EnvironmentKey {
    static let defaultValue: RemoteImageAccess? = nil
}

extension EnvironmentValues {
    var remoteImageAccess: RemoteImageAccess? {
        get { self[RemoteImageAccessKey.self] }
        set { self[RemoteImageAccessKey.self] = newValue }
    }
}

private struct MarkdownImagePolicy {
    let access: RemoteImageAccess?
    let site: String?
    let allowExternal: Bool

    /// The loader, when `url` may load at all.
    func loader(for url: URL?) -> ((URL) async -> Data?)? {
        guard let access, let url,
              MarkdownContentPolicy.allowsImage(url, tdxBase: access.tdxBase, site: site, allowExternal: allowExternal)
        else { return nil }
        return { await access.load($0) }
    }
}

private struct PolicedImageProvider: ImageProvider {
    let policy: MarkdownImagePolicy

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, let load = policy.loader(for: url) {
            PolicedRemoteImage(url: url, load: load)
        } else if let host = url?.host {
            Label("Image from \(host) not loaded", systemImage: "photo")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .help("Images from other sites load once Settings ▸ Authentication allows them")
        }
    }
}

private struct PolicedInlineImageProvider: InlineImageProvider {
    let policy: MarkdownImagePolicy

    func image(with url: URL, label: String) async throws -> Image {
        guard let load = policy.loader(for: url),
              let data = await load(url), TdxImageType.sniff(data) != nil,
              let image = NSImage(data: data), image.isValid else { throw URLError(.cancelled) }
        return Image(nsImage: image)
    }
}

private struct PolicedRemoteImage: View {
    let url: URL
    let load: (URL) async -> Data?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: image.size.width)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .task(id: url) {
            guard let data = await load(url), TdxImageType.sniff(data) != nil,
                  let fetched = NSImage(data: data), fetched.isValid else { return }
            image = fetched
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

#if !TICKETSMATE
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
#endif
