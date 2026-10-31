import Foundation

/// A comment on any ticket that notified the signed-in person.
public struct TicketInboxItem: Codable, Identifiable, Hashable, Sendable {
    /// The feed entry's id.
    public let id: Int
    public let ticketId: Int
    public let ticketTitle: String
    public let author: String
    public let authorEmail: String?
    public let body: String
    public let createdDate: String
    public let isPrivate: Bool

    public var date: Date? { TdxTicket.parseDate(createdDate) }

    public init(id: Int, ticketId: Int, ticketTitle: String, author: String, authorEmail: String?,
                body: String, createdDate: String, isPrivate: Bool) {
        self.id = id
        self.ticketId = ticketId
        self.ticketTitle = ticketTitle
        self.author = author
        self.authorEmail = authorEmail
        self.body = body
        self.createdDate = createdDate
        self.isPrivate = isPrivate
    }
}

/// Every comment that notified one person, across all tickets.
///
/// TDX has no per-person inbox in its API, so this is built by reading the
/// feeds of tickets that changed and keeping the entries whose notified list
/// names the person. Read state is kept here too: TDX does not record which
/// comments someone has read.
public struct TicketInbox: Codable, Sendable {
    public static let windowDays = 90

    public var personUid: String
    public var items: [TicketInboxItem] = []
    public var readIds: Set<Int> = []
    /// When the last full pass started. The next pass asks only for tickets
    /// modified since then.
    public var scannedThrough: Date?
    /// Each scanned ticket's `ModifiedDate`, so an unchanged ticket is not
    /// read twice and an interrupted pass resumes where it stopped.
    public var ticketModified: [Int: String] = [:]

    public init(personUid: String) {
        self.personUid = personUid
    }

    public var sortedItems: [TicketInboxItem] {
        items.sorted { $0.createdDate > $1.createdDate }
    }

    public var unreadCount: Int {
        items.reduce(0) { $0 + (readIds.contains($1.id) ? 0 : 1) }
    }

    public func isRead(_ item: TicketInboxItem) -> Bool { readIds.contains(item.id) }

    /// True when a feed entry's notified list names this person.
    ///
    /// TDX writes the list as display names separated by commas, sometimes
    /// with the address in angle brackets.
    public static func isAddressed(notifiedList: String?, name: String?, email: String?) -> Bool {
        guard let list = notifiedList, !list.isEmpty else { return false }
        let wantedName = name?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let wantedEmail = email?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if !wantedEmail.isEmpty, list.lowercased().contains(wantedEmail) { return true }
        guard !wantedName.isEmpty else { return false }
        return list.split(whereSeparator: { $0 == "," || $0 == ";" }).contains { part in
            var text = String(part)
            if let bracket = text.firstIndex(of: "<") { text = String(text[..<bracket]) }
            return text.trimmingCharacters(in: .whitespaces).lowercased() == wantedName
        }
    }

    /// Fold one ticket's feed in: keep entries that notified the person and
    /// were not written by them, newer than `cutoff`.
    public mutating func merge(feed: [TdxFeedEntry], ticket: TdxTicket,
                               name: String?, email: String?, cutoff: Date) {
        guard let ticketId = ticket.id else { return }
        let ownEmail = email?.lowercased()
        let found: [TicketInboxItem] = feed.compactMap { entry in
            guard let id = entry.id,
                  let created = entry.createdDate,
                  let date = TdxTicket.parseDate(created), date >= cutoff,
                  Self.isAddressed(notifiedList: entry.notifiedList, name: name, email: email) else { return nil }
            if let ownEmail, entry.createdEmail?.lowercased() == ownEmail { return nil }
            return TicketInboxItem(
                id: id,
                ticketId: ticketId,
                ticketTitle: ticket.title ?? "Ticket \(ticketId)",
                author: entry.createdFullName ?? "Unknown",
                authorEmail: entry.createdEmail,
                body: entry.body ?? "",
                createdDate: created,
                isPrivate: entry.isPrivate ?? false
            )
        }
        let foundIds = Set(found.map(\.id))
        items.removeAll { foundIds.contains($0.id) }
        items.append(contentsOf: found)
        if let modified = ticket.modifiedDate { ticketModified[ticketId] = modified }
    }

    /// Drop items older than the window, and read marks for items gone.
    public mutating func prune(before cutoff: Date) {
        items.removeAll { ($0.date ?? .distantPast) < cutoff }
        let live = Set(items.map(\.id))
        readIds.formIntersection(live)
    }

    // MARK: - Storage

    public static func fileURL(personUid: String, root: URL? = nil) -> URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(AppEdition.current.isTicketsOnly ? "TicketsMate" : "FleetMate", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent("\(personUid).json")
    }

    public static func load(personUid: String, root: URL? = nil) -> TicketInbox {
        let url = fileURL(personUid: personUid, root: root)
        guard let data = try? Data(contentsOf: url),
              let inbox = try? JSONDecoder().decode(TicketInbox.self, from: data),
              inbox.personUid == personUid else {
            return TicketInbox(personUid: personUid)
        }
        return inbox
    }

    public func save(root: URL? = nil) throws {
        let url = Self.fileURL(personUid: personUid, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
