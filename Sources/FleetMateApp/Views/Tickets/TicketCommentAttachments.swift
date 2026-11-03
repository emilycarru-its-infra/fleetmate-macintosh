import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FleetMateCore

// MARK: - Pending attachment

/// A file chosen for the next comment, not yet uploaded: a file on disk, or
/// image data pasted or dragged in from another app.
struct PendingCommentAttachment: Identifiable, Equatable {
    enum Source: Equatable {
        case file(URL)
        case data(Data)
    }

    let id = UUID()
    let fileName: String
    let source: Source

    init(fileURL: URL) {
        self.fileName = fileURL.lastPathComponent
        self.source = .file(fileURL)
    }

    init(imageData: Data, fileName: String) {
        self.fileName = fileName
        self.source = .data(imageData)
    }

    var byteCount: Int64? {
        switch source {
        case .data(let data):
            return Int64(data.count)
        case .file(let url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }
    }

    var sizeLabel: String {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    var iconName: String {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .text) == true { return "doc.text" }
        return "doc"
    }

    /// The bytes to upload. Reads the file now rather than when it was
    /// chosen, so a file edited after attaching goes up as it is at Post.
    func loadData() throws -> Data {
        switch source {
        case .data(let data):
            return data
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    /// "Pasted Image 2026-11-03 at 14.05.09.png", after the screenshot naming
    /// macOS uses, so pasted images arrive on the ticket with a useful name.
    static func pastedImageName(at date: Date = Date(), index: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let suffix = index > 0 ? " \(index + 1)" : ""
        return "Pasted Image \(formatter.string(from: date))\(suffix).png"
    }
}

// MARK: - Pasteboard reading

enum CommentPasteboard {
    /// File URLs on a pasteboard — what Finder puts there for Copy and drags.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// An image on the pasteboard as PNG data, the format TDX previews inline.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// What a paste or drop should attach: files first, then an image — but
    /// only an image that came without text, so copying a styled paragraph
    /// still pastes its words.
    static func attachments(from pasteboard: NSPasteboard) -> [PendingCommentAttachment] {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty { return files.map(PendingCommentAttachment.init(fileURL:)) }
        guard pasteboard.string(forType: .string) == nil, hasImage(pasteboard),
              let png = pngData(from: pasteboard) else { return [] }
        return [PendingCommentAttachment(imageData: png, fileName: PendingCommentAttachment.pastedImageName())]
    }
}

// MARK: - Comment text view

/// The comment editor: a plain-text `NSTextView` that also takes files.
///
/// SwiftUI's `TextEditor` can't be used here because its text view claims
/// every file drag for itself and inserts the file's path as text, and it
/// refuses to paste an image. This keeps all of `NSTextView`'s editing,
/// spelling and undo, and turns a dropped or pasted file or image into an
/// attachment instead.
struct CommentTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Set true to put the cursor in the editor; it resets itself once the
    /// editor has focus, so clicking elsewhere afterwards isn't overridden.
    @Binding var focusRequested: Bool
    let fontSize: CGFloat
    let accessibilityLabel: String
    let onAttach: ([PendingCommentAttachment]) -> Void
    let onDropTargeted: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let original = scrollView.documentView as? NSTextView
        let textView = AttachingTextView(frame: original?.frame ?? .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onAttach = onAttach
        textView.onDropTargeted = onDropTargeted
        if textView.string != text {
            textView.string = text
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
        }
        if focusRequested {
            DispatchQueue.main.async {
                if let window = textView.window, window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
                focusRequested = false
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentTextEditor
        weak var textView: AttachingTextView?

        init(_ parent: CommentTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// `NSTextView` that hands files and images to the composer instead of
/// inserting them as text.
final class AttachingTextView: NSTextView {
    var onAttach: (([PendingCommentAttachment]) -> Void)?
    var onDropTargeted: ((Bool) -> Void)?

    // MARK: Paste

    override func paste(_ sender: Any?) {
        let found = CommentPasteboard.attachments(from: .general)
        if !found.isEmpty, let onAttach {
            onAttach(found)
        } else {
            super.paste(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           !CommentPasteboard.fileURLs(from: .general).isEmpty || CommentPasteboard.hasImage(.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Drag and drop

    private func carriesAttachments(_ info: NSDraggingInfo) -> Bool {
        let pasteboard = info.draggingPasteboard
        return !CommentPasteboard.fileURLs(from: pasteboard).isEmpty
            || (pasteboard.string(forType: .string) == nil && CommentPasteboard.hasImage(pasteboard))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesAttachments(sender) else { return super.draggingEntered(sender) }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesAttachments(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesAttachments(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard carriesAttachments(sender) else { return super.performDragOperation(sender) }
        onDropTargeted?(false)
        let found = CommentPasteboard.attachments(from: sender.draggingPasteboard)
        guard !found.isEmpty else { return false }
        onAttach?(found)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.concludeDragOperation(sender)
    }
}

// MARK: - Chips

/// One chosen file, shown as a removable chip under the comment editor.
struct CommentAttachmentChip: View {
    let attachment: PendingCommentAttachment
    let isDisabled: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.iconName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(attachment.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            if !attachment.sizeLabel.isEmpty {
                Text(attachment.sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)
            .help("Remove \(attachment.fileName)")
            .accessibilityLabel("Remove \(attachment.fileName)")
        }
        .appFont(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .help(attachment.fileName)
        .contextMenu {
            if case .file(let url) = attachment.source {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Remove", role: .destructive, action: onRemove).disabled(isDisabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment \(attachment.fileName)")
    }
}
