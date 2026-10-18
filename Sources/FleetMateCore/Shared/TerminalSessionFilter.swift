import Foundation

/// What the terminal's session list knows about one session for filtering,
/// searching and sorting.
public struct TerminalSessionTraits: Equatable, Sendable {
    /// An agent CLI, not a bare shell, is in the foreground.
    public var isAgent: Bool
    /// Output is streaming.
    public var isRunning: Bool
    /// An agent is waiting on the person.
    public var isPaused: Bool
    /// Name, folder, section and program, matched by the search field.
    public var searchable: [String]
    /// When the session last printed or rang its bell.
    public var lastActivity: Date?

    public init(isAgent: Bool, isRunning: Bool, isPaused: Bool,
                searchable: [String], lastActivity: Date?) {
        self.isAgent = isAgent
        self.isRunning = isRunning
        self.isPaused = isPaused
        self.searchable = searchable
        self.lastActivity = lastActivity
    }
}

/// How the session list is ordered.
public enum TerminalSessionSort: String, CaseIterable, Sendable {
    /// In sections, in the order the person arranged.
    case manual
    case recentFirst
    case recentLast

    public var title: String {
        switch self {
        case .manual: "By Section"
        case .recentFirst: "Recently Active on Top"
        case .recentLast: "Recently Active at Bottom"
        }
    }
}

/// The session list's status toggles and search. Toggles that are on and
/// the search combine as an intersection, so a search can be narrowed to
/// its running or paused matches.
public struct TerminalSessionFilter: Equatable, Sendable {
    public var active: Bool
    public var running: Bool
    public var paused: Bool
    public var query: String

    public init(active: Bool = false, running: Bool = false, paused: Bool = false, query: String = "") {
        self.active = active
        self.running = running
        self.paused = paused
        self.query = query
    }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Any toggle is on or the search has text.
    public var isFiltering: Bool { active || running || paused || !trimmedQuery.isEmpty }

    public func matches(_ traits: TerminalSessionTraits) -> Bool {
        if active && !traits.isAgent { return false }
        if running && !traits.isRunning { return false }
        if paused && !traits.isPaused { return false }
        let query = trimmedQuery
        guard !query.isEmpty else { return true }
        // Every word must appear somewhere, so "fleet main" finds a session
        // named fleet in a folder called main.
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in
            traits.searchable.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The indices of `items`, in `sort` order, of those that match. Ties and
    /// sessions with no activity keep their list order; sessions that have
    /// never been active sit at the far end from the recent ones.
    public static func order(_ items: [TerminalSessionTraits], by sort: TerminalSessionSort) -> [Int] {
        let indices = Array(items.indices)
        guard sort != .manual else { return indices }
        let recentFirst = indices.sorted { lhs, rhs in
            switch (items[lhs].lastActivity, items[rhs].lastActivity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs < rhs
            }
        }
        return sort == .recentFirst ? recentFirst : recentFirst.reversed()
    }
}
