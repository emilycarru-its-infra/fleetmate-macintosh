import SwiftUI
import FleetMateCore

/// Choose a ticket's new responsible person or group, anchored to the
/// Reassign button.
///
/// The candidates come from TDX's eligible-assignment search for the
/// ticketing application — the same people and groups its web Responsible
/// picker offers — not the whole people directory, so everyone listed can
/// actually own the ticket. Type to search; ↑/↓ move the highlight, Return
/// picks it, Escape or a click outside closes the popover.
struct TicketReassignPopover: View {
    let service: TdxService
    let currentResponsibleUid: String?
    let currentGroupId: Int?
    @Binding var notifyNewResponsible: Bool
    let onSelect: (TdxEligibleAssignment) -> Void

    @State private var query = ""
    @State private var results: [TdxEligibleAssignment] = []
    @State private var highlighted: Int = 0
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private static let minimumQueryLength = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reassign Ticket")
                .appFont(.headline)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search people and groups", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(pickHighlighted)
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .accessibilityLabel("Search people and groups who can own this ticket")
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            resultsList

            Divider()

            Toggle("Notify new responsible", isOn: $notifyNewResponsible)
                .toggleStyle(.checkbox)
                .help("Email the new responsible person when the change is saved")

            Text("Lists the people and groups that can be responsible for tickets in this application. TeamDynamix returns up to five matches per search.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { searchFocused = true }
        .task(id: query) { await search() }
    }

    @ViewBuilder
    private var resultsList: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .appFont(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else if trimmed.count < Self.minimumQueryLength {
            Text("Type at least \(Self.minimumQueryLength) letters of a name, email or group.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        } else if results.isEmpty && !isSearching {
            Text("No one who can own tickets matches “\(trimmed)”.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, candidate in
                    row(candidate, isHighlighted: index == highlighted)
                        .onHover { if $0 { highlighted = index } }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Candidates")
        }
    }

    private func row(_ candidate: TdxEligibleAssignment, isHighlighted: Bool) -> some View {
        let isCurrent = candidate.isUser
            ? candidate.value.caseInsensitiveCompare(currentResponsibleUid ?? "") == .orderedSame
            : candidate.groupId == currentGroupId && (currentResponsibleUid ?? "").isEmpty
        return Button { onSelect(candidate) } label: {
            HStack(spacing: 8) {
                Image(systemName: candidate.isUser ? "person.crop.circle" : "person.3")
                    .frame(width: 20)
                    .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name)
                        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                    Text(candidate.isUser ? (candidate.email ?? "") : "Group")
                        .appFont(.caption)
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.isUser ? candidate.name : "\(candidate.name), group")
        .accessibilityValue(isCurrent ? "Current responsible" : "")
        .accessibilityHint("Makes this the ticket's responsible")
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
        return .handled
    }

    private func pickHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        onSelect(results[highlighted])
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        guard trimmed.count >= Self.minimumQueryLength else {
            results = []
            isSearching = false
            return
        }
        // Debounce: a new keystroke cancels this task before the request goes.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await service.searchEligibleResponsibles(searchText: trimmed)
            guard !Task.isCancelled else { return }
            // People first, then groups, each as TDX ranked them.
            results = found.filter(\.isUser) + found.filter { !$0.isUser }
            highlighted = 0
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = "Couldn't search TeamDynamix: \(error.localizedDescription)"
        }
    }
}
