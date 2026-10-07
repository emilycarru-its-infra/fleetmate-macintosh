import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FleetMateCore

/// Keeps the window in step with the log, coalescing bursts of requests into
/// one redraw.
@MainActor
final class ActivityLogModel: ObservableObject {
    @Published private(set) var actions: [ActivityAction] = []
    private var observer: NSObjectProtocol?
    private var pending = false

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: ActivityLog.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func scheduleReload() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.reload()
            }
        }
    }

    func reload() {
        actions = ActivityLog.shared.snapshot.reversed()
    }
}

/// Window ▸ Activity Log: what FleetMate asked each service to do, and each
/// HTTP request made for it. Copy and export mask serials, UDIDs and hardware
/// addresses so the result can go into a bug report.
struct ActivityLogView: View {
    static let windowId = "activity-log"

    @StateObject private var model = ActivityLogModel()
    @State private var query = ""
    @State private var selection: ActivityAction.ID?

    private var filtered: [ActivityAction] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.actions }
        return model.actions.filter { action in
            action.title.localizedCaseInsensitiveContains(needle)
                || action.service.localizedCaseInsensitiveContains(needle)
                || action.serials.contains { $0.localizedCaseInsensitiveContains(needle) }
                || action.requests.contains { $0.path.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var selected: ActivityAction? {
        guard let selection else { return nil }
        return model.actions.first { $0.id == selection }
    }

    var body: some View {
        VSplitView {
            Table(filtered, selection: $selection) {
                TableColumn("Time") { Text($0.startedAt, format: .dateTime.hour().minute().second()).monospacedDigit() }
                    .width(min: 70, ideal: 80, max: 100)
                TableColumn("Service", value: \.service)
                    .width(min: 90, ideal: 120, max: 180)
                TableColumn("Action") { action in
                    Text(action.title).foregroundStyle(action.isBackground ? .secondary : .primary)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Serials") { Text($0.serials.joined(separator: ", ")).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 140)
                TableColumn("Requests") { Text("\($0.requests.count)").monospacedDigit() }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("Result") { action in
                    Text(action.result).foregroundStyle(action.result == "OK" ? Color.secondary : Color.orange)
                }
                .width(min: 80, ideal: 120)
            }
            .frame(minHeight: 200)

            requestTable
                .frame(minHeight: 140)
        }
        .safeAreaInset(edge: .bottom) {
            Text("Kept in memory only and cleared when FleetMate quits. Headers, query strings and request bodies are never recorded.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search by serial, action or path")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy Masked", systemImage: "doc.on.doc", action: copyMasked)
                    .help("Copy the shown entries with serials, UDIDs and hardware addresses replaced")
                Button("Export Masked…", systemImage: "square.and.arrow.up", action: exportMasked)
                    .help("Save the shown entries with serials, UDIDs and hardware addresses replaced")
                Button("Clear", systemImage: "trash") {
                    ActivityLog.shared.clear()
                    selection = nil
                }
                .help("Empty the activity log")
            }
        }
        .navigationTitle("Activity Log")
    }

    @ViewBuilder
    private var requestTable: some View {
        if let action = selected {
            Table(action.requests) {
                TableColumn("Method", value: \.method).width(min: 50, ideal: 60, max: 80)
                TableColumn("Host", value: \.host).width(min: 120, ideal: 200)
                TableColumn("Path") { Text($0.path).textSelection(.enabled) }.width(min: 200, ideal: 420)
                TableColumn("Status") { request in
                    Text(request.statusText).foregroundStyle(request.succeeded ? Color.secondary : Color.orange)
                }
                .width(min: 60, ideal: 100)
                TableColumn("Duration") { Text("\(Int((($0.duration) * 1000).rounded())) ms").monospacedDigit() }
                    .width(min: 60, ideal: 80, max: 100)
            }
        } else {
            Text(model.actions.isEmpty ? "No activity yet." : "Select an action to see its requests.")
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copyMasked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ActivityMasker.export(filtered.reversed()), forType: .string)
    }

    private func exportMasked() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "FleetMate Activity Log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ActivityMasker.export(filtered.reversed()).write(to: url, atomically: true, encoding: .utf8)
    }
}
