import Foundation

// MARK: - Labels

public extension WindowsAutopilotDevice {
    /// The deployment profile assignment, as a reader would say it.
    var profileStatusLabel: String {
        switch deploymentProfileAssignmentStatus?.lowercased() {
        case "assignedinsync", "assignedoutofsync", "assignedunkownsyncstate", "assignedunknownsyncstate":
            return "Assigned"
        case "notassigned": return "Not Assigned"
        case "pending": return "Pending"
        case "failed": return "Failed"
        case nil, "", "unknown": return "Unknown"
        case let s?: return s
        }
    }

    /// True once a deployment profile reaches the device, whatever its sync state.
    var isProfileAssigned: Bool { profileStatusLabel == "Assigned" }

    /// Autopilot's own enrollment state for the identity.
    var enrollmentStateLabel: String {
        switch enrollmentState?.lowercased() {
        case "enrolled": return "Enrolled"
        case "notcontacted": return "Not Contacted"
        case "pendingreset": return "Pending Reset"
        case "failed": return "Failed"
        case "blocked": return "Blocked"
        case nil, "", "unknown": return "Unknown"
        case let s?: return s
        }
    }

    var groupTagLabel: String {
        let tag = groupTag?.trimmingCharacters(in: .whitespaces) ?? ""
        return tag.isEmpty ? "No Group Tag" : tag
    }

    /// Graph reports an all-zero GUID when no managed device is linked.
    var linkedManagedDeviceId: String? {
        guard let id = managedDeviceId?.lowercased(), !id.isEmpty,
              id != "00000000-0000-0000-0000-000000000000" else { return nil }
        return id
    }
}

// MARK: - Joined with Intune

/// Where a Windows device stands between Autopilot and Intune.
public enum AutopilotRegistration: String, CaseIterable, Sendable {
    case registeredAndEnrolled = "Registered"
    case registeredNotEnrolled = "Registered, Not Enrolled"
    case enrolledNotRegistered = "Not Registered"
}

/// Autopilot identities matched to the Intune records they describe.
public struct AutopilotIndex: Sendable {
    /// Intune managed device id (lowercased) → its Autopilot identity.
    public let byManagedDeviceId: [String: WindowsAutopilotDevice]
    /// Identities no Intune record matched: registered, never (or no longer) enrolled.
    public let unenrolled: [WindowsAutopilotDevice]

    public func autopilot(for device: IntuneDevice) -> WindowsAutopilotDevice? {
        byManagedDeviceId[device.id.lowercased()]
    }

    /// Nil for a device that is not Windows and has no Autopilot identity:
    /// registration means nothing there.
    public func registration(for device: IntuneDevice) -> AutopilotRegistration? {
        if autopilot(for: device) != nil { return .registeredAndEnrolled }
        return DevicePlatform(operatingSystem: device.operatingSystem) == .windows ? .enrolledNotRegistered : nil
    }
}

public enum AutopilotJoin {
    public static func normalize(_ serial: String) -> String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Match each identity to an Intune record: first by the managed device id
    /// Autopilot links, then by Entra device id, then by serial. A serial match
    /// prefers the most recently synced record, since a re-enrolment leaves the
    /// old one behind until it ages out. Each Intune record matches at most once.
    public static func index(autopilot: [WindowsAutopilotDevice], intune: [IntuneDevice]) -> AutopilotIndex {
        var byId: [String: IntuneDevice] = [:]
        var byEntra: [String: IntuneDevice] = [:]
        var bySerial: [String: IntuneDevice] = [:]
        for record in intune {
            byId[record.id.lowercased()] = record
            if let entra = record.azureADDeviceId?.lowercased(), !entra.isEmpty,
               entra != "00000000-0000-0000-0000-000000000000" {
                byEntra[entra] = record
            }
            if let serial = record.serialNumber, !serial.isEmpty {
                let key = normalize(serial)
                if let existing = bySerial[key], (existing.lastSyncDateTime ?? "") >= (record.lastSyncDateTime ?? "") {
                    continue
                }
                bySerial[key] = record
            }
        }

        var matched: [String: WindowsAutopilotDevice] = [:]
        var unenrolled: [WindowsAutopilotDevice] = []
        for identity in autopilot {
            let candidate = identity.linkedManagedDeviceId.flatMap { byId[$0] }
                ?? identity.azureActiveDirectoryDeviceId.flatMap { byEntra[$0.lowercased()] }
                ?? identity.serialNumber.flatMap { bySerial[normalize($0)] }
            if let record = candidate, matched[record.id.lowercased()] == nil {
                matched[record.id.lowercased()] = identity
            } else {
                unenrolled.append(identity)
            }
        }
        return AutopilotIndex(byManagedDeviceId: matched, unenrolled: unenrolled)
    }

