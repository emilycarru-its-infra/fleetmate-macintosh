import Foundation

// MARK: - Serial number lookup lists

/// Reads a list of serial numbers typed, pasted, or imported from a text or
/// CSV file. A CSV whose header names a serial column contributes that column
/// only; anything else is split on commas, semicolons, tabs and line breaks.
/// FleetMate for Windows reads lists the same way.
public enum SerialList {
    public static let maxSerials = 5000
    static let headerWords: Set<String> = ["serial", "serialnumber", "serial number", "serial_number", "serial no", "sn"]

    /// Distinct serials in first-seen order, normalized as the Devices join
    /// compares them.
    public static func parse(_ text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let tokens = serialColumn(lines) ?? text.components(separatedBy: CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines))

        var seen = Set<String>()
        var out: [String] = []
        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespaces)
            guard looksLikeSerial(token), !headerWords.contains(token.lowercased()) else { continue }
            let serial = AppleOrgJoin.normalize(token)
            if seen.insert(serial).inserted { out.append(serial) }
            if out.count == maxSerials { break }
        }
        return out
    }

    /// A letter or digit, then two to thirty-nine letters, digits or hyphens.
    static func looksLikeSerial(_ s: String) -> Bool {
        guard (3...40).contains(s.count), let first = s.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The serial column of a CSV whose first line names one; nil otherwise.
    static func serialColumn(_ lines: [String]) -> [String]? {
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let first = lines[firstIndex]
        let delimiter: Character = first.contains("\t") ? "\t" : (first.contains(";") && !first.contains(",")) ? ";" : ","
        let headers = splitCSVLine(first, delimiter: delimiter)
        guard headers.count >= 2 else { return nil }
        guard let index = headers.firstIndex(where: {
            let name = $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespaces).lowercased()
            return name.contains("serial") || name == "sn"
        }) else { return nil }
        return lines[(firstIndex + 1)...]
            .map { splitCSVLine($0, delimiter: delimiter) }
            .filter { $0.count > index }
            .map { $0[index] }
    }

    /// One CSV line's cells, honouring double-quoted cells that contain the
    /// delimiter.
    static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var cells: [String] = []
        var current = ""
        var quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if c == "\"" {
                if quoted, chars.first == "\"" { current.append("\""); chars = chars.dropFirst() }
                else { quoted.toggle() }
            } else if c == delimiter && !quoted {
                cells.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        cells.append(current)
        return cells
    }

    /// The rows a lookup list shows: each device whose serial is on the list,
    /// then a "Not Found" row for each listed serial that no system knows.
    public static func rows(for serials: [String], in rows: [DeviceListRow]) -> [DeviceListRow] {
        let wanted = Set(serials)
        var found = Set<String>()
        var out = rows.filter { row in
            guard let serial = row.serialNumber.map(AppleOrgJoin.normalize), wanted.contains(serial) else { return false }
            found.insert(serial)
            return true
        }
        for serial in serials where !found.contains(serial) {
            var row = DeviceListRow.unknown(serial: serial)
            row.discrepancies = [DeviceDiscrepancy.unknown]
            out.append(row)
        }
        return out
    }
}

// MARK: - Discrepancies between systems

/// Where the systems that know a device disagree about it. The labels and
/// rules match FleetMate for Windows.
public enum DeviceDiscrepancy {
    public static let none = "No Discrepancy"
    public static let orgNotEnrolled = "In Apple Organization, Not Enrolled"
    public static let autopilotNotEnrolled = "In Autopilot, Not Enrolled"
    public static let enrolledUnregistered = "Enrolled, Not in Apple Organization or Autopilot"
    public static let otherService = "Assigned to Another Service"
    public static let noService = "Not Assigned to a Service"
    public static let notInInventory = "Missing from Inventory"
    public static let unknown = "Unknown to Every System"

    /// What has been read, so each check speaks only once both systems it
    /// compares have loaded.
    public struct Sources: Sendable {
        public var autopilotRead: Bool
        public var appleOrgsRead: Bool
        /// Normalized serials in the asset inventory; nil or empty when it
        /// was not read.
        public var inventorySerials: Set<String>?

        public init(autopilotRead: Bool, appleOrgsRead: Bool, inventorySerials: Set<String>? = nil) {
            self.autopilotRead = autopilotRead
            self.appleOrgsRead = appleOrgsRead
            self.inventorySerials = inventorySerials
        }
    }

    /// The rows with their discrepancies filled in. The service enrolled Apple
    /// devices should be assigned to is the one most of them already are, so
    /// no service name is configured or assumed.
    public static func annotate(_ rows: [DeviceListRow], sources: Sources) -> [DeviceListRow] {
        let home = sources.appleOrgsRead ? homeService(rows) : nil
        return rows.map { row in
            var row = row
            row.discrepancies = labels(for: row, sources: sources, homeService: home)
            return row
        }
    }

    public static func homeService(_ rows: [DeviceListRow]) -> String? {
        var counts: [String: (name: String, count: Int)] = [:]
        for row in rows where row.isEnrolled && row.apple?.assignedServerId != nil {
            guard let name = row.serverName else { continue }
            counts[name.lowercased(), default: (name, 0)].count += 1
        }
        return counts.values.max { a, b in a.count == b.count ? a.name > b.name : a.count < b.count }?.name
    }

    public static func labels(for row: DeviceListRow, sources: Sources, homeService: String?) -> [String] {
        if row.isUnknown { return [unknown] }
        var found: [String] = []

        if row.apple != nil && !row.isEnrolled { found.append(orgNotEnrolled) }
        if row.autopilot != nil && !row.isEnrolled { found.append(autopilotNotEnrolled) }

        if row.isEnrolled && row.apple == nil && row.autopilot == nil {
            // Only platforms a provisioning system could hold, and only once
            // that system has been read.
            let isWindows = DevicePlatform(operatingSystem: row.platformLabel) == .windows
            if (sources.appleOrgsRead && row.isApplePlatform) || (sources.autopilotRead && isWindows) {
                found.append(enrolledUnregistered)
            }
        }

        if row.isEnrolled, let apple = row.apple {
            if apple.assignedServerId == nil {
                found.append(noService)
            } else if let home = homeService, row.serverName?.lowercased() != home.lowercased() {
                found.append(otherService)
            }
        }

        if let inventory = sources.inventorySerials, !inventory.isEmpty,
           let serial = row.serialNumber, !inventory.contains(AppleOrgJoin.normalize(serial)) {
            found.append(notInInventory)
        }
        return found
    }
}
