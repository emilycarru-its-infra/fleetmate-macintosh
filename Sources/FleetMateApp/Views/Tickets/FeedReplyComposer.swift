import AppKit
import SwiftUI

/// A reply being written under one feed entry. Kept per entry so closing the
/// composer, or replying in another thread, doesn't lose what was typed.
struct FeedReplyDraft: Equatable {
    var text = ""
    var attachments: [PendingCommentAttachment] = []

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { !hasText && attachments.isEmpty }
}

/// The inline composer that opens under a comment's thread.
///
/// TeamDynamix's reply endpoint (12.3+) takes a body and nothing else, so
/// unlike Add Comment there is no Private toggle and no Notify list. Files can
/// still come along: like a comment's, they go up to the ticket's Attachments
/// list first — private when the comment being answered is — and the text
/// posts only once every file has landed.
struct FeedReplyComposer: View {
    let parentAuthor: String?
    let parentIsPrivate: Bool
    @Binding var draft: FeedReplyDraft
    @Binding var focusRequested: Bool
    let isPosting: Bool
    let uploadProgress: (done: Int, total: Int)?
    let onPost: () -> Void
    let onCancel: () -> Void

    @Environment(\.appFontScale) private var appFontScale
    @State private var isPickingFiles = false
    @State private var isDropTargeted = false

    private var replyLabel: String {
        parentAuthor.map { "Reply to \($0)" } ?? "Reply"
    }

    private var canPost: Bool { (draft.hasText || !draft.attachments.isEmpty) && !isPosting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentTextEditor(
                text: $draft.text,
                focusRequested: $focusRequested,
                fontSize: (AppTextStyle.callout.basePointSize * CGFloat(AppFontScale.clamp(appFontScale))).rounded(),
                accessibilityLabel: replyLabel,
                onAttach: addAttachments,
                onDropTargeted: { isDropTargeted = $0 }
            )
            .frame(height: 64)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isDropTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                            lineWidth: isDropTargeted ? 2 : 1)
            )

            if !draft.attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(draft.attachments) { attachment in
                        CommentAttachmentChip(attachment: attachment, isDisabled: isPosting) {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(draft.attachments.count) attachment\(draft.attachments.count == 1 ? "" : "s")")
            }

            HStack(spacing: 10) {
                let post = Button(draft.attachments.isEmpty ? "Post Reply" : "Post Reply with Attachments", action: onPost)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canPost)
                    .help(draft.attachments.isEmpty ? "Post this reply in the thread (⌘Return)"
                          : "Upload the files to the ticket, then post the reply (⌘Return)")
                if canPost {
                    post.buttonStyle(.borderedProminent)
                } else {
                    post.buttonStyle(.bordered)
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the reply; the draft is kept (Escape)")
                Button {
                    isPickingFiles = true
                } label: {
                    Label("Attach…", systemImage: "paperclip")
                }
                .disabled(isPosting)
                .help("Attach files to the ticket with this reply — or drag them onto the reply, or paste an image")
                if isPosting {
                    ProgressView().controlSize(.small)
                    if let uploadProgress {
                        Text("Uploading \(min(uploadProgress.done + 1, uploadProgress.total)) of \(uploadProgress.total)…")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .fileImporter(isPresented: $isPickingFiles,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    addAttachments(urls.map(PendingCommentAttachment.init(fileURL:)))
                }
            }

            Text(parentIsPrivate
                 ? "Joins this private comment's thread. Replies can't notify anyone or set their own visibility."
                 : "Joins this comment's thread. Replies can't notify anyone or set their own visibility.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        // The editor takes drops itself; this catches files dropped on the
        // buttons and chips around it.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { addAttachments([PendingCommentAttachment(fileURL: url)]) }
                }
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(replyLabel)
    }

    private func addAttachments(_ added: [PendingCommentAttachment]) {
        let existing = Set(draft.attachments.compactMap { attachment -> URL? in
            if case .file(let url) = attachment.source { return url.standardizedFileURL }
            return nil
        })
        var pastedIndex = 0
        for attachment in added {
            switch attachment.source {
            case .file(let url):
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue, !existing.contains(url.standardizedFileURL) else { continue }
                draft.attachments.append(attachment)
            case .data(let data):
                let taken = Set(draft.attachments.map(\.fileName))
                var name = attachment.fileName
                while taken.contains(name) {
                    pastedIndex += 1
                    name = PendingCommentAttachment.pastedImageName(index: pastedIndex)
                }
                draft.attachments.append(PendingCommentAttachment(imageData: data, fileName: name))
            }
        }
    }
}
