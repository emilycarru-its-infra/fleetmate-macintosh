import SwiftUI
import AppKit
import FleetMateCore

enum ResultFilter: String, CaseIterable {
    case all = "All"
    case success = "Success"
    case failed = "Failed"
    case offline = "Offline"

    func matches(_ status: CommandRunStatus) -> Bool {
        switch self {
        case .all: true
        case .success: status == .success
        case .failed:
            switch status {
            case .failed, .authFailed, .timeout: true
            default: false
            }
        case .offline: status == .offline
        }
    }
}

/// Per-host output of the run in progress or the last one, streaming as
/// it arrives, filterable, and copyable for a hand-off note.
struct ResultsView: View {
    @ObservedObject var manage: ManageState
    @State private var filter: ResultFilter = .all

    private var filteredResults: [CommandRunResult] {
        manage.sortedResults.filter { filter.matches($0.status) }
    }

    private func count(_ filter: ResultFilter) -> Int {
        manage.sortedResults.filter { filter.matches($0.status) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manage.results.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .appFont(fixed: 32)
                        .foregroundStyle(Color(NSColor.quaternaryLabelColor))
                    Text("No results yet").foregroundStyle(.secondary)
                }
                Spacer()
            } else if filteredResults.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No \(filter.rawValue.lowercased()) results").foregroundStyle(.secondary)
                    Button("Show all") { filter = .all }.buttonStyle(.link).appFont(.caption)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredResults) { result in
                            ResultRowView(manage: manage, result: result)
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
        }
        .onChange(of: manage.isRunning) { _, running in
            if running { filter = .all }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(manage.isRunning ? manage.runLabel : "Results")
                .appFont(.footnote, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !manage.results.isEmpty {
                let success = count(.success), failed = count(.failed), offline = count(.offline)
                if success > 0 { StatusCapsule(text: "\(success)", systemImage: "checkmark.circle.fill", tint: .manageSuccess) }
                if failed > 0 { StatusCapsule(text: "\(failed)", systemImage: "xmark.circle.fill", tint: .manageFailure) }
                if offline > 0 { StatusCapsule(text: "\(offline)", systemImage: "wifi.slash", tint: .secondary) }
                if manage.isRunning {
                    let running = manage.sortedResults.filter { $0.status == .running }.count
                    let queued = manage.sortedResults.filter { $0.status == .pending }.count
                    if running > 0 { StatusCapsule(text: "\(running) running", systemImage: "arrow.clockwise", tint: .manageInfo) }
                    if queued > 0 {
                        StatusCapsule(text: "\(queued) queued", systemImage: "clock", tint: .secondary)
                            .help(CommandRunStatus.pending.explanation)
                    }
                }
            }

            Spacer()

            if !manage.results.isEmpty {
                HStack(spacing: 2) {
                    ForEach(ResultFilter.allCases, id: \.self) { f in
                        Button(f.rawValue) { filter = f }
                            .buttonStyle(.link)
                            .appFont(.caption)
                            .foregroundStyle(filter == f ? Color.accentColor : Color.secondary)
                    }
                }

                Divider().frame(height: 12)

                Button("Select failed") {
                    manage.selectedComputerIDs = Set(manage.sortedResults.filter { ResultFilter.failed.matches($0.status) || $0.status == .offline }.map(\.computer.id))
                }
                .buttonStyle(.link)
                .appFont(.caption)
                .disabled(count(.failed) + count(.offline) == 0)
                .help("Check only the machines that failed or were offline, to run again")

                Divider().frame(height: 12)

                Button("Copy visible") {
                    ManageClipboard.copy(filteredResults.map { $0.formatted() }.joined(separator: "\n\n"))
                }
                .buttonStyle(.link)
                .appFont(.caption)
                .disabled(filteredResults.isEmpty)

                Divider().frame(height: 12)

                Button("Clear") {
                    manage.clearResults()
                    filter = .all
                }
                .buttonStyle(.link)
                .appFont(.caption)
                .disabled(manage.isRunning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct ResultRowView: View {
    @ObservedObject var manage: ManageState
    let result: CommandRunResult
    @State private var isExpanded = true

    private var hasOutput: Bool { !result.output.isEmpty || !result.errorOutput.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if result.status == .running {
                    ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
                } else {
                    Image(systemName: result.status.icon)
                        .foregroundStyle(result.status.tint)
                        .appFont(fixed: 13)
                        .frame(width: 16)
                }

                Text(result.computer.displayName).appFont(.subheadline, weight: .semibold)
                Text(result.ip).appFont(.footnote).foregroundStyle(.secondary)
                StatusCapsule(text: result.status.label, systemImage: result.status.icon, tint: result.status.tint)
                    .help(result.status.explanation)

                Spacer()

                if let duration = result.duration {
                    Text(String(format: "%.1fs", duration)).appFont(.footnote).foregroundStyle(.secondary)
                }

                Button { manage.openScreenSharing(for: result.computer) } label: {
                    Image(systemName: "rectangle.on.rectangle").appFont(fixed: 11).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Screen Sharing")

                Button { manage.openSSH(for: result.computer) } label: {
                    Image(systemName: "terminal").appFont(fixed: 11).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open SSH")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").appFont(fixed: 10).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(result.status.tint.opacity(0.025))
            .contextMenu {
                Button("Open Screen Sharing") { manage.openScreenSharing(for: result.computer) }
                Button("Open SSH") { manage.openSSH(for: result.computer) }
                Button("Open Both") { manage.openSSHAndScreenSharing(for: result.computer) }
                Divider()
                Button("Copy Hostname") { ManageClipboard.copy(result.computer.displayName) }
                Button("Copy IP Address") { ManageClipboard.copy(result.ip) }
                if !result.output.isEmpty { Button("Copy Output") { ManageClipboard.copy(result.output) } }
                if !result.errorOutput.isEmpty { Button("Copy Error") { ManageClipboard.copy(result.errorOutput) } }
                Button("Copy Full Result") { ManageClipboard.copy(result.formatted()) }
            }

            if isExpanded && hasOutput {
                VStack(alignment: .leading, spacing: 8) {
                    if !result.output.isEmpty {
                        Text(result.output.trimmingCharacters(in: .newlines))
                            .appFont(.footnote, design: .monospaced)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !result.errorOutput.isEmpty {
                        Text(result.errorOutput)
                            .appFont(.footnote, design: .monospaced)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .foregroundStyle(Color.manageFailure)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.leading, 36)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
            }
        }
    }
}