    /// Layer Autopilot onto the Devices list: each Intune row carries its
    /// identity and registration, and identities no Intune record matches
    /// follow as their own rows — registered, not enrolled.
    public static func enrich(_ rows: [DeviceListRow], autopilot: [WindowsAutopilotDevice]) -> [DeviceListRow] {
        guard !autopilot.isEmpty else { return rows }
        let index = Self.index(autopilot: autopilot, intune: rows.compactMap(\.intune))
        var out = rows.map { row -> DeviceListRow in
            guard let record = row.intune else { return row }
            return row.with(autopilot: index.autopilot(for: record), registration: index.registration(for: record))
        }
        out += index.unenrolled.map {
            DeviceListRow(intune: nil, apple: nil, serverName: nil, autopilot: $0, registration: .registeredNotEnrolled)
        }
        return out
    }
}

// MARK: - Actions

/// What can be asked of Autopilot for a set of identities.
public enum AutopilotAction: Hashable, Sendable {
    case setGroupTag(String)
    case assignUser(String)
    case unassignUser
    case delete

    public var title: String {
        switch self {
        case .setGroupTag: "Set Group Tag"
        case .assignUser: "Assign User"
        case .unassignUser: "Unassign User"
        case .delete: "Delete Autopilot Identity"
        }
    }

    /// Whether the action can reach every device in a selection. A selection
    /// offers an action only when it is valid for all of it: a device with no
    /// Autopilot identity rules every Autopilot action out.
    public func isAvailable(for identities: [WindowsAutopilotDevice?]) -> Bool {
        guard !identities.isEmpty, identities.allSatisfy({ $0?.id != nil }) else { return false }
        switch self {
        case .unassignUser:
            return identities.allSatisfy { !($0?.userPrincipalName ?? "").isEmpty }
        case .setGroupTag, .assignUser, .delete:
            return true
        }
    }
}

// MARK: - Hardware hash import

/// One row of a hardware hash CSV, as `Get-WindowsAutopilotInfo` writes it.
public struct AutopilotHashEntry: Hashable, Sendable {
    public let serialNumber: String
    public let productKey: String?
    public let hardwareHash: String
    public let groupTag: String?
    public let assignedUser: String?

    public init(serialNumber: String, productKey: String? = nil, hardwareHash: String,
                groupTag: String? = nil, assignedUser: String? = nil) {
        self.serialNumber = serialNumber
        self.productKey = productKey
        self.hardwareHash = hardwareHash
        self.groupTag = groupTag
        self.assignedUser = assignedUser
    }

    /// With a group tag set, every entry gets it; otherwise each keeps its own.
    public func withGroupTag(_ tag: String?) -> AutopilotHashEntry {
        guard let tag, !tag.isEmpty else { return self }
        return AutopilotHashEntry(serialNumber: serialNumber, productKey: productKey,
                                  hardwareHash: hardwareHash, groupTag: tag, assignedUser: assignedUser)
    }
}

public struct AutopilotHashCSV: Sendable {
    public struct Issue: Hashable, Sendable {
        /// 1-based line in the file.
        public let line: Int
        public let message: String
    }

    public let entries: [AutopilotHashEntry]
    public let issues: [Issue]

    /// Intune accepts at most this many devices in one import.
    public static let maxEntries = 500

