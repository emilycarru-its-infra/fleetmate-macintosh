import Foundation

/// What the Manage sidebar has selected and, from that, which machines are
/// the current targets. Rooms and custom groups can be combined with the
/// command key; a search picks a temporary set that replaces both.
///
/// Pure state so the rules are testable away from the view model that owns
/// scanning and results.
public struct ManageSelection: Equatable, Sendable {
    public var roomIDs: Set<String> = []
    public var groupIDs: Set<UUID> = []
    /// A temporary target set built from search results, with its label.
    public var searchSet: (label: String, computers: [RosterComputer])? {
        get { searchLabel.map { ($0, searchComputers) } }
        set {
            searchLabel = newValue?.label
            searchComputers = newValue?.computers ?? []
        }
    }
    private var searchLabel: String?
    private var searchComputers: [RosterComputer] = []
    /// Machines added to the current view without joining a group.
    public var adhocComputers: [RosterComputer] = []

    public init() {}

    public static func == (lhs: ManageSelection, rhs: ManageSelection) -> Bool {
        lhs.roomIDs == rhs.roomIDs && lhs.groupIDs == rhs.groupIDs
            && lhs.searchLabel == rhs.searchLabel && lhs.searchComputers == rhs.searchComputers
            && lhs.adhocComputers == rhs.adhocComputers
    }

    public var isEmpty: Bool { roomIDs.isEmpty && groupIDs.isEmpty && searchLabel == nil }

    public var isSearch: Bool { searchLabel != nil }

    // MARK: - Mutation

    /// Click a room: replace the selection, or toggle it in with `extending`.
    public mutating func selectRoom(_ id: String, extending: Bool) {
        searchSet = nil
        if extending {
            if roomIDs.contains(id) { roomIDs.remove(id) } else { roomIDs.insert(id) }
        } else {
            roomIDs = [id]
            groupIDs = []
            adhocComputers = []
        }
    }

    public mutating func selectRooms(_ ids: Set<String>) {
        searchSet = nil
        roomIDs = ids
        groupIDs = []
        adhocComputers = []
    }

    public mutating func selectGroup(_ id: UUID, extending: Bool) {
        searchSet = nil
        if extending {
            if groupIDs.contains(id) { groupIDs.remove(id) } else { groupIDs.insert(id) }
        } else {
            groupIDs = [id]
            roomIDs = []
            adhocComputers = []
        }
    }

    public mutating func selectSearchResults(_ computers: [RosterComputer], label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        roomIDs = []
        groupIDs = []
        adhocComputers = []
        searchSet = (trimmed.isEmpty ? "Search Results" : "Search: \(trimmed)", Self.uniqueBySerial(computers))
    }

    public mutating func clear() {
        roomIDs = []
        groupIDs = []
        adhocComputers = []
        searchSet = nil
    }

    public mutating func removeGroup(_ id: UUID) {
        groupIDs.remove(id)
    }

    public mutating func addAdhoc(_ computer: RosterComputer) {
        guard !adhocComputers.contains(where: { $0.id == computer.id }) else { return }
        adhocComputers.append(computer)
    }

    // MARK: - Derived

    /// The one selected room when exactly one room and no group is selected.
    public func primaryRoom(in roster: FleetRoster) -> RosterRoom? {
        guard roomIDs.count == 1, groupIDs.isEmpty, let id = roomIDs.first else { return nil }
        return roster.room(id: id)
    }

    /// The one selected group when exactly one group and no room is selected.
    public func primaryGroup(in groups: [CustomGroup]) -> CustomGroup? {
        guard groupIDs.count == 1, roomIDs.isEmpty, let id = groupIDs.first else { return nil }
        return groups.first { $0.id == id }
    }

    public func selectedRooms(in roster: FleetRoster) -> [RosterRoom] {
        roster.allRooms.filter { roomIDs.contains($0.id) }
    }

    public func selectedGroups(in groups: [CustomGroup]) -> [CustomGroup] {
        groups.filter { groupIDs.contains($0.id) }
    }

    /// Every machine in the current view, de-duplicated by serial, in
    /// sidebar order: rooms, then groups, then ad-hoc additions.
    public func currentComputers(roster: FleetRoster, groups: [CustomGroup]) -> [RosterComputer] {
        if let searchSet {
            return Self.uniqueBySerial(searchSet.computers + adhocComputers)
        }
        let fromRooms = selectedRooms(in: roster).flatMap(\.computers)
        let fromGroups = selectedGroups(in: groups).flatMap { $0.devices.map(\.computer) }
        return Self.uniqueBySerial(fromRooms + fromGroups + adhocComputers)
    }

    /// What the current view is called, for the scan label and the header.
    public func label(roster: FleetRoster, groups: [CustomGroup]) -> String {
        if let searchSet { return searchSet.label }
        let names = selectedRooms(in: roster).map(\.name) + selectedGroups(in: groups).map(\.name)
        switch names.count {
        case 0: return "Selection"
        case 1: return names[0]
        default: return "\(names.count) groups"
        }
    }

    /// Stored addresses for ad-hoc devices in the selected groups, so a scan
    /// can probe them without resolving.
    public func knownAddresses(groups: [CustomGroup]) -> [String: String] {
        var map: [String: String] = [:]
        for group in selectedGroups(in: groups) {
            for device in group.devices where !device.ip.isEmpty {
                map[device.hostname] = device.ip
            }
        }
        for computer in adhocComputers where computer.isAdhoc {
            // Ad-hoc additions carry their address as the hostname when it is an IP.
            if Self.looksLikeIPv4(computer.hostname) { map[computer.hostname] = computer.hostname }
        }
        return map
    }

    static func uniqueBySerial(_ computers: [RosterComputer]) -> [RosterComputer] {
        var seen: Set<String> = []
        return computers.filter { seen.insert($0.id).inserted }
    }

    static func looksLikeIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

/// Search across the roster for the sidebar's search mode.
public enum RosterSearch {
    /// Machines whose hostname, friendly name, username, serial or asset
    /// tag contains `query`, de-duplicated, in roster order.
    public static func matches(_ query: String, in roster: FleetRoster) -> [RosterComputer] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hits = roster.allComputers.filter { c in
            c.hostname.localizedCaseInsensitiveContains(q)
                || c.allocation.localizedCaseInsensitiveContains(q)
                || c.username.localizedCaseInsensitiveContains(q)
                || c.serial.localizedCaseInsensitiveContains(q)
                || c.asset.localizedCaseInsensitiveContains(q)
        }
        return ManageSelection.uniqueBySerial(hits)
    }

    /// Rooms whose key, display name or members match `query`.
    public static func rooms(_ query: String, in rooms: [RosterRoom]) -> [RosterRoom] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rooms }
        return rooms.filter { room in
            room.number.localizedCaseInsensitiveContains(q)
                || (room.displayName?.localizedCaseInsensitiveContains(q) ?? false)
                || room.computers.contains {
                    $0.hostname.localizedCaseInsensitiveContains(q)
                        || $0.allocation.localizedCaseInsensitiveContains(q)
                        || $0.serial.localizedCaseInsensitiveContains(q)
                }
        }
    }
}
