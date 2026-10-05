import SwiftUI
import AppKit
import FleetMateCore

/// Fetches one recovery secret when it opens and shows it until it closes.
///
/// The value lives only in this sheet's state: it is never written to the
/// device cache, a table, an export or the debug log, and it is dropped the
/// moment the sheet disappears.
struct RecoverySecretSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let kind: RecoverySecretKind
    let device: IntuneDevice

    @State private var secrets: [RevealedSecret] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var copiedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: kind.systemImage)
                    .appFont(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .appFont(.headline)
                    Text(device.deviceName ?? device.serialNumber ?? "Device")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Group {
                if isLoading {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Retrieving…").appFont(.caption).foregroundColor(.secondary)
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .appFont(.caption)
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                } else {
                    ForEach(secrets) { secret in
                        secretRow(secret)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Shown only while this sheet is open. Not saved or logged; a copied value is hidden from clipboard history and cleared after a minute.")
                .appFont(.caption2)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .task { await load() }
        .onDisappear {
            secrets = []
            copiedId = nil
        }
    }

    private func secretRow(_ secret: RevealedSecret) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(secret.label)
                .appFont(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(secret.value)
                    .appFont(.body, design: .monospaced)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    SecretPasteboard.copy(secret.value)
                    copiedId = secret.id
                } label: {
                    Label(copiedId == secret.id ? "Copied" : "Copy",
                          systemImage: copiedId == secret.id ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            if let detail = secret.detail {
                Text(detail)
                    .appFont(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let serial = device.serialNumber ?? device.id
        do {
            secrets = try await appState.graphService.revealRecoverySecret(kind, for: device)
            // Record that a reveal happened, never what was revealed.
            dbg.info("Revealed \(kind.rawValue) for \(serial)", category: "devices")
        } catch {
            errorMessage = "\(error)"
            dbg.warn("Could not reveal \(kind.rawValue) for \(serial)", category: "devices")
        }
    }
}

/// Copies a secret so it does not outlive its use on the clipboard.
///
/// The value is marked concealed and transient (the nspasteboard.org
/// convention), so clipboard managers skip it rather than keep it in their
/// history, and it is cleared after `lifetime` unless something else has been
/// copied since.
enum SecretPasteboard {
    static let lifetime: Duration = .seconds(60)

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @MainActor
    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: concealed)
        pasteboard.setString("", forType: transient)
        let changeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: lifetime)
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
    }
}
