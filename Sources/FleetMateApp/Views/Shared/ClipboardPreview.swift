import AppKit
import SwiftUI
import FleetMateCore

/// One preview per application. A subsequent copy replaces it and restarts the timeout.
@MainActor
final class ClipboardPreview {
    private static let shared = ClipboardPreview()
    private var popover: NSPopover?
    private var dismissal: Task<Void, Never>?

    static func show(_ text: String, heading: String = "Copied", anchor: NSView? = nil) {
        // Menu actions finish tracking before the popover takes focus.
        DispatchQueue.main.async { shared.present(text, heading: heading, source: anchor) }
    }

    private func present(_ text: String, heading: String, source: NSView?) {
        dismissal?.cancel()
        popover?.close()
        guard let window = source?.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let anchor = window.contentView else { return }
        let preview = NSPopover()
        preview.behavior = .transient
        preview.contentViewController = NSHostingController(rootView:
            VStack(alignment: .leading, spacing: 10) {
                Label(heading, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Closes after 5 seconds")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 460, height: min(320, max(130, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count) * 16 + 86)))
        )
        let mouse = anchor.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let point = NSPoint(x: min(max(mouse.x, 1), anchor.bounds.width - 1),
                            y: min(max(mouse.y, 1), anchor.bounds.height - 1))
        if let source, source.window === window {
            preview.show(relativeTo: source.bounds, of: source, preferredEdge: .minY)
        } else {
            preview.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: anchor, preferredEdge: .minY)
        }
        popover = preview
        dismissal = Task { [weak self, weak preview] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.popover === preview else { return }
            preview?.close()
            self.popover = nil
        }
    }
}

@MainActor
final class ClipboardAnchor: ObservableObject {
    weak var view: NSView?
}

struct ClipboardAnchorView: NSViewRepresentable {
    let anchor: ClipboardAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

struct CopyTitleLinkButton: View {
    @StateObject private var anchor = ClipboardAnchor()
    let title: String
    let link: String?

    var body: some View {
        Button {
            guard let link, let payload = TitleLinkCopy(title: title, link: link) else { return }
            let item = NSPasteboardItem()
            item.setString(payload.text, forType: .string)
            item.setString(payload.html, forType: .html)
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([item]) {
                ClipboardPreview.show(payload.text, heading: "Copied title and link", anchor: anchor.view)
            }
        } label: {
            Image(systemName: "square.on.square")
        }
        .buttonStyle(.plain)
        .background(ClipboardAnchorView(anchor: anchor).accessibilityHidden(true))
        .disabled(link.flatMap { TitleLinkCopy(title: title, link: $0) } == nil)
        .help("Copy title and link")
        .accessibilityLabel("Copy title and link")
    }
}
