import AppKit
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
    @Published private var scanErrorMessage: String?
    @Published private var readStateErrorMessage: String?
    @Published private var readStateReady = false

    var errorMessage: String? { readStateErrorMessage ?? scanErrorMessage }

    /// Leave room below the per-user limit when both editions scan, plus foreground reads.
    private let pace: Duration = .milliseconds(2500)
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var scope: TicketInboxScope?
    private var readMutationTask: Task<Void, Never>?
    private var readReloadTask: Task<Void, Never>?
    private var readReloadRequested = false
    private var observers: TicketInboxReadObservers?

    private var legacyServiceKey: String? {
        UserDefaults.standard.string(forKey: TicketInboxReadStore.legacyServiceSettingKey)
    }

    private var readStore: TicketInboxReadStore? {
        scope.map { TicketInboxReadStore(scope: $0, legacyServiceKey: legacyServiceKey) }
    }

    init() {
        observers = TicketInboxReadObservers { [weak self] identifier in
            Task { @MainActor [weak self] in
                guard let self, identifier == nil || identifier == self.scope?.identifier else { return }
                self.reloadReadState()
            }
        }
    }

    deinit {
        scanTask?.cancel()
        refreshTask?.cancel()
        readReloadTask?.cancel()
    }

    var unreadCount: Int { readStateReady ? (inbox?.unreadCount(readIds: readIds) ?? 0) : 0 }

    /// True once a full pass has finished on this computer. Until then the
    /// inbox is incomplete, so it stays out of sight.
    var isReady: Bool { inbox?.scannedThrough != nil && readStateReady }

    func isRead(_ item: TicketInboxItem) -> Bool { readIds.contains(item.id) }

    /// Load the stored inbox for this person and keep it fresh: a pass every
    /// five minutes, and a reload of the helper's results every minute.
    /// Safe to call repeatedly.
    func start(service: TdxService, me: TdxPerson) {
        guard let uid = me.uid,
              let nextScope = TicketInboxScope(ticketEndpoint: service.ticketInboxEndpoint, personUid: uid) else { stop(); return }
        if scope != nextScope {
            scanTask?.cancel()
            refreshTask?.cancel()
            refreshTask = nil
            load(scope: nextScope)
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.reloadReadState()
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

    /// Forget the visible account immediately; queued explicit read decisions still finish.
    func stop() {
        scanTask?.cancel()
        refreshTask?.cancel()
        readReloadTask?.cancel()
        scanTask = nil
        refreshTask = nil
        readReloadTask = nil
        readReloadRequested = false
        scope = nil
        inbox = nil
        readIds = []
        readStateReady = false
        isScanning = false
        progress = nil
        scanErrorMessage = nil
        readStateErrorMessage = nil
    }

    func scan(service: TdxService, me: TdxPerson) {
        guard !isScanning, let uid = me.uid,
              let nextScope = TicketInboxScope(ticketEndpoint: service.ticketInboxEndpoint, personUid: uid) else { return }
        if scope != nextScope { load(scope: nextScope) }
        scanTask = Task { await runPass(service: service, me: me) }
    }

    func markRead(_ item: TicketInboxItem) { updateReadState(.read([item.id])) }

    func markUnread(_ item: TicketInboxItem) { updateReadState(.unread([item.id])) }

    func markAllRead() {
        guard let inbox else { return }
        updateReadState(.read(Set(inbox.items.map(\.id))))
    }

    private func load(scope: TicketInboxScope) {
        self.scope = scope
        inbox = TicketInbox.load(scope: scope, legacyServiceKey: legacyServiceKey)
        readIds = []
        readStateReady = false
        readStateErrorMessage = nil
        isScanning = false
        progress = nil
        scanErrorMessage = nil
        reloadReadState()
    }

    private func reload() {
        guard let scope else { return }
        inbox = TicketInbox.load(scope: scope, legacyServiceKey: legacyServiceKey)
        reloadReadState()
    }

    private func reloadReadState() {
        readReloadRequested = true
        guard readReloadTask == nil, let store = readStore else { return }
        readReloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            self?.readReloadRequested = false
            let result = await Task.detached { Result { try store.update() } }.value
            guard !Task.isCancelled, let self else { return }
            if self.scope == store.scope { self.adoptReadState(result) }
            self.readReloadTask = nil
            if self.readReloadRequested { self.reloadReadState() }
        }
    }

    private func updateReadState(_ change: TicketInboxReadStore.Change) {
        guard let store = readStore else { return }
        let previous = readMutationTask
        // Preserve click order without blocking the main actor on another process's file lock.
        readMutationTask = Task { [weak self] in
            await previous?.value
            let result = await Task.detached { Result { try store.update(change) } }.value
            guard let self, self.scope == store.scope else { return }
            self.adoptReadState(result)
        }
    }

    private func adoptReadState(_ result: Result<TicketInboxReadState, Error>) {
        switch result {
        case .success(let state):
            if readIds != state.readIds { readIds = state.readIds }
            readStateReady = true
            readStateErrorMessage = nil
        case .failure:
            readStateErrorMessage = "Inbox read status couldn't be saved or refreshed. It will be retried."
        }
    }

    private func runPass(service: TdxService, me: TdxPerson) async {
        guard let passScope = scope else { return }
        guard let lock = TicketInboxScanLock(scope: passScope) else {
            // The other process is scanning; show what it has so far.
            reload()
            return
        }
        defer { withExtendedLifetime(lock) {} }

        var working = TicketInbox.load(scope: passScope, legacyServiceKey: legacyServiceKey)
        isScanning = true
        scanErrorMessage = nil
        defer {
            if scope == passScope {
                isScanning = false
                progress = nil
            }
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
            guard !Task.isCancelled, scope == passScope else { return }
            scanErrorMessage = "Couldn't search tickets: \(error.localizedDescription)"
            return
        }

        guard !Task.isCancelled, scope == passScope else { return }
        progress = (0, changed.count)
        var failures = 0
        for (index, ticket) in changed.enumerated() {
            if Task.isCancelled || scope != passScope { return }
            guard let id = ticket.id else { continue }
            do {
                let feed = try await service.getTicketFeed(ticketId: id, includeReplies: false)
                guard !Task.isCancelled, scope == passScope else { return }
                working.merge(feed: feed, ticket: ticket, name: me.fullName, email: me.primaryEmail, cutoff: cutoff)
            } catch {
                // Left out of `ticketModified`, so the next pass retries it.
                failures += 1
                try? await Task.sleep(for: .seconds(30))
            }
            guard !Task.isCancelled, scope == passScope else { return }
            progress = (index + 1, changed.count)
            inbox = working
            try? working.save(scope: passScope)
            try? await Task.sleep(for: pace)
        }

        guard !Task.isCancelled, scope == passScope else { return }
        working.prune(before: cutoff)
        if failures == 0 { working.scannedThrough = passStart }
        inbox = working
        try? working.save(scope: passScope)
        if failures > 0 {
            scanErrorMessage = "\(failures) ticket\(failures == 1 ? "" : "s") couldn't be read; they'll be retried."
        }
    }

}

/// Observers own their tokens; callbacks carry only an opaque scope identifier.
private final class TicketInboxReadObservers: @unchecked Sendable {
    private let shared: NSObjectProtocol
    private let active: NSObjectProtocol

    init(onChange: @escaping @Sendable (String?) -> Void) {
        shared = DistributedNotificationCenter.default().addObserver(
            forName: TicketInboxReadStore.changedNotification, object: nil, queue: .main
        ) { note in onChange(note.object as? String) }
        active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in onChange(nil) }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(shared)
        NotificationCenter.default.removeObserver(active)
    }
}
