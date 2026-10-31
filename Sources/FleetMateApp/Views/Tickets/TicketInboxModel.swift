import Foundation
import FleetMateCore

/// Builds and keeps the signed-in person's ticket inbox.
///
/// A pass asks TDX for tickets modified since the last pass, reads the feed of
/// each one that changed, and keeps the comments that notified this person.
/// The first pass covers `TicketInbox.windowDays` and is slow — TDX allows
/// about 60 calls a minute — so it runs newest first, saves after every
/// ticket, and resumes where it stopped.
@MainActor
final class TicketInboxModel: ObservableObject {
    @Published private(set) var inbox: TicketInbox?
    @Published private(set) var isScanning = false
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var errorMessage: String?

    /// Spacing between feed calls, under TDX's rate limit with room left for
    /// the rest of the app.
    private let pace: Duration = .milliseconds(1200)
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var unreadCount: Int { inbox?.unreadCount ?? 0 }

    /// Load the stored inbox for this person and start refreshing it every
    /// five minutes. Safe to call repeatedly.
    func start(service: TdxService, me: TdxPerson) {
        guard let uid = me.uid else { return }
        if inbox?.personUid != uid {
            scanTask?.cancel()
            inbox = TicketInbox.load(personUid: uid)
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.scan(service: service, me: me)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func scan(service: TdxService, me: TdxPerson) {
        guard !isScanning, let uid = me.uid else { return }
        if inbox?.personUid != uid { inbox = TicketInbox.load(personUid: uid) }
        scanTask = Task { await runPass(service: service, me: me) }
    }

    func markRead(_ item: TicketInboxItem) {
        guard inbox?.readIds.contains(item.id) == false else { return }
        inbox?.readIds.insert(item.id)
        persist()
    }

    func markUnread(_ item: TicketInboxItem) {
        inbox?.readIds.remove(item.id)
        persist()
    }

    func markAllRead() {
        guard let ids = inbox?.items.map(\.id) else { return }
        inbox?.readIds.formUnion(ids)
        persist()
    }

    private func runPass(service: TdxService, me: TdxPerson) async {
        guard var working = inbox else { return }
        isScanning = true
        errorMessage = nil
        defer {
            isScanning = false
            progress = nil
        }

        let passStart = Date()
        let cutoff = passStart.addingTimeInterval(-Double(TicketInbox.windowDays) * 86_400)
        let since = working.scannedThrough.map { $0.addingTimeInterval(-600) } ?? cutoff

        let formatter = ISO8601DateFormatter()
        var request = TicketSearchRequest()
        request.modifiedDateFrom = formatter.string(from: max(since, cutoff))

        let changed: [TdxTicket]
        do {
            changed = try await service.searchTickets(search: request, maxResults: 10_000)
                .filter { ticket in
                    guard let id = ticket.id else { return false }
                    return working.ticketModified[id] != ticket.modifiedDate
                }
                .sorted { ($0.modifiedDate ?? "") > ($1.modifiedDate ?? "") }
        } catch {
            errorMessage = "Couldn't search tickets: \(error.localizedDescription)"
            return
        }

        progress = (0, changed.count)
        var failures = 0
        for (index, ticket) in changed.enumerated() {
            if Task.isCancelled { return }
            guard let id = ticket.id else { continue }
            do {
                let feed = try await service.getTicketFeed(ticketId: id, includeReplies: false)
                working.merge(feed: feed, ticket: ticket, name: me.fullName, email: me.primaryEmail, cutoff: cutoff)
            } catch {
                // Left out of `ticketModified`, so the next pass retries it.
                failures += 1
                try? await Task.sleep(for: .seconds(30))
            }
            progress = (index + 1, changed.count)
            // Keep read marks made while the pass runs.
            if let current = inbox { working.readIds = current.readIds }
            inbox = working
            persist()
            try? await Task.sleep(for: pace)
        }

        if let current = inbox { working.readIds = current.readIds }
        working.prune(before: cutoff)
        if failures == 0 { working.scannedThrough = passStart }
        inbox = working
        persist()
        if failures > 0 {
            errorMessage = "\(failures) ticket\(failures == 1 ? "" : "s") couldn't be read; they'll be retried."
        }
    }

    private func persist() {
        try? inbox?.save()
    }
}