    public enum ParseError: Error, LocalizedError, Equatable {
        case unreadable
        case missingColumns([String])
        case empty

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The file is not readable text."
            case .missingColumns(let columns): "The file has no \(columns.joined(separator: " or ")) column."
            case .empty: "The file lists no devices."
            }
        }
    }

    /// Decode as UTF-8 or UTF-16 (PowerShell's default for `Out-File`), with or without a BOM.
    public static func parse(data: Data) throws -> AutopilotHashCSV {
        let bytes = [UInt8](data.prefix(2))
        let text: String?
        if bytes == [0xFF, 0xFE] {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if bytes == [0xFE, 0xFF] {
            text = String(data: data, encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { throw ParseError.unreadable }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> AutopilotHashCSV {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ParseError.empty
        }
        let header = fields(lines[headerIndex]).map { $0.lowercased() }
        func column(_ names: String...) -> Int? { header.firstIndex { names.contains($0) } }

        guard let serialCol = column("device serial number", "serial number", "serialnumber") else {
            throw ParseError.missingColumns(["Device Serial Number"])
        }
        guard let hashCol = column("hardware hash", "hardwarehash", "hardware identifier") else {
            throw ParseError.missingColumns(["Hardware Hash"])
        }
        let productCol = column("windows product id", "product id", "productkey")
        let tagCol = column("group tag", "grouptag", "order id")
        let userCol = column("assigned user", "assigneduser", "assigned user principal name")

        var entries: [AutopilotHashEntry] = []
        var issues: [Issue] = []
        var seen: Set<String> = []
        for (offset, line) in lines.enumerated() where offset > headerIndex {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lineNumber = offset + 1
            let row = fields(line)
            func value(_ col: Int?) -> String? {
                guard let col, col < row.count else { return nil }
                let v = row[col].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let serial = value(serialCol) else {
                issues.append(Issue(line: lineNumber, message: "No serial number."))
                continue
            }
            guard let hash = value(hashCol) else {
                issues.append(Issue(line: lineNumber, message: "\(serial): no hardware hash."))
                continue
            }
            guard Data(base64Encoded: hash) != nil else {
                issues.append(Issue(line: lineNumber, message: "\(serial): the hardware hash is not valid base64."))
                continue
            }
            let key = AutopilotJoin.normalize(serial)
            guard seen.insert(key).inserted else {
                issues.append(Issue(line: lineNumber, message: "\(serial): listed more than once; the first row is used."))
                continue
            }
            entries.append(AutopilotHashEntry(serialNumber: serial, productKey: value(productCol),
                                              hardwareHash: hash, groupTag: value(tagCol), assignedUser: value(userCol)))
        }
        guard !entries.isEmpty || !issues.isEmpty else { throw ParseError.empty }
        if entries.count > maxEntries {
            issues.append(Issue(line: 0, message: "Intune imports at most \(maxEntries) devices at once; split the file."))
        }
        return AutopilotHashCSV(entries: entries, issues: issues)
    }

    /// Split one CSV line, honouring double-quoted fields and doubled quotes.
    static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                out.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current)
        return out
    }
}

/// An imported hash's progress, as Intune reports it.
public struct ImportedAutopilotIdentity: Codable, Sendable, Identifiable {
    public struct State: Codable, Sendable {
        /// `unknown`, `pending`, `partial`, `complete` or `error`.
        public let deviceImportStatus: String?
        public let deviceRegistrationId: String?
        public let deviceErrorCode: Int?
        public let deviceErrorName: String?
    }

    public let id: String
    public let serialNumber: String?
    public let groupTag: String?
    public let state: State?

    public var isFinished: Bool {
        let s = state?.deviceImportStatus?.lowercased()
        return s == "complete" || s == "error"
    }

    public var succeeded: Bool { state?.deviceImportStatus?.lowercased() == "complete" }

    /// Intune's error name, or its code when it gives no name.
    public var failureReason: String? {
        guard state?.deviceImportStatus?.lowercased() == "error" else { return nil }
        if let name = state?.deviceErrorName, !name.isEmpty { return name }
        return state?.deviceErrorCode.map { "error \($0)" } ?? "error"
    }
}

public struct ImportedAutopilotIdentitiesResponse: Codable, Sendable {
    public let value: [ImportedAutopilotIdentity]
}
