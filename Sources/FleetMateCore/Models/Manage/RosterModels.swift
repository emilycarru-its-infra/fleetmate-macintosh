import Foundation

/// One row of the fleet roster (the enrollment computers.csv). Serial is the
/// stable identity; hostname is what the network knows the machine as, and is
/// empty for machines that have not been provisioned yet.
public struct RosterComputer: Identifiable, Hashable, Sendable, Codable {
    public static let adhocSerialPrefix = "adhoc-"

    public var serial: String
    public var catalog: String
    public var area: String
    public var location: String
    public var asset: String
    public var usage: String
    public var status: String
    /// Person the machine is assigned to, or a descriptive label for shared machines.
    public var allocation: String
    public var username: String
    public var platform: String
    /// Lab or fleet grouping (for example "Foundation Studio"). The real lab grouping; location is the fallback.
    public var fleet: String
    public var hostname: String

    public init(
        serial: String, catalog: String = "", area: String = "", location: String = "",
        asset: String = "", usage: String = "", status: String = "", allocation: String = "",
        username: String = "", platform: String = "", fleet: String = "", hostname: String = ""
    ) {
        self.serial = serial
        self.catalog = catalog
        self.area = area
        self.location = location
        self.asset = asset
        self.usage = usage
        self.status = status
        self.allocation = allocation
        self.username = username
        self.platform = platform
        self.fleet = fleet
        self.hostname = hostname
    }

    public var id: String { serial }

    public var hasHostname: Bool { !hostname.trimmingCharacters(in: .whitespaces).isEmpty }

    public var isAdhoc: Bool { serial.hasPrefix(Self.adhocSerialPrefix) }

    /// Bonjour name for mDNS resolution.
    public var localHostname: String { "\(hostname).local" }

    /// In-service means any "Active" variant: Active, Active (Legacy), Active (Buyouts),
    /// Active (Lease End). Everything else has left the fleet and must never enter a batch.
    public var isInService: Bool {
        status.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("active")
    }

    /// The roster's friendly name (allocation), falling back to `displayName`.
    public var friendlyName: String {
        allocation.isEmpty ? displayName : allocation
    }

    /// What to show for the machine: hostname, else the assignee, else the serial.
    public var displayName: String {
        if hasHostname { return hostname }
        if !allocation.isEmpty { return allocation }
        return serial
    }

    /// A temporary machine that is not in the roster, addressed by hostname or IP.
    public static func adhoc(hostname: String, ip: String) -> RosterComputer {
        let trimmed = hostname.trimmingCharacters(in: .whitespaces)
        let label = trimmed.isEmpty ? ip : trimmed
        return RosterComputer(
            serial: adhocSerialPrefix + label,
            status: "Active",
            allocation: label,
            platform: "Macintosh",
            hostname: label
        )
    }

    /// One line suitable for a ticket or hand-off note.
    public func inventoryLine(ip: String? = nil, osVersion: String? = nil) -> String {
        var parts = [displayName]
        if let ip, !ip.isEmpty { parts.append(ip) }
        if !isAdhoc { parts.append(serial) }
        if !asset.isEmpty { parts.append(asset) }
        if !location.isEmpty { parts.append(location) }
        if let osVersion, !osVersion.isEmpty { parts.append(osVersion) }
        return parts.joined(separator: "  ")
    }
}

/// A sidebar group: a lab, a kiosk room, a department's staff machines, or a
/// letter bucket of faculty machines. `number` is the short key shown first
/// (room number, department, letter); `displayName` the longer label when known.
public struct RosterRoom: Identifiable, Hashable, Sendable {
    public var number: String
    public var displayName: String?
    /// Where the machines are: the room most of them sit in. Nil when the
    /// group key already is the room, so nothing repeats itself.
    public var location: String?
    public var computers: [RosterComputer]

    public init(number: String, displayName: String? = nil, location: String? = nil, computers: [RosterComputer]) {
        self.number = number
        self.displayName = displayName
        self.location = (location == number) ? nil : location
        self.computers = computers
    }

    public var id: String { number }
    public var count: Int { computers.count }

    public var name: String {
        if let displayName, !displayName.isEmpty, displayName != number {
            return "\(number) · \(displayName)"
        }
        return number
    }
}

/// The roster split into sidebar sections.
public struct FleetRoster: Sendable {
    public var labs: [RosterRoom]
    public var kiosks: [RosterRoom]
    public var staff: [RosterRoom]
    public var faculty: [RosterRoom]
    /// Every in-service row with a hostname, for search and the group browser.
    public var sourceComputers: [RosterComputer]

    public init(labs: [RosterRoom] = [], kiosks: [RosterRoom] = [], staff: [RosterRoom] = [],
                faculty: [RosterRoom] = [], sourceComputers: [RosterComputer] = []) {
        self.labs = labs
        self.kiosks = kiosks
        self.staff = staff
        self.faculty = faculty
        self.sourceComputers = sourceComputers
    }

    public static let empty = FleetRoster()

    public var isEmpty: Bool { labs.isEmpty && kiosks.isEmpty && staff.isEmpty && faculty.isEmpty }

    public var allRooms: [RosterRoom] { labs + kiosks + staff + faculty }

    public var allComputers: [RosterComputer] { allRooms.flatMap(\.computers) }

    public func room(id: String) -> RosterRoom? {
        allRooms.first { $0.id == id }
    }
}
