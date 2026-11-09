import AppKit
import FleetMateCore
import SwiftUI

struct TeamsPostPreview: View {
    let hit: TeamsSearchHit
    let selected: Bool
    let saved: Bool
    let canSave: Bool
    let open: () -> Void
    let save: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                TeamsAuthorBadge(name: hit.authorDisplayName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(TeamsText.line(hit.authorDisplayName ?? "Unknown author")).fontWeight(.semibold)
                    Text(TeamsDates.full(hit.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(TeamsDates.relative(hit.lastActivityAt)).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: open) {
                Text(hit.title).font(.title3).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(TeamsText.body(hit.snippet)).lineLimit(6).lineSpacing(3).textSelection(.enabled)
            Text("\(TeamsText.line(hit.teamName)) › \(TeamsText.line(hit.channelName))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1))
        .contextMenu {
            Button("Read Thread", action: open)
            Button("Copy Preview", action: copy)
            Button(saved ? "Edit Bookmark" : "Save Thread", action: save).disabled(!canSave)
        }
    }

    @ViewBuilder private var actions: some View {
        Button(hit.replyCount > 0 ? "\(hit.replyCount) replies · Read thread" : "Read Thread",
               systemImage: "bubble.left", action: open)
        Button("Copy Preview", systemImage: "doc.on.doc", action: copy)
        Button(saved ? "Saved" : "Save", systemImage: saved ? "bookmark.fill" : "bookmark", action: save)
            .disabled(!canSave)
    }
}

struct TeamsConversationView: View {
    let hit: TeamsSearchHit?
    let thread: TeamsThread?
    let isLoading: Bool
    let error: String?
    let linkHosts: [String]
    let saved: Bool
    let canSave: Bool
    let copy: (String) -> Void
    let save: () -> Void
    let retry: () -> Void
    @State private var showReplies = false

    private var root: TeamsMessage? {
        thread?.messages.first(where: { $0.replyToId == nil }) ?? thread?.messages.first
    }
    private var replies: [TeamsMessage] {
        thread?.messages.filter { $0.messageId != root?.messageId } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error {
                ContentUnavailableView {
                    Label("Thread Unavailable", systemImage: "exclamationmark.bubble")
                } description: { Text(error) } actions: { Button("Try Again", action: retry) }
            } else if isLoading {
                ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ConversationThreadRow(author: TeamsText.line(root.authorDisplayName), isReply: false,
                                              connector: showReplies && !replies.isEmpty ? .elbow : .none) {
                            VStack(alignment: .leading, spacing: 8) {
                                TeamsMessageCard(message: root, isRoot: true, linkHosts: linkHosts, copy: copy)
                                if !replies.isEmpty {
                                    Button {
                                        showReplies.toggle()
                                    } label: {
                                        Label(showReplies ? "Hide replies" : (replies.count == 1 ? "Show 1 reply" : "Show \(replies.count) replies"),
                                              systemImage: showReplies ? "chevron.up" : "chevron.down")
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                        if showReplies {
                            ForEach(Array(replies.enumerated()), id: \.element.messageId) { index, message in
                                ConversationThreadRow(author: TeamsText.line(message.authorDisplayName), isReply: true,
                                                      connector: index == replies.count - 1 ? .none : .straight) {
                                    TeamsMessageCard(message: message, isRoot: false, linkHosts: linkHosts, copy: copy)
                                }
                            }
                        }
                    }.padding(16)
                }
            } else {
                ContentUnavailableView("No Thread Selected", systemImage: "bubble.left")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TeamsText.line(thread?.subject ?? hit?.title ?? "Conversation"))
                .font(.headline).lineLimit(2).textSelection(.enabled)
            if let hit {
                Text("\(TeamsText.line(hit.teamName)) › \(TeamsText.line(hit.channelName))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            FlowLayout(spacing: 8) {
                Button("Copy Thread", systemImage: "doc.on.doc") {
                    if let thread { copy(TeamsThreadCopy.thread(thread, allowedHosts: linkHosts)) }
                }
                .disabled(thread == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the full conversation with source (⇧⌘C)")
                Button("Copy Markdown", systemImage: "text.document") {
                    if let thread { copy(TeamsThreadCopy.thread(thread, allowedHosts: linkHosts, markdown: true)) }
                }.disabled(thread == nil)
                Button("Copy Link", systemImage: "link") {
                    if let source { copy(source.absoluteString) }
                }.disabled(source == nil)
                Button(saved ? "Edit Bookmark" : "Save Thread", systemImage: saved ? "bookmark.fill" : "bookmark", action: save)
                    .disabled(!canSave || hit == nil)
                Button("Open in Teams", systemImage: "arrow.up.right.square") {
                    if let source { NSWorkspace.shared.open(source) }
                }
                .disabled(source == nil)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .help("Open in Teams (⇧⌘O)")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }.padding(12)
    }

    private var source: URL? {
        TeamsLinkPolicy.safeURL(thread?.webUrl ?? hit?.webUrl, allowedHosts: linkHosts)
    }
}

private struct TeamsMessageCard: View {
    let message: TeamsMessage
    let isRoot: Bool
    let linkHosts: [String]
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TeamsText.line(message.authorDisplayName ?? "Unknown author")).fontWeight(.semibold)
                    HStack {
                        Text(TeamsDates.full(message.createdAt))
                        if message.editedAt != nil { Text("Edited") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { copy(TeamsThreadCopy.message(message, allowedHosts: linkHosts)) } label: {
                    Label("Copy Message", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).help("Copy message with author, time and source")
            }
            Text(TeamsText.body(message.text))
                .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                if let url = TeamsLinkPolicy.safeURL(attachment.url, allowedHosts: linkHosts) {
                    Link(destination: url) { Label(TeamsText.line(attachment.name), systemImage: "paperclip") }
                } else {
                    Label(TeamsText.line(attachment.name), systemImage: "paperclip").foregroundStyle(.secondary)
                }
            }
            if let url = TeamsLinkPolicy.safeURL(message.webUrl, allowedHosts: linkHosts) {
                HStack {
                    Spacer()
                    Button("Copy Message Link") { copy(url.absoluteString) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .modifier(ConversationCardStyle(isReply: !isRoot))
        .contextMenu {
            Button("Copy Message") { copy(TeamsThreadCopy.message(message, allowedHosts: linkHosts)) }
            Button("Copy as Markdown") { copy(TeamsThreadCopy.message(message, allowedHosts: linkHosts, markdown: true)) }
        }
    }
}

private struct TeamsAuthorBadge: View {
    let name: String?
    private var initials: String {
        let words = TeamsText.line(name).split(separator: " ")
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
    var body: some View {
        Text(initials).font(.caption).fontWeight(.semibold)
            .frame(width: 32, height: 32)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}
