import SwiftUI
import FleetMateCore
import QuickLookUI

/// The files on a ticket, with open and save-to-disk.
struct TicketAttachmentsView: View {
    @EnvironmentObject var appState: AppState

    let attachments: [TdxAttachment]

    @State private var busyId: String?
    @State private var errorMessage: String?
    /// Folded by default — the file list is reference material, and on a busy
    /// ticket it pushes the comment box and activity below the fold.
    @State private var isExpanded = false
    /// The staged file being previewed in the Quick Look popover, keyed by the
    /// attachment id it belongs to so the popover anchors on the right row.
    @State private var preview: (attachmentId: String, url: URL)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Attachments")
                        .appFont(.headline)
                    Text(verbatim: "\(attachments.count)")
                        .appFont(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide attachments" : "Show \(attachments.count) attachment\(attachments.count == 1 ? "" : "s")")

            if isExpanded {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption)
                        .foregroundColor(.red)
                }

                VStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        row(for: attachment)
                    }
                }
            }
        }
    }

    private func row(for attachment: TdxAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.iconName)
                .appFont(.body)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(attachment.displayName)
                        .appFont(.body)
                        .lineLimit(1)
                    if attachment.isPrivate == true {
                        Text("Private")
                            .appFont(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundColor(.secondary)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle(for: attachment))
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if busyId == attachment.id {
                ProgressView().controlSize(.small)
            } else {
                Button(action: { open(attachment) }) {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .help("Preview \(attachment.displayName)")
                .popover(isPresented: Binding(
                    get: { preview?.attachmentId == attachment.id },
                    set: { if !$0 { preview = nil } }
                )) {
                    if let preview {
                        QuickLookPreview(url: preview.url)
                            .frame(width: 560, height: 640)
                    }
                }

                Button(action: { save(attachment) }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Save \(attachment.displayName) to disk")
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(attachment) }
    }

    private func subtitle(for attachment: TdxAttachment) -> String {
        var parts: [String] = []
        if !attachment.sizeLabel.isEmpty { parts.append(attachment.sizeLabel) }
        if let who = attachment.createdFullName, !who.isEmpty { parts.append(who) }
        if let dateStr = attachment.createdDate, let date = TicketsView.parseDate(dateStr) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            parts.append(formatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// Quick Look in a popover on the row, not a separate Preview window.
    private func open(_ attachment: TdxAttachment) {
        run(attachment) { url in
            preview = (attachmentId: attachment.id, url: url)
        }
    }

    private func save(_ attachment: TdxAttachment) {
        run(attachment) { url in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.displayName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                errorMessage = "Could not save \(attachment.displayName): \(error.localizedDescription)"
            }
        }
    }

    /// Download once, then hand the staged file to `action`.
    private func run(_ attachment: TdxAttachment, action: @escaping (URL) -> Void) {
        guard busyId == nil else { return }
        Task {
            busyId = attachment.id
            errorMessage = nil
            defer { busyId = nil }
            do {
                guard let url = try await appState.tdxService.stageAttachment(attachment) else {
                    errorMessage = "Could not download \(attachment.displayName)."
                    return
                }
                action(url)
            } catch {
                errorMessage = "Could not download \(attachment.displayName): \(error.localizedDescription)"
            }
        }
    }
}

/// A Quick Look preview embedded in SwiftUI — the same rendering the Space-bar
/// preview uses, but inline in a popover instead of a floating panel.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }
}
