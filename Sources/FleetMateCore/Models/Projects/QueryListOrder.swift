import Foundation

/// How the Projects queries list orders its stored queries, and the project
/// groups that hold them. This orders the queries themselves, so it works
/// while every query is collapsed; the column headers order the rows inside
/// an expanded query.
public enum QueryListOrder: String, CaseIterable, Codable, Sendable {
    /// Most recently changed work first. The list's long-standing default.
    case lastChanged
    case name
    case resultCount
    /// The order Azure DevOps keeps the shared queries in.
    case queryOrder

    public static let `default`: QueryListOrder = .lastChanged

    /// User defaults keys for the remembered choice.
    public static let storageKey = "queriesList.order"
    public static let ascendingStorageKey = "queriesList.orderAscending"

    public var title: String {
        switch self {
        case .lastChanged: return "Last Changed"
        case .name: return "Name"
        case .resultCount: return "Result Count"
        case .queryOrder: return "Query Order"
        }
    }

    /// The direction a fresh pick starts in: names A to Z, the newest and the
    /// biggest queries first, and Azure DevOps order as stored.
    public var defaultAscending: Bool {
        switch self {
        case .name, .queryOrder: return true
        case .lastChanged, .resultCount: return false
        }
    }

    /// Words for the two directions, so the menu reads "Newest First" rather
    /// than a bare "Ascending" that means nothing for dates.
    public func directionTitle(ascending: Bool) -> String {
        switch self {
        case .lastChanged: return ascending ? "Oldest First" : "Newest First"
        case .name: return ascending ? "A to Z" : "Z to A"
        case .resultCount: return ascending ? "Fewest First" : "Most First"
        case .queryOrder: return ascending ? "As Stored" : "Reversed"
        }
    }
}

/// What the sort needs to know about one query, or one project group.
public struct QueryOrderKey: Equatable, Sendable {
    public var name: String
    public var resultCount: Int
    public var lastChanged: Date
    /// Position in the Azure DevOps shared-queries list.
    public var position: Int

    public init(name: String, resultCount: Int, lastChanged: Date, position: Int) {
        self.name = name
        self.resultCount = resultCount
        self.lastChanged = lastChanged
        self.position = position
    }
}

extension QueryListOrder {
    /// Sort items by this order. Ties fall back to name, then stored position,
    /// so the result is stable whichever key is chosen.
    public func sorted<T>(_ items: [T], ascending: Bool, key: (T) -> QueryOrderKey) -> [T] {
        let keyed = items.map { (item: $0, key: key($0)) }
        return keyed.sorted { a, b in
            if let primary = compare(a.key, b.key) {
                return ascending ? primary : !primary
            }
            let byName = a.key.name.localizedCaseInsensitiveCompare(b.key.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.key.position < b.key.position
        }
        .map(\.item)
    }

    /// True when `a` comes first ascending, nil on a tie.
    private func compare(_ a: QueryOrderKey, _ b: QueryOrderKey) -> Bool? {
        switch self {
        case .lastChanged:
            return a.lastChanged == b.lastChanged ? nil : a.lastChanged < b.lastChanged
        case .name:
            let result = a.name.localizedCaseInsensitiveCompare(b.name)
            return result == .orderedSame ? nil : result == .orderedAscending
        case .resultCount:
            return a.resultCount == b.resultCount ? nil : a.resultCount < b.resultCount
        case .queryOrder:
            return a.position == b.position ? nil : a.position < b.position
        }
    }
}
