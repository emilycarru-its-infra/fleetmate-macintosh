import Foundation

/// An Apple School Manager or Apple Business Manager organization, named after
/// the Key Vault secret prefix its API credentials are stored under.
public struct AppleOrgProfile: Identifiable, Hashable, Sendable {
    public let name: String
    public let clientId: String
    /// School Manager credentials carry a `SCHOOLAPI` client ID; everything
    /// else is Business Manager.
    public var isSchool: Bool { clientId.hasPrefix("SCHOOLAPI") }
    public var serviceName: String { isSchool ? "Apple School Manager" : "Apple Business Manager" }
    public var id: String { name }

    /// What to call each organization: its service, with the profile name
    /// added only when two profiles are the same kind of service.
    public static func labels(for profiles: [AppleOrgProfile]) -> [String: String] {
        var out: [String: String] = [:]
        for p in profiles {
            let sameKind = profiles.filter { $0.isSchool == p.isSchool }.count > 1
            out[p.name] = sameKind ? "\(p.serviceName) (\(p.name))" : p.serviceName
        }
        return out
    }

    public init(name: String, clientId: String) {
        self.name = name
        self.clientId = clientId
    }
}

/// A device management service (an MDM server entry) in the Apple organization.
public struct AppleOrgServer: Identifiable, Hashable, Sendable {
    public let id: String
    /// The profile name of the organization the service belongs to.
    public let orgId: String
    public let name: String
    public let type: String?
    /// Devices assigned to it, from the server-side listing. Nil until read.
    public var deviceCount: Int?

    public init(id: String, orgId: String = "", name: String, type: String?, deviceCount: Int? = nil) {
        self.id = id
        self.orgId = orgId
        self.name = name
        self.type = type
        self.deviceCount = deviceCount
    }
}

