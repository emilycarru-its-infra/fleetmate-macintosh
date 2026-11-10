import AppKit
import QuickLookUI
import SwiftUI
import FleetMateCore

struct WorkItemAttachmentButton: View {
    let attachment: WorkItemAttachment
    let access: AttachmentAccess
    /// Revalidates the current provider identity before accessing an attachment.
    let authorize: () async throws -> AttachmentAuthorization
    @State private var operation: Task<Void, Never>?
    @State private var download: AttachmentDownload?
    @State private var preview: AttachmentPreviewItem?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                Label(attachment.name, systemImage: "paperclip")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Quick Look \(attachment.name)")
            .disabled(loading)
            Spacer(minLength: 4)
            if loading {
                ProgressView().controlSize(.small)
                Button("Cancel") { operation?.cancel() }.controlSize(.small)
            }
            Button { NSWorkspace.shared.openInBrowser(attachment.url) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("Open original attachment in browser")
        }
        .sheet(item: $preview, onDismiss: { download = nil }) { item in
            VStack(spacing: 0) {
                HStack {
                    Text(attachment.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button("Save As…") { save(item.url) }
                    Button("Open in Browser") { NSWorkspace.shared.openInBrowser(attachment.url) }
                    Button("Done") { preview = nil }.keyboardShortcut(.cancelAction)
                }.padding(12)
                Divider()
                AttachmentQuickLook(url: item.url)
            }
            .frame(minWidth: 640, minHeight: 480)
        }
        .alert("Attachment preview", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Open in Browser") { NSWorkspace.shared.openInBrowser(attachment.url) }
            Button("Cancel", role: .cancel) { }
        } message: { Text(error ?? "") }
        .onDisappear { operation?.cancel(); download?.cancel(); download = nil; preview = nil }
    }

    private func open() {
        operation?.cancel()
        loading = true
        operation = Task { @MainActor in
            defer { loading = false }
            do {
                let authorization = try await authorize()
                try Task.checkCancellation()
                let loader = try AttachmentDownload(access: access, name: attachment.name)
                download = loader
                let url = try await loader.download(authorization.url, token: authorization.token)
                try Task.checkCancellation()
                preview = AttachmentPreviewItem(url: url)
            } catch is CancellationError {
                download = nil
            } catch {
                if !Task.isCancelled { self.error = (error as? AttachmentDownload.DownloadError)?.localizedDescription ?? "The attachment couldn't be previewed. Open the original in your browser or try again." }
                download = nil
            }
        }
    }

    private func save(_ source: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (attachment.name as NSString).lastPathComponent
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            do {
                // A save is an explicit copy; never launch a downloaded local file.
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch { self.error = "The attachment couldn't be saved." }
        }
    }
}

private struct AttachmentPreviewItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct AttachmentQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct AttachmentAuthorization {
    let url: URL
    let token: String?
}
