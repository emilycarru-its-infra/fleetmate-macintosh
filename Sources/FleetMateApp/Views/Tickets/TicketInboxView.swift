import SwiftUI
import FleetMateCore

/// Every comment that notified the signed-in person, across all tickets,
/// newest first. Selecting one opens its ticket beside the list.
struct TicketInboxView: View {
    @ObservedObject var inbox: TicketInboxModel
    let onRefresh: () -> Void
    let onSelect: (TicketInboxItem) -> Void

    @State private var showUnreadOnly = false
    @State private var selectedItemId: Int?

    private var items: [TicketInboxItem] {
        let all = inbox.inbox?.sortedItems ?? []
        guard showUnreadOnly else { return all }
        return all.filter { !inbox.isRead($0) || $0.id == selectedItemId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if inbox.inbox == nil {
                ContentUnavailableView(
                    "Inbox unavailable",
                    systemImage: "tray",
                    description: Text("Your TeamDynamix person record hasn't been found yet.")
                )
            } else if items.isEmpty {
                if inbox.isScanning {
                    VStack {
                        ProgressView("Reading ticket activity...")
                            .padding(.top, 50)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        showUnreadOnly ? "No unread comments" : "No comments",
                        systemImage: "tray",
                        description: Text("Comments that notify you in the last \(TicketInbox.windowDays) days appear here.")
                    )
                }
            } else {
                List(items, selection: $selectedItemId) { item in
                    row(item)
                        .tag(item.id)
                        .contextMenu {
                            if inbox.isRead(item) {
                                Button("Mark as Unread") { inbox.markUnread(item) }
                            } else {
                                Button("Mark as Read") { inbox.markRead(item) }
                            }
                        }
                }
                .listStyle(.inset)
                .onChange(of: selectedItemId) { _, id in
                    guard let id, let item = items.first(where: { $0.id == id }) else { return }
                    inbox.markRead(item)
                    onSelect(item)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let progress = inbox.progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(width: 120)
                Text("Scanning \(progress.done) of \(progress.total) tickets")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            } else if inbox.isScanning {
                ProgressView().controlSize(.small)
                Text("Checking for new comments")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            } else if let error = inbox.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("\(inbox.unreadCount) unread")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("Unread only", isOn: $showUnreadOnly)
                .toggleStyle(.checkbox)
                .appFont(.caption)
            Button("Mark All as Read") { inbox.markAllRead() }
                .controlSize(.small)
                .disabled(inbox.unreadCount == 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(inbox.isScanning)
            .help("Check for new comments")
            .accessibilityLabel("Refresh inbox")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(_ item: TicketInboxItem) -> some View {
        let isRead = inbox.isRead(item)
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityLabel(isRead ? "" : "Unread")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.author)
                        .appFont(.body)
                        .fontWeight(isRead ? .regular : .semibold)
                        .lineLimit(1)
                    if item.isPrivate {
                        Text("Private")
                            .appFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let date = item.date {
                        Text(date, format: .relative(presentation: .named))
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(verbatim: "\(item.ticketTitle) - [\(item.ticketId)]")
                    .appFont(.callout)
                    .fontWeight(isRead ? .regular : .medium)
                    .lineLimit(1)
                Text(TicketsView.decodeHtml(item.body))
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
