import SwiftUI
import FleetMateCore

/// Every comment that notified the signed-in person, across all tickets,
/// newest first, as the Tickets sidebar. Laid out like Mail's message list:
/// controls in the column's toolbar, status in a footer, three-line rows.
struct TicketInboxView: View {
    @ObservedObject var inbox: TicketInboxModel
    var requiresSignIn = false
    /// The ticket open in the workspace. When it moves elsewhere the row
    /// deselects, so clicking that row opens its ticket again.
    var openTicketId: Int?
    let onRefresh: () -> Void
    let onSelect: (TicketInboxItem) -> Void

    @AppStorage("tickets.inboxUnreadOnly") private var showUnreadOnly = false
    @State private var selectedItemId: Int?

    private var items: [TicketInboxItem] {
        let all = inbox.inbox?.sortedItems ?? []
        guard showUnreadOnly else { return all }
        return all.filter { !inbox.isRead($0) || $0.id == selectedItemId }
    }

    var body: some View {
        content
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: $showUnreadOnly) {
                        Label("Unread Only", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help(showUnreadOnly ? "Show all comments" : "Show only unread comments")
                    Button { inbox.markAllRead() } label: {
                        Label("Mark All as Read", systemImage: "envelope.open")
                    }
                    .disabled(inbox.unreadCount == 0)
                    .help("Mark all as read")
                    Button(action: onRefresh) {
                        Label("Check for New Comments", systemImage: "arrow.clockwise")
                    }
                    .disabled(inbox.isScanning)
                    .help("Check for new comments")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if inbox.inbox == nil {
            ContentUnavailableView {
                Label(requiresSignIn ? "Sign In to See Your Inbox" : "Inbox Unavailable", systemImage: "tray")
            } description: {
                Text(requiresSignIn
                     ? "Your ticket session has expired. Reconnect to load comments that notify you."
                     : "Your TeamDynamix person record hasn't been found yet.")
            }
        } else if items.isEmpty {
            if inbox.isScanning {
                ProgressView("Reading ticket activity…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(showUnreadOnly ? "No Unread Comments" : "No Comments", systemImage: "tray")
                } description: {
                    Text("Comments that notify you in the last \(TicketInbox.windowDays) days appear here.")
                }
            }
        } else {
            List(items, selection: $selectedItemId) { item in
                TicketInboxRow(item: item, isRead: inbox.isRead(item))
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
                        Divider()
                        Button("Copy Ticket Number") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(item.ticketId), forType: .string)
                        }
                    }
            }
            .listStyle(.inset)
            .onChange(of: selectedItemId) { _, id in
                guard let id, let item = items.first(where: { $0.id == id }) else { return }
                inbox.markTicketOpened(item.ticketId)
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

    /// Mail's footer: one quiet line of status under the list.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                if let progress = inbox.progress, progress.total > 0 {
                    ProgressView().controlSize(.mini)
                    Text("Checking \(progress.done) of \(progress.total) tickets").monospacedDigit()
                } else if inbox.isScanning {
                    ProgressView().controlSize(.mini)
                    Text("Checking for new comments")
                } else if let error = inbox.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(1).truncationMode(.tail).help(error)
                } else if showUnreadOnly {
                    Text("Filtered by Unread · \(inbox.unreadCount) unread")
                } else {
                    Text(inbox.unreadCount == 0 ? "No unread comments" : "\(inbox.unreadCount) unread")
                }
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .background(.bar)
    }
}

/// One comment: who, when, which ticket, and the start of what they wrote.
private struct TicketInboxRow: View {
    let item: TicketInboxItem
    let isRead: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(isRead ? Color.clear : Color.accentColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.author)
                        .fontWeight(isRead ? .regular : .semibold)
                        .lineLimit(1)
                    if item.isPrivate {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .help("Private comment")
                            .accessibilityLabel("Private")
                    }
                    Spacer(minLength: 6)
                    if let date = item.date {
                        Text(Self.shortDate(date))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.ticketTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: "#\(item.ticketId)")
                        .appFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(Self.preview(item.body))
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .appFont(.body)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isRead ? "" : "Unread")
    }

    /// Mail's dates: a time today, "Yesterday", a weekday this week, then a date.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The comment as one run of text: greetings and blank lines don't spend the two lines.
    static func preview(_ html: String) -> String {
        TicketsView.decodeHtml(html)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
