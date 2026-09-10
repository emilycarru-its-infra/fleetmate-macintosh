import SwiftUI
import AppKit
import FleetMateCore

/// Tints the Manage tab uses for state: soft so a room of forty rows does
/// not shout.
extension Color {
    static let manageSuccess = Color.green.opacity(0.72)
    static let manageWarning = Color.orange.opacity(0.72)
    static let manageFailure = Color.red.opacity(0.72)
    static let manageInfo = Color.blue.opacity(0.70)
    static let manageSelection = Color.accentColor.opacity(0.10)
}

/// A small tinted pill with an optional symbol: an address, a readiness
/// state, a scan mode.
struct StatusCapsule: View {
    let text: String
    var systemImage: String? = nil
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .appFont(fixed: 9, weight: .medium)
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 11, height: 11, alignment: .center)
            }
            Text(text)
                .appFont(.caption2, weight: .medium)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct CountBadge: View {
    let value: Int
    var tint: Color = .secondary

    var body: some View {
        Text("\(value)")
            .appFont(.caption2, weight: .semibold)
            .foregroundColor(tint)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A file path with a Choose… button beside it.
struct PathPickerRow: View {
    let label: String
    @Binding var value: String
    var placeholder: String = ""
    var buttonLabel: String = "Choose…"
    var allowedExtensions: [String] = []

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 120, alignment: .leading)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .appFont(.footnote, design: .monospaced)
                .truncationMode(.middle)
            Button(buttonLabel) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                panel.title = buttonLabel
                if panel.runModal() == .OK, let url = panel.url {
                    value = url.path
                }
            }
            .controlSize(.small)
        }
    }
}

enum ManageClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ScanMode {
    var tint: Color {
        switch self {
        case .reportMate: .manageSuccess
        case .mdnsOnly: .manageInfo
        case .limited: .manageWarning
        case .unknown: .secondary
        }
    }
}

extension CommandRunStatus {
    var tint: Color {
        switch self {
        case .pending, .cancelled: .secondary
        case .running: .manageInfo
        case .success: .manageSuccess
        case .failed, .authFailed: .manageFailure
        case .offline: .gray
        case .timeout: .manageWarning
        }
    }
}
