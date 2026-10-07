import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FleetMateCore

/// The Serials popover beside Filters: type, paste or import a list, and the
/// Devices list shows only those devices plus a "Not Found" row for each
/// serial no system knows.
struct SerialLookupView: View {
    @Binding var text: String
    /// The applied list; empty when no lookup is active.
    @Binding var serials: [String]
    /// How many of the applied serials no system knows.
    let unknownCount: Int

    private var parsed: [String] { SerialList.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Look Up Serials").appFont(.headline)
            Text("One serial per line, or separated by commas. A CSV is read by its serial column.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .appFont(.body, design: .monospaced)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

            HStack(spacing: 8) {
                Button("Import File…", action: importFile)
                    .controlSize(.small)
                Spacer()
                if !serials.isEmpty {
                    Button("Clear") {
                        text = ""
                        serials = []
                    }
                    .controlSize(.small)
                }
                Button(parsed.isEmpty ? "Show Devices" : "Show \(parsed.count) Device\(parsed.count == 1 ? "" : "s")") {
                    serials = parsed
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(parsed.isEmpty || parsed == serials)
            }

            if !serials.isEmpty {
                Text(summary)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var summary: String {
        let listed = "\(serials.count) serial\(serials.count == 1 ? "" : "s") listed"
        return unknownCount == 0 ? "\(listed), all found." : "\(listed), \(unknownCount) not found in any system."
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a text or CSV file of serial numbers"
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8)
                ?? String(contentsOf: url, encoding: .isoLatin1) else { return }
        text = contents
        serials = SerialList.parse(contents)
    }
}
