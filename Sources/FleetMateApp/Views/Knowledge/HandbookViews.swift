import SwiftUI
import AppKit
import FleetMateCore

/// A Handbook page read inside FleetMate — the same text staff read on the
/// site, from FleetMate's own copy of `main`.
struct HandbookReaderView: View {
    @ObservedObject var knowledge: KnowledgeStore
    let page: HandbookPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).appFont(.title3, weight: .semibold)
                    Text(page.breadcrumb.isEmpty ? "Handbook" : "Handbook › \(page.breadcrumb)")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = knowledge.siteURL(for: page), HandbookLinks.isWeb(url) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open on Site", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let modified = page.lastModified {
                        Text("Updated \(modified)\(page.lastModifiedBy.map { " by \($0)" } ?? "")")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownTextView(content: page.body, document: true,
                                     linkPolicy: { HandbookLinks.classify($0, from: page, index: knowledge.handbook,
                                                                          siteURL: knowledge.siteAddress) },
                                     openPage: { knowledge.openPage = $0 },
                                     imageSite: knowledge.siteAddress)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 760)
    }
}

/// Presents whichever Handbook page the knowledge store says is open.
struct HandbookReaderHost: ViewModifier {
    @ObservedObject var knowledge: KnowledgeStore

    func body(content: Content) -> some View {
        content.sheet(item: $knowledge.openPage) { page in
            HandbookReaderView(knowledge: knowledge, page: page)
        }
    }
}

/// "Handbook" card: the pages about the thing on screen, found from the
/// words that describe it. Hidden when nothing relevant turns up.
struct HandbookRelatedSection: View {
    @ObservedObject var knowledge: KnowledgeStore
    let terms: [String]

    private var pages: [HandbookPage] { knowledge.handbook.related(to: terms, limit: 5) }

    var body: some View {
        let pages = self.pages
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Handbook", systemImage: "book.closed")
                    .appFont(.headline)
                ForEach(pages) { page in
                    Button { knowledge.openPage = page } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(page.title).appFont(.callout, weight: .medium)
                            Text(page.breadcrumb).appFont(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
