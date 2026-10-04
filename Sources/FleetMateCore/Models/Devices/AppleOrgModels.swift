import Foundation

/// An Apple School Manager or Apple Business Manager API profile, as stored in
/// asbmutil's keychain so a profile made with `asbmutil config set` shows up
/// here unchanged.
public struct AppleOrgProfile: Identifiable, Hashable, Sendable {
    public let name: String
    public let clientId: String
    /// School Manager credentials carry a `SCHOOLAPI` client ID; everything
    /// else is Business Manager.
    public var isSchool: Bool { clientId.hasPrefix("SCHOOLAPI") }
    public var serviceName: String { isSchool ? "Apple School Manager" : "Apple Business Manager" }
    public var id: String { name }

    public init(name: String, clientId: String) {
        self.name = name
        self.clientId = clientId
    }
}

/// A device management service (an MDM server entry) in the Apple organization.
public struct AppleOrgServer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String?
    /// Devices assigned to it, from the server-side listing. Nil until read.
    public var deviceCount: Int?

    public init(id: String, name: String, type: String?, deviceCount: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.deviceCount = deviceCount
    }
}

/// One device as the Apple organization reports it.
public struct AppleOrgDevice: Identifiable, Hashable, Sendable {
    public let serialNumber: String
    public let model: String
    public let productFamily: String?
    /// `ASSIGNED` or `UNASSIGNED`.
    public let status: String?
    public var assignedServerId: String?
    public let orderNumber: String?
    /// `APPLE`, `RESELLER` or `MANUALLY_ADDED`.
    public let purchaseSource: String?
    public let addedToOrg: Date?
    public let orderDate: Date?
    public let isMigrationCapable: Bool?
    /// `REQUESTED`, `STARTED`, `SUCCESS` or `FAILED`.
    public let migrationStatus: String?
    public let migrationDeadline: Date?
    public let releasedFromOrg: Date?
    public let wifiMacAddresses: [String]
    public let ethernetMacAddresses: [String]

    public var id: String { serialNumber }

    public init(
        serialNumber: String, model: String, productFamily: String? = nil, status: String? = nil,
        assignedServerId: String? = nil, orderNumber: String? = nil, purchaseSource: String? = nil,
        addedToOrg: Date? = nil, orderDate: Date? = nil, isMigrationCapable: Bool? = nil,
        migrationStatus: String? = nil, migrationDeadline: Date? = nil, releasedFromOrg: Date? = nil,
        wifiMacAddresses: [String] = [], ethernetMacAddresses: [String] = []
    ) {
        self.serialNumber = serialNumber
        self.model = model
        self.productFamily = productFamily
        self.status = status
        self.assignedServerId = assignedServerId
        self.orderNumber = orderNumber
        self.purchaseSource = purchaseSource
        self.addedToOrg = addedToOrg
        self.orderDate = orderDate
        self.isMigrationCapable = isMigrationCapable
        self.migrationStatus = migrationStatus
        self.migrationDeadline = migrationDeadline
        self.releasedFromOrg = releasedFromOrg
        self.wifiMacAddresses = wifiMacAddresses
        self.ethernetMacAddresses = ethernetMacAddresses
    }

    /// A migration Apple has not finished yet.
    public var hasActiveMigration: Bool {
        let s = migrationStatus?.uppercased()
        return s == "REQUESTED" || s == "STARTED"
    }
}

/// One AppleCare or warranty agreement on a device.
public struct AppleCareAgreement: Hashable, Sendable {
    public let description: String
    public let status: String?
    public let start: Date?
    public let end: Date?
    public let agreementNumber: String?
    public let paymentType: String?
    public let isCanceled: Bool

    public init(description: String, status: String?, start: Date?, end: Date?,
                agreementNumber: String?, paymentType: String?, isCanceled: Bool) {
        self.description = description
        self.status = status
        self.start = start
        self.end = end
        self.agreementNumber = agreementNumber
        self.paymentType = paymentType
        self.isCanceled = isCanceled
    }
}

/// What can be asked of the Apple organization for a set of devices.
public enum AppleOrgAction: Hashable, Sendable {
    case assign(serverId: String)
    case unassign(serverId: String)
    case scheduleMigration(serverId: String, deadline: Date)
    case updateMigrationDeadline(Date)
    case cancelMigration
    /// Apple Business Manager only, and irreversible.
    case release

    /// Apple caps a migration deadline at 90 days out.
    public static let maxMigrationDays = 90

    public var title: String {
        switch self {
        case .assign: "Assign"
        case .unassign: "Unassign"
        case .scheduleMigration: "Schedule Migration"
        case .updateMigrationDeadline: "Change Migration Deadline"
        case .cancelMigration: "Cancel Migration"
        case .release: "Release from Organization"
        }
    }

    public var isBusinessOnly: Bool { self == .release }

    /// The latest deadline Apple accepts from `now`.
    public static func latestDeadline(from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: maxMigrationDays, to: now) ?? now
    }
}

/// How an Apple organization activity ended.
public struct AppleOrgActivityResult: Sendable {
    public let activityId: String
    /// Apple's terminal status (`COMPLETED`, `FAILED`, …) or `TIMEOUT`.
    public let status: String
    public let serials: [String]

