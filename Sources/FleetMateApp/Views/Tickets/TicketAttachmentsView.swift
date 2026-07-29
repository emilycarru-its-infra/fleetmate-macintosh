import SwiftUI
import FleetMateCore
import QuickLookUI

/// The files on a ticket, with open and save-to-disk.
struct TicketAttachmentsView: View {
    @EnvironmentObject var appState: AppState

    let attachments: [TdxAttachment]

    @State private var busyId: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
                .help("Open \(attachment.displayName)")

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

    private func open(_ attachment: TdxAttachment) {
        run(attachment) { url in
            NSWorkspace.shared.open(url)
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
