import SwiftUI
import FleetMateCore

/// Every comment that notified the signed-in person, across all tickets,
/// newest first, as the Tickets sidebar. Its host opens the selected ticket.
struct TicketInboxView: View {
    @ObservedObject var inbox: TicketInboxModel
    var requiresSignIn = false
    /// The ticket open in the workspace. When it moves elsewhere the row
    /// deselects, so clicking that row opens its ticket again.
    var openTicketId: Int?
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
                emptyState(
                    requiresSignIn ? "Sign in to see your Inbox" : "Inbox unavailable",
                    message: requiresSignIn
                        ? "Your ticket session has expired. Reconnect to load comments that notify you."
                        : "Your TeamDynamix person record hasn't been found yet."
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
                    emptyState(
                        showUnreadOnly ? "You're all caught up" : "No comments yet",
                        message: "Comments that notify you in the last \(TicketInbox.windowDays) days appear here."
                    )
                }
            } else {
                List(items, selection: $selectedItemId) { item in
                    row(item)
                        .tag(item.id)
                        .contextMenu {
                            if inbox.isRead(item) {
                                Button("Mark as Unread") {
                                    if selectedItemId == item.id { selectedItemId = nil }
                                    inbox.markUnread(item)
                                }
                            } else {
                                Button("Mark as Read") { inbox.markRead(item) }
                            }
                        }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedItemId) { _, id in
                    guard let id, let item = items.first(where: { $0.id == id }) else { return }
                    inbox.markTicketOpened(from: item)
                    onSelect(item)
                }
                .onChange(of: openTicketId) { _, ticketId in
                    guard let id = selectedItemId,
                          let item = inbox.inbox?.items.first(where: { $0.id == id }),
                          item.ticketId != ticketId else { return }
                    selectedItemId = nil
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func emptyState(_ title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title).appFont(.headline)
            Text(message)
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Inbox").appFont(.headline)
                Spacer()
                Toggle(isOn: $showUnreadOnly) {
                    Label("Unread Only", systemImage: showUnreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Show only unread comments")
                Button { inbox.markAllRead() } label: {
                    Label("Mark All as Read", systemImage: "envelope.open")
                }
                .labelStyle(.iconOnly)
                .disabled(inbox.unreadCount == 0)
                .help("Mark all as read")
                Button(action: onRefresh) {
                    Label("Refresh Inbox", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(inbox.isScanning)
                .help("Check for new comments")
            }
            .buttonStyle(.borderless)
            status
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var status: some View {
        if let progress = inbox.progress, progress.total > 0 {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                Text("Scanning \(progress.done) of \(progress.total) tickets")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        } else if inbox.isScanning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for new comments")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
        } else if let error = inbox.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .appFont(.caption)
                .foregroundColor(.orange)
        } else {
            Text("\(inbox.unreadCount) unread")
                .appFont(.caption)
                .foregroundColor(.secondary)
        }
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
