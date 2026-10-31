import Foundation
import FleetMateCore

/// Builds and keeps the signed-in person's ticket inbox.
///
/// A pass asks TDX for tickets modified since the last pass, reads the feed of
/// each one that changed, and keeps the comments that notified this person.
/// The first pass covers `TicketInbox.windowDays` and is slow — TDX allows
/// about 60 calls a minute — so it runs newest first, saves after every
/// ticket, and resumes where it stopped.
///
/// The same model runs in the app window and in the background helper. A
/// file lock lets only one of them scan; the other just reloads what the
/// scanner saved.
@MainActor
final class TicketInboxModel: ObservableObject {
    @Published private(set) var inbox: TicketInbox?
    @Published private(set) var readIds: Set<Int> = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var errorMessage: String?

    /// Spacing between feed calls, under TDX's rate limit with room left for
    /// the rest of the app.
    private let pace: Duration = .milliseconds(1200)
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var unreadCount: Int { inbox?.unreadCount(readIds: readIds) ?? 0 }

    /// True once a full pass has finished on this computer. Until then the
    /// inbox is incomplete, so it stays out of sight.
    var isReady: Bool { inbox?.scannedThrough != nil }

    func isRead(_ item: TicketInboxItem) -> Bool { readIds.contains(item.id) }

    /// Load the stored inbox for this person and keep it fresh: a pass every
    /// five minutes, and a reload of the helper's results every minute.
    /// Safe to call repeatedly.
    func start(service: TdxService, me: TdxPerson) {
        guard let uid = me.uid else { return }
        if inbox?.personUid != uid {
            scanTask?.cancel()
            refreshTask?.cancel()
            refreshTask = nil
            load(uid: uid)
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if tick % 5 == 0 {
                    self?.scan(service: service, me: me)
                } else if self?.isScanning == false {
                    self?.reload()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func scan(service: TdxService, me: TdxPerson) {
        guard !isScanning, let uid = me.uid else { return }
        if inbox?.personUid != uid { load(uid: uid) }
        scanTask = Task { await runPass(service: service, me: me) }
    }

    func markRead(_ item: TicketInboxItem) {
        guard !readIds.contains(item.id) else { return }
        readIds.insert(item.id)
        saveReadState()
    }

    func markUnread(_ item: TicketInboxItem) {
        readIds.remove(item.id)
        saveReadState()
    }

    func markAllRead() {
        guard let ids = inbox?.items.map(\.id) else { return }
        readIds.formUnion(ids)
        saveReadState()
    }

    private func load(uid: String) {
        inbox = TicketInbox.load(personUid: uid)
        let live = Set(inbox?.items.map(\.id) ?? [])
        readIds = TicketInboxReadState.load(personUid: uid).readIds.intersection(live)
    }

    /// Pick up what the other process saved. Read marks stay as they are:
    /// only this window writes them.
    private func reload() {
        guard let uid = inbox?.personUid else { return }
        inbox = TicketInbox.load(personUid: uid)
    }

    private func runPass(service: TdxService, me: TdxPerson) async {
        guard let uid = me.uid else { return }
        guard let lock = TicketInboxScanLock(personUid: uid) else {
            // The other process is scanning; show what it has so far.
            reload()
            return
        }
        defer { withExtendedLifetime(lock) {} }

        var working = TicketInbox.load(personUid: uid)
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
            inbox = working
            try? working.save()
            try? await Task.sleep(for: pace)
        }

        working.prune(before: cutoff)
        if failures == 0 { working.scannedThrough = passStart }
        inbox = working
        try? working.save()
        if failures > 0 {
            errorMessage = "\(failures) ticket\(failures == 1 ? "" : "s") couldn't be read; they'll be retried."
        }
    }

    private func saveReadState() {
        guard let uid = inbox?.personUid else { return }
        try? TicketInboxReadState(readIds: readIds).save(personUid: uid)
    }
}
