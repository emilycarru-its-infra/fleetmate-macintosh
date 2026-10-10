import SwiftUI
import FleetMateCore

/// Everything that ever happened to one asset, newest first — the same log
/// Snipe-IT's History tab shows: who, what, to whom, and each field's old and
/// new value.
struct AssetHistoryView: View {
    let assetId: Int
    let snipeService: SnipeService

    @State private var entries: [SnipeHistoryEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var filter = ""

    private var filtered: [SnipeHistoryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            [e.actionType, e.createdBy?.name, e.target?.name, e.note, e.file?.filename]
                .contains { $0?.localizedCaseInsensitiveContains(q) ?? false }
            || e.changes.contains {
                $0.field.localizedCaseInsensitiveContains(q)
                || $0.old.localizedCaseInsensitiveContains(q)
                || $0.new.localizedCaseInsensitiveContains(q)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter history", text: $filter)
                    .textFieldStyle(.plain)
                if isLoading { ProgressView().controlSize(.small) }
                Text("\(filtered.count) events")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Button(action: { Task { await load() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload history")
                .disabled(isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if let loadError, entries.isEmpty {
                ContentUnavailableView("History unavailable", systemImage: "clock.badge.exclamationmark",
                                       description: Text(loadError))
            } else if entries.isEmpty && !isLoading {
                ContentUnavailableView("No history", systemImage: "clock",
                                       description: Text("Nothing has been logged for this asset."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            AssetHistoryRow(entry: entry)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .task(id: assetId) { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await snipeService.getAssetHistory(assetId: assetId)
            entries = rows
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct AssetHistoryRow: View {
    let entry: SnipeHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(actionLabel)
                        .appFont(.callout, weight: .semibold)
                    if let who = entry.createdBy?.name, !who.isEmpty {
                        Text("by \(who)")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let target = entry.target?.name, !target.isEmpty {
                        Image(systemName: "arrow.right")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                        Text(target)
                            .appFont(.callout)
                    }
                    Spacer(minLength: 8)
                    Text(entry.when?.formatted ?? entry.when?.value ?? "")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                ForEach(entry.changes, id: \.self) { change in
                    changeLine(change)
                }

                if let note = entry.note, !note.isEmpty {
                    Text(SnipeHistoryText.plain(note))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let file = entry.file, let name = file.filename {
                    if let raw = file.url, let url = URL(string: raw) {
                        Link(destination: url) {
                            Label(name, systemImage: "paperclip").appFont(.callout)
                        }
                    } else {
                        Label(name, systemImage: "paperclip").appFont(.callout)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func changeLine(_ change: SnipeFieldChange) -> some View {
        // Field: old (struck) → new, wrapping as one run of text.
        var line = Text("\(change.field): ").foregroundColor(.secondary)
        if !change.old.isEmpty {
            line = line + Text(change.old).strikethrough().foregroundColor(.secondary) + Text(" ")
        }
        line = line + Text(Image(systemName: "arrow.right")).foregroundColor(.secondary)
        line = line + Text(" ") + Text(change.new.isEmpty ? "—" : change.new)
        return line
            .appFont(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionLabel: String {
        let raw = entry.actionType ?? "activity"
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private var symbol: String {
        switch (entry.actionType ?? "").lowercased() {
        case "update": return "pencil"
        case "create", "create new": return "plus.circle"
        case "checkout": return "arrow.up.forward.circle"
        case "checkin from": return "arrow.down.backward.circle"
        case "audit": return "checkmark.seal"
        case "uploaded": return "paperclip"
        case "delete": return "trash"
        case "restore": return "arrow.uturn.backward.circle"
        case "requested", "request canceled": return "hand.raised"
        case "accepted", "declined": return "signature"
        default: return "clock"
        }
    }
}

/// Snipe sends notes as escaped inline Markdown rendered to HTML; strip the
/// tags so a row shows the words.
enum SnipeHistoryText {
    static func plain(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
