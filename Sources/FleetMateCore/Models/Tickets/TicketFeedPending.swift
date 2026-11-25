import Foundation

/// Comments and replies posted from here that the ticket feed may not list yet.
///
/// TDX answers a post with the entry it created, but a feed read straight
/// afterwards can still come back without it, so the ticket looked as if the
/// reply never went out. Each posted entry is kept here and merged into every
/// feed read until TDX lists it, or until `lifetime` passes.
public struct TicketFeedPending: Equatable {
    struct Comment: Equatable {
        let ticketId: Int
        let entry: TdxFeedEntry
        let postedAt: Date
    }

    struct Reply: Equatable {
        let ticketId: Int
        let parentId: Int
        let reply: TdxFeedEntry
        let postedAt: Date
    }

    public static let lifetime: TimeInterval = 120

    private var comments: [Comment] = []
    private var replies: [Reply] = []

    public init() {}

    public var isEmpty: Bool { comments.isEmpty && replies.isEmpty }

    public mutating func addComment(_ entry: TdxFeedEntry, ticketId: Int, now: Date = Date()) {
        guard let id = entry.id, !comments.contains(where: { $0.entry.id == id }) else { return }
        comments.append(Comment(ticketId: ticketId, entry: entry, postedAt: now))
    }

    public mutating func addReply(_ reply: TdxFeedEntry, parentId: Int, ticketId: Int, now: Date = Date()) {
        guard let id = reply.id, !replies.contains(where: { $0.reply.id == id }) else { return }
        replies.append(Reply(ticketId: ticketId, parentId: parentId, reply: reply, postedAt: now))
    }

    /// Forget a reply that was deleted before TDX listed it.
    public mutating func removeReply(id: Int) {
        replies.removeAll { $0.reply.id == id }
    }

    /// `fetched` with this ticket's posted entries added where TDX left them
    /// out. Entries TDX now lists, and entries past `lifetime`, are dropped.
    public mutating func merge(_ fetched: [TdxFeedEntry], ticketId: Int, now: Date = Date()) -> [TdxFeedEntry] {
        let fetchedIds = Set(fetched.compactMap(\.id))
        let fetchedReplyIds = Set(fetched.flatMap { $0.replyList.compactMap(\.id) })
        comments.removeAll {
            now.timeIntervalSince($0.postedAt) > Self.lifetime
                || ($0.ticketId == ticketId && $0.entry.id.map(fetchedIds.contains) == true)
        }
        replies.removeAll {
            now.timeIntervalSince($0.postedAt) > Self.lifetime
                || ($0.ticketId == ticketId && $0.reply.id.map(fetchedReplyIds.contains) == true)
        }

        return apply(to: fetched, ticketId: ticketId)
    }

    /// `feed` with this ticket's posted entries added where missing. Unlike
    /// `merge`, it never treats `feed` as TDX's word, so it is safe on the feed
    /// already on screen.
    public func apply(to feed: [TdxFeedEntry], ticketId: Int) -> [TdxFeedEntry] {
        var feed = feed
        for pending in replies where pending.ticketId == ticketId {
            guard let index = feed.firstIndex(where: { $0.id == pending.parentId }),
                  !feed[index].replyList.contains(where: { $0.id == pending.reply.id }) else { continue }
            let thread = feed[index].replyList + [pending.reply]
            feed[index] = feed[index].withReplies(thread)
        }
        let listed = Set(feed.compactMap(\.id))
        let missing = comments.filter { $0.ticketId == ticketId && !listed.contains($0.entry.id ?? -1) }.map(\.entry)
        guard !missing.isEmpty else { return feed }
        return Self.newestFirst(feed) ? missing.reversed() + feed : feed + missing
    }

    /// TDX lists the ticket feed newest first; follow whatever order it sent.
    private static func newestFirst(_ feed: [TdxFeedEntry]) -> Bool {
        guard let first = feed.first?.createdDate, let last = feed.last?.createdDate else { return true }
        return first >= last
    }
}