    public init(activityId: String, status: String, serials: [String]) {
        self.activityId = activityId
        self.status = status
        self.serials = serials
    }

    public var succeeded: Bool {
        let s = status.uppercased()
        return s == "COMPLETED" || s == "COMPLETE"
    }
}

// MARK: - Joined with Intune

/// An Apple organization device paired with the Intune record of the same
/// serial, when there is one.
public struct AppleOrgRow: Identifiable, Sendable {
    public let device: AppleOrgDevice
    public let intune: IntuneDevice?
    public let serverName: String?

    public var id: String { device.serialNumber }
    public var isEnrolled: Bool { intune != nil }

    public init(device: AppleOrgDevice, intune: IntuneDevice?, serverName: String?) {
        self.device = device
        self.intune = intune
        self.serverName = serverName
    }

    // Sort keys: String so Table's KeyPathComparator can use them directly.
    public var serialKey: String { device.serialNumber }
    public var modelKey: String { device.model }
    public var statusKey: String { statusLabel }
    public var serverKey: String { serverName ?? "" }
    public var orderKey: String { device.orderNumber ?? "" }
    public var sourceKey: String { purchaseSourceLabel }
    public var addedKey: String { device.addedToOrg.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
    public var migrationKey: String { migrationLabel }
    public var nameKey: String { intune?.deviceName ?? "" }
    public var complianceKey: String { complianceLabel }
    public var lastSyncKey: String { intune?.lastSyncDateTime ?? "" }

    public var statusLabel: String {
        if device.releasedFromOrg != nil { return "Released" }
        switch device.status?.uppercased() {
        case "ASSIGNED": return "Assigned"
        case "UNASSIGNED": return "Unassigned"
        case let s?: return s.capitalized
        case nil: return "Unknown"
        }
    }

    public var purchaseSourceLabel: String {
        switch device.purchaseSource?.uppercased() {
        case "APPLE": return "Apple"
        case "RESELLER": return "Reseller"
        case "MANUALLY_ADDED": return "Manually Added"
        case let s?: return s.capitalized
        case nil: return "—"
        }
    }

    public var migrationLabel: String {
        guard let status = device.migrationStatus?.uppercased(), !status.isEmpty else { return "None" }
        switch status {
        case "REQUESTED": return "Requested"
        case "STARTED": return "In Progress"
        case "SUCCESS": return "Migrated"
        case "FAILED": return "Failed"
        default: return status.capitalized
        }
    }

    public var complianceLabel: String {
        guard let intune else { return "Not Enrolled" }
        return intune.complianceState?.capitalized ?? "Unknown"
    }

    /// The value a filter facet reads for this row. Every facet answers for
    /// every row, so a filter never silently drops a row whose value was
    /// simply absent.
    public func value(for facet: AppleOrgFacet) -> String {
        switch facet {
        case .status: statusLabel
        case .server: serverName ?? "No Service"
        case .model: device.model
        case .order: device.orderNumber ?? "No Order"
        case .purchaseSource: purchaseSourceLabel
        case .migration: migrationLabel
        case .enrollment: isEnrolled ? "Enrolled in Intune" : "Not Enrolled"
        case .compliance: complianceLabel
        }
    }
}

/// Facets the Mac device list filters on.
public enum AppleOrgFacet: String, CaseIterable, Identifiable, Sendable {
    case status = "Organization Status"
    case server = "Device Management Service"
    case enrollment = "Enrollment"
    case compliance = "Compliance"
    case migration = "Migration"
    case model = "Model"
    case order = "Order"
    case purchaseSource = "Purchase Source"
    public var id: String { rawValue }
}

public enum AppleOrgJoin {
    /// Serials compare uppercased and trimmed: Intune and Apple disagree on
    /// neither today, but a hand-entered Intune serial can carry whitespace.
    public static func normalize(_ serial: String) -> String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Pair each Apple device with the Intune record of the same serial. When
    /// Intune holds two records for one serial (a re-enrolment leaves the old
    /// one behind until it ages out), the most recently synced wins.
    public static func join(
        devices: [AppleOrgDevice],
        intune: [IntuneDevice],
        servers: [AppleOrgServer]
    ) -> [AppleOrgRow] {
        var bySerial: [String: IntuneDevice] = [:]
        for record in intune {
            guard let serial = record.serialNumber, !serial.isEmpty else { continue }
            let key = normalize(serial)
            if let existing = bySerial[key], (existing.lastSyncDateTime ?? "") >= (record.lastSyncDateTime ?? "") {
                continue
            }
            bySerial[key] = record
        }
        let serverNames = Dictionary(servers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return devices.map { device in
            AppleOrgRow(
                device: device,
                intune: bySerial[normalize(device.serialNumber)],
                serverName: device.assignedServerId.flatMap { serverNames[$0] }
            )
        }
    }

    /// Serial → server ID from each server's device listing, which is the
    /// only bulk source of assignments: the organization's device list does
    /// not carry the relationship.
    public static func assignments(fromServerListings listings: [String: [String]]) -> [String: String] {
        var out: [String: String] = [:]
        for (serverId, serials) in listings {
            for serial in serials { out[normalize(serial)] = serverId }
        }
        return out
    }
}