/// One device as the Apple organization reports it.
public struct AppleOrgDevice: Identifiable, Hashable, Sendable {
    public let serialNumber: String
    /// The profile name of the organization that holds the device.
    public var orgId: String
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
        serialNumber: String, orgId: String = "", model: String, productFamily: String? = nil, status: String? = nil,
        assignedServerId: String? = nil, orderNumber: String? = nil, purchaseSource: String? = nil,
        addedToOrg: Date? = nil, orderDate: Date? = nil, isMigrationCapable: Bool? = nil,
        migrationStatus: String? = nil, migrationDeadline: Date? = nil, releasedFromOrg: Date? = nil,
        wifiMacAddresses: [String] = [], ethernetMacAddresses: [String] = []
    ) {
        self.serialNumber = serialNumber
        self.orgId = orgId
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

// MARK: - One row per device, Intune first

/// A row of the Devices list: an Intune record enriched with the Apple
/// organization's or Windows Autopilot's record of the same device, or a
/// device one of those knows and Intune does not yet, so it can still be
/// assigned.
public struct DeviceListRow: Identifiable, Sendable {
    public let intune: IntuneDevice?
    public let apple: AppleOrgDevice?
    public let serverName: String?
    /// The organization holding the device, as `AppleOrgProfile.labels` names it.
    public let orgName: String?
    /// The device's Windows Autopilot identity.
    public let autopilot: WindowsAutopilotDevice?
    /// Where a Windows device stands between Autopilot and Intune; nil for
    /// every other platform.
    public let registration: AutopilotRegistration?
    /// A serial from a pasted or imported lookup list that no system knows;
    /// the row exists only to say so.
    public let lookupOnlySerial: String?
    /// Where the systems disagree about this device, as `DeviceDiscrepancy`
    /// labels. Filled in after the rows are joined.
    public var discrepancies: [String] = []

    /// Intune rows keep the Intune ID — every MDM action is keyed on it.
    /// Organization-only rows are prefixed so they can never be mistaken
    /// for one.
    public var id: String {
        if let intune { return intune.id }
        if let apple { return Self.orgOnlyPrefix + apple.serialNumber }
        if let lookupOnlySerial { return Self.unknownPrefix + lookupOnlySerial }
        return Self.autopilotOnlyPrefix + (autopilot?.id ?? autopilot?.serialNumber ?? "")
    }
    public static let orgOnlyPrefix = "apple-org:"
    public static let autopilotOnlyPrefix = "autopilot:"
    public static let unknownPrefix = "unknown:"
    /// What a looked-up serial no system knows reads as.
    public static let notFound = "Not Found"

    /// True for a looked-up serial that no system knows.
    public var isUnknown: Bool { lookupOnlySerial != nil }

    public var isEnrolled: Bool { intune != nil }
    public var serialNumber: String? {
        intune?.serialNumber ?? apple?.serialNumber ?? autopilot?.serialNumber ?? lookupOnlySerial
    }

    public init(intune: IntuneDevice?, apple: AppleOrgDevice?, serverName: String?, orgName: String? = nil,
                autopilot: WindowsAutopilotDevice? = nil, registration: AutopilotRegistration? = nil,
                lookupOnlySerial: String? = nil) {
        self.intune = intune
        self.apple = apple
        self.serverName = serverName
        self.orgName = orgName
        self.autopilot = autopilot
        self.registration = registration
        self.lookupOnlySerial = lookupOnlySerial
    }

    /// A row for a looked-up serial that no system knows.
    public static func unknown(serial: String) -> DeviceListRow {
        DeviceListRow(intune: nil, apple: nil, serverName: nil, lookupOnlySerial: serial)
    }

    /// The same row carrying its Autopilot identity and registration.
    public func with(autopilot: WindowsAutopilotDevice?, registration: AutopilotRegistration?) -> DeviceListRow {
        var row = DeviceListRow(intune: intune, apple: apple, serverName: serverName, orgName: orgName,
                                autopilot: autopilot, registration: registration, lookupOnlySerial: lookupOnlySerial)
        row.discrepancies = discrepancies
        return row
    }

    /// Intune's operating system, or for an organization-only row the one its
    /// product family implies, so a Platform filter keeps it.
    public var platformLabel: String? {
        if let os = intune?.operatingSystem, !os.isEmpty { return os }
        if autopilot != nil { return "Windows" }
        switch apple?.productFamily?.lowercased() {
        case "mac": return "macOS"
        case "ipad": return "iPadOS"
        case "iphone": return "iOS"
        case "appletv": return "tvOS"
        case "vision": return "visionOS"
        case let f?: return f
        case nil: return nil
        }
    }

    /// A Mac, iPhone, iPad or other Apple device, by whichever record says.
    public var isApplePlatform: Bool {
        if apple != nil { return true }
        let p = (platformLabel ?? "").lowercased()
        return p.contains("mac") || p.contains("ios") || p.contains("ipad") || p.contains("tvos") || p.contains("visionos")
    }

    /// The Apple organization's status for the device, or for a Windows
    /// device its Autopilot registration.
    public var orgStatusLabel: String {
        guard let device = apple else { return registration?.rawValue ?? "Not in Organization" }
        if device.releasedFromOrg != nil { return "Released" }
        switch device.status?.uppercased() {
        case "ASSIGNED": return "Assigned"
        case "UNASSIGNED": return "Unassigned"
        case let s?: return s.capitalized
        case nil: return "Unknown"
        }
    }

    /// The MDM a Windows device enrolls with. Autopilot is a registration
    /// program, not a management service, so it never names one: a Windows
    /// device with an Intune MDM record is managed by Intune, and one that is
    /// only registered has none yet.
    public var windowsServiceName: String? {
        guard apple == nil, registration != nil || DevicePlatform(operatingSystem: platformLabel) == .windows,
              let intune else { return nil }
        let agent = intune.managementAgent?.lowercased() ?? "mdm"
        return agent.contains("mdm") ? "Intune" : nil
    }

    public var serviceLabel: String {
        guard apple != nil else {
            if let windows = windowsServiceName { return windows }
            return registration != nil ? "No Service" : "Not in Organization"
        }
        return serverName ?? "No Service"
    }

    public var purchaseSourceLabel: String {
        switch apple?.purchaseSource?.uppercased() {
        case "APPLE": return "Apple"
        case "RESELLER": return "Reseller"
        case "MANUALLY_ADDED": return "Manually Added"
        case let s?: return s.capitalized
        case nil: return "—"
        }
    }

    public var migrationLabel: String {
        guard let status = apple?.migrationStatus?.uppercased(), !status.isEmpty else { return "None" }
        switch status {
        case "REQUESTED": return "Requested"
        case "STARTED": return "In Progress"
        case "SUCCESS": return "Migrated"
        case "FAILED": return "Failed"
        default: return status.capitalized
        }
    }

    public var enrollmentLabel: String { isEnrolled ? "Enrolled" : isUnknown ? Self.notFound : "Not Enrolled" }

    // MARK: Column values — the same columns for every row, "—" when the
    // row's sources have no value.

    public static let missing = "—"

    public var nameText: String { intune?.deviceName ?? (isUnknown ? DeviceListRow.notFound : Self.missing) }
    public var serialText: String { serialNumber ?? Self.missing }
    public var platformText: String { platformLabel ?? Self.missing }
    public var osText: String {
        let parts = [intune?.operatingSystem, intune?.osVersion].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? Self.missing : parts.joined(separator: " ")
    }
    public var userText: String { intune?.userDisplayName ?? intune?.userPrincipalName ?? Self.missing }
    public var modelText: String { intune?.model ?? apple?.model ?? autopilot?.model ?? Self.missing }
    public var manufacturerText: String {
        intune?.manufacturer ?? (apple != nil ? "Apple" : nil) ?? autopilot?.manufacturer ?? Self.missing
    }
    public var ownershipText: String { intune?.managedDeviceOwnerType?.capitalized ?? Self.missing }
    public var complianceText: String {
        if isUnknown { return Self.missing }
        guard let intune else { return "Not Enrolled" }
        return intune.complianceState?.capitalized ?? "Unknown"
    }
    public var serviceText: String { serverName ?? windowsServiceName ?? Self.missing }
    public var orgStatusText: String { apple == nil && registration == nil ? Self.missing : orgStatusLabel }
    /// The device's grouping in its provisioning system: the Apple order
    /// number for an Apple organization device, the group tag for an
    /// Autopilot one.
    public var groupOrOrderText: String { apple?.orderNumber ?? Self.nonEmpty(autopilot?.groupTag) ?? Self.missing }
    public var migrationText: String { apple == nil ? Self.missing : migrationLabel }
    /// Where the device was bought from: Apple's purchase source, or the
    /// purchase order an Autopilot registration carries.
    public var purchaseSourceText: String {
        if apple != nil { return purchaseSourceLabel }
        return Self.nonEmpty(autopilot?.purchaseOrderIdentifier) ?? Self.missing
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    /// Autopilot facet values: the identity's own, "Not Registered" for a
    /// Windows device with none, and "Not in Autopilot" for other platforms.
    private func autopilotValue(_ read: (WindowsAutopilotDevice) -> String) -> String {
        if let autopilot { return read(autopilot) }
        return registration == nil ? "Not in Autopilot" : "Not Registered"
    }

    /// The value a Devices filter reads for this row. Every facet answers
    /// for every row, so a filter never drops a row just because one of its
    /// sources lacked the value.
    public func value(for facet: DeviceFacet) -> String {
        switch facet {
        case .managementService: serviceLabel
        case .orgStatus: orgStatusLabel
        case .appleOrganization: apple == nil ? "Not in Organization" : (orgName ?? "Apple Organization")
        case .groupTag: autopilotValue(\.groupTagLabel)
        case .deploymentProfile: autopilotValue(\.profileStatusLabel)
        case .autopilotEnrollment: autopilotValue(\.enrollmentStateLabel)
        case .platform: platformLabel ?? "Unknown"
        case .compliance: complianceText
        case .manufacturer: intune?.manufacturer ?? (apple != nil ? "Apple" : "Unknown")
        case .model: intune?.model ?? apple?.model ?? "Unknown"
        case .ownership: intune?.managedDeviceOwnerType ?? "Unknown"
        case .migration: migrationLabel
        case .enrollment: enrollmentLabel
        case .discrepancy: discrepancies.first ?? DeviceDiscrepancy.none
        }
    }

    /// Every value a filter reads for this row. A device can disagree with
    /// several systems at once, so Discrepancy answers with all of them.
    public func values(for facet: DeviceFacet) -> [String] {
        if facet == .discrepancy { return discrepancies.isEmpty ? [DeviceDiscrepancy.none] : discrepancies }
        return [value(for: facet)]
    }

    // Sort keys. Dates sort as ISO strings; a missing value sorts first.
    public var lastSyncKey: String { intune?.lastSyncDateTime ?? "" }
    public var addedKey: String { apple?.addedToOrg.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
}

/// The Devices list's filter categories, in the order the Filters popover
/// lists them: the Apple organization's first, then Intune's.
public enum DeviceFacet: String, CaseIterable, Identifiable, Sendable {
    case managementService = "Device Management Service"
    case orgStatus = "Organization Status"
    case appleOrganization = "Apple Organization"
    case groupTag = "Group Tag"
    case deploymentProfile = "Deployment Profile"
    case autopilotEnrollment = "Autopilot Enrollment"
    case platform = "Platform"
    case compliance = "Compliance"
    case manufacturer = "Manufacturer"
    case model = "Model"
    case ownership = "Ownership"
    case migration = "Migration"
    case enrollment = "Enrollment"
    case discrepancy = "Discrepancies"

    public var id: String { rawValue }

    /// Facets with nothing to say when no Apple organization is configured.
    public static let appleOrgOnly: Set<DeviceFacet> = [.appleOrganization, .migration]
    /// Facets with nothing to say when no Autopilot identity was read.
    public static let autopilotOnly: Set<DeviceFacet> = [.groupTag, .deploymentProfile, .autopilotEnrollment]
    /// Facets either source fills: hidden only when neither is present.
    public static let provisioning: Set<DeviceFacet> = [.managementService, .orgStatus]

    /// The categories to hide for the sources that are present.
    public static func hidden(hasAppleOrg: Bool, hasAutopilot: Bool) -> Set<DeviceFacet> {
        var out: Set<DeviceFacet> = []
        if !hasAppleOrg { out.formUnion(appleOrgOnly) }
        if !hasAutopilot { out.formUnion(autopilotOnly) }
        if !hasAppleOrg && !hasAutopilot { out.formUnion(provisioning) }
        return out
    }
}

public enum AppleOrgJoin {
    /// Serials compare uppercased and trimmed: a hand-entered Intune serial
    /// can carry whitespace.
    public static func normalize(_ serial: String) -> String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Every Intune record becomes a row, carrying the Apple record of its
    /// serial when the organization has one — two Intune records of one
    /// serial (a re-enrolment leaves the old one until it ages out) both
    /// carry it. Apple devices no Intune record matches follow as their own
    /// rows, so they stay visible and assignable.
    public static func merge(
        intune: [IntuneDevice],
        apple: [AppleOrgDevice],
        servers: [AppleOrgServer],
        orgLabels: [String: String] = [:]
    ) -> [DeviceListRow] {
        let serverNames = Dictionary(servers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // A device released from one organization and re-added to another is
        // reported by both; the one still holding it wins.
        let appleBySerial = Dictionary(apple.map { (normalize($0.serialNumber), $0) }) { a, b in
            a.releasedFromOrg == nil ? a : b
        }
        func row(_ record: IntuneDevice?, _ d: AppleOrgDevice?) -> DeviceListRow {
            DeviceListRow(intune: record, apple: d,
                          serverName: d?.assignedServerId.flatMap { serverNames[$0] },
                          orgName: d.flatMap { orgLabels[$0.orgId] })
        }

        var matched = Set<String>()
        var rows: [DeviceListRow] = intune.map { record in
            let key = record.serialNumber.map(normalize) ?? ""
            let device = key.isEmpty ? nil : appleBySerial[key]
            if device != nil { matched.insert(key) }
            return row(record, device)
        }
        for (key, device) in appleBySerial where !matched.contains(key) {
            rows.append(row(nil, device))
        }
        return rows
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

/// A device's Activation Lock state as its Apple organization reports it.
///
/// The organization is the authority here: it knows the live state, covers
/// Macs as well as iPhones and iPads, and is the only source that says which
/// kind of lock is set. A read that fails or returns nothing is `.unknown`,
/// never `.disabled` — "Disabled" from a failure would be the wrong answer.
public enum AppleActivationLock: Hashable, Sendable {
    case mdmLock
    case userLock
    /// Locked, but the organization did not say which kind.
    case enabled
    case disabled
    case unknown

    /// Maps the organization's answer. `nil` means it could not report one.
    public init(isLocked: Bool?, lockType: String?) {
        guard let isLocked else { self = .unknown; return }
        guard isLocked else { self = .disabled; return }
        switch lockType?.uppercased() {
        case "MDM": self = .mdmLock
        case "USER": self = .userLock
        default: self = .enabled
        }
    }

    public var isLocked: Bool {
        switch self {
        case .mdmLock, .userLock, .enabled: true
        case .disabled, .unknown: false
        }
    }

    /// Short value for the table column.
    public var columnText: String {
        switch self {
        case .mdmLock: "Enabled — MDM"
        case .userLock: "Enabled — User"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }

    /// Full value for the inspector, saying what the lock means for clearing it.
    public var detailText: String {
        switch self {
        case .mdmLock: "Enabled — MDM lock (bypass code escrowed; clearing doesn't need the owner)"
        case .userLock: "Enabled — User lock (needs the owner's Apple Account)"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }
}
