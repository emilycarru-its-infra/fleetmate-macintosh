import Foundation

/// A machine in a custom group, addressed by hostname or IP rather than by
/// roster serial. The IP is the last good address, refreshed after a scan so
/// the group opens online next time.
public struct AdhocDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var hostname: String
    public var ip: String
    /// Roster serial when the device was picked from the roster browser; lets
    /// a scan use inventory for it.
    public var serial: String?

    public init(id: UUID = UUID(), hostname: String, ip: String, serial: String? = nil) {
        self.id = id
        let trimmed = hostname.trimmingCharacters(in: .whitespaces)
        self.hostname = trimmed.isEmpty ? ip : trimmed
        self.ip = ip
        self.serial = serial
    }

    public var computer: RosterComputer {
        RosterComputer.adhoc(hostname: hostname, ip: ip)
    }
}

/// An operator-defined target set outside the roster's room structure.
public struct CustomGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var devices: [AdhocDevice]

    public init(id: UUID = UUID(), name: String, devices: [AdhocDevice] = []) {
        self.id = id
        self.name = name
        self.devices = devices
    }

    /// The group as a sidebar room, so selection and scanning treat it like a lab.
    public var room: RosterRoom {
        RosterRoom(number: "group:\(id.uuidString)", displayName: name, computers: devices.map(\.computer))
    }
}
