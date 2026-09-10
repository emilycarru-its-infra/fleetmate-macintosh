import Foundation

/// Reads the enrollment roster (computers.csv) by header and splits it into
/// sidebar sections.
///
/// Two roster shapes exist. The current one has twelve columns ending in
/// `hostname`, with `allocation` holding the friendly name (the person, or a
/// label for shared machines). The older one has eleven columns and the
/// hostname lives in `allocation`. Reading by header handles both: the
/// `hostname` column wins when present and non-empty, `allocation` is the
/// fallback.
public struct RosterLoader: Sendable {
    /// Show rows whose status is not an Active variant.
    public var includeRetired: Bool
    /// Show the Provisioning catalog (machines not yet assigned) as a lab section.
    public var includeProvisioning: Bool

    public init(includeRetired: Bool = false, includeProvisioning: Bool = false) {
        self.includeRetired = includeRetired
        self.includeProvisioning = includeProvisioning
    }

    public enum RosterError: Error, LocalizedError {
        case unreadable(String)
        case missingHeader(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Could not read roster at \(path)"
            case .missingHeader(let name): "Roster is missing the \(name) column"
            }
        }
    }

    public func load(path: String) throws -> FleetRoster {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw RosterError.unreadable(expanded)
        }
        return try load(csv: content)
    }

    public func load(csv: String) throws -> FleetRoster {
        let rows = try Self.parseRows(csv)
        return group(rows)
    }

    /// Every row of the CSV as a RosterComputer, regardless of status. The
    /// sections apply the filters; this is for lookups by serial.
    public static func parseRows(_ csv: String) throws -> [RosterComputer] {
        var records = CSVReader.records(csv)
        guard !records.isEmpty else { return [] }
        let header = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func index(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let serialIndex = index("serial") else { throw RosterError.missingHeader("serial") }
        guard let allocationIndex = index("allocation") else { throw RosterError.missingHeader("allocation") }
        let hostnameIndex = index("hostname")

        func field(_ record: [String], _ i: Int?) -> String {
            guard let i, i < record.count else { return "" }
            return record[i].trimmingCharacters(in: .whitespaces)
        }

        var computers: [RosterComputer] = []
        for record in records {
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            let allocation = field(record, allocationIndex)
            let explicitHostname = field(record, hostnameIndex)
            let hostname: String
            if hostnameIndex != nil {
                // New shape: the column is authoritative even when empty.
                hostname = explicitHostname
            } else {
                // Old shape: allocation is the hostname.
                hostname = allocation
            }
            computers.append(RosterComputer(
                serial: field(record, serialIndex),
                catalog: field(record, index("catalog")),
                area: field(record, index("area")),
                location: field(record, index("location")),
                asset: field(record, index("asset")),
                usage: field(record, index("usage")),
                status: field(record, index("status")),
                allocation: allocation,
                username: field(record, index("username")),
                platform: field(record, index("platform")),
                fleet: field(record, index("fleet")),
                hostname: hostname
            ))
        }
        return computers
    }

    func group(_ rows: [RosterComputer]) -> FleetRoster {
        var labs: [RosterComputer] = []
        var kiosks: [RosterComputer] = []
        var staff: [RosterComputer] = []
        var faculty: [RosterComputer] = []
        var source: [RosterComputer] = []

        for c in rows {
            guard includeRetired || c.isInService else { continue }
            guard !c.serial.isEmpty || c.hasHostname else { continue }
            if c.hasHostname { source.append(c) }

            let catalog = c.catalog.lowercased()
            let usage = c.usage.lowercased()
            if catalog == "curriculum", usage == "shared", c.area.lowercased() != "podium" {
                labs.append(c)
            } else if catalog == "kiosk" {
                kiosks.append(c)
            } else if catalog == "staff", usage == "assigned" {
                staff.append(c)
            } else if catalog == "faculty", usage == "assigned" {
                faculty.append(c)
            } else if includeProvisioning, catalog == "provisioning" {
                labs.append(c)
            }
        }

        return FleetRoster(
            labs: Self.groupLabs(labs),
            kiosks: Self.groupByLocation(kiosks),
            staff: Self.groupBy(staff) { $0.area.isEmpty ? "Other" : $0.area },
            faculty: Self.groupBy(faculty) { Self.firstLetter($0.allocation.isEmpty ? $0.displayName : $0.allocation) },
            sourceComputers: source.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        )
    }

    /// Labs group by the `fleet` column (the real lab grouping) with the room
    /// number as fallback for rows that have none. Display name is the most
    /// common area in the group. Largest labs first, then by name.
    static func groupLabs(_ computers: [RosterComputer]) -> [RosterRoom] {
        var map: [String: [RosterComputer]] = [:]
        for c in computers {
            let key = c.fleet.isEmpty ? (c.location.isEmpty ? "Unassigned" : c.location) : c.fleet
            map[key, default: []].append(c)
        }
        return map
            .map { key, members in
                RosterRoom(
                    number: key,
                    displayName: dominantArea(members),
                    computers: members.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                )
            }
            .sorted {
                if $0.computers.count != $1.computers.count { return $0.computers.count > $1.computers.count }
                return $0.number.localizedCaseInsensitiveCompare($1.number) == .orderedAscending
            }
    }

    static func groupByLocation(_ computers: [RosterComputer]) -> [RosterRoom] {
        groupBy(computers) { $0.location.isEmpty ? "Other" : $0.location }
    }

    static func groupBy(_ computers: [RosterComputer], key: (RosterComputer) -> String) -> [RosterRoom] {
        var map: [String: [RosterComputer]] = [:]
        for c in computers { map[key(c), default: []].append(c) }
        return map
            .map { key, members in
                RosterRoom(
                    number: key,
                    computers: members.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                )
            }
            .sorted { $0.number.localizedCaseInsensitiveCompare($1.number) == .orderedAscending }
    }

    static func dominantArea(_ computers: [RosterComputer]) -> String? {
        var counts: [String: Int] = [:]
        for c in computers {
            let area = c.area.trimmingCharacters(in: .whitespaces)
            guard !area.isEmpty else { continue }
            counts[area, default: 0] += 1
        }
        return counts.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key > $1.key
        }?.key
    }

    static func firstLetter(_ s: String) -> String {
        guard let first = s.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

/// A small RFC 4180 reader: quoted fields, doubled quotes inside quotes,
/// newlines inside quotes, CRLF or LF line endings. Works on unicode
/// scalars because Swift folds a CR LF pair into one Character, which
/// would otherwise match neither line ending.
public enum CSVReader {
    private static let quote: Unicode.Scalar = "\""
    private static let comma: Unicode.Scalar = ","
    private static let cr: Unicode.Scalar = "\r"
    private static let lf: Unicode.Scalar = "\n"

    public static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        func endField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
        }

        func endRecord() {
            endField()
            records.append(record)
            record = []
        }

        while let ch = next() {
            if inQuotes {
                if ch == quote {
                    if let peek = next() {
                        if peek == quote { field.append(quote) } else { inQuotes = false; pending = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case quote:
                inQuotes = true
            case comma:
                endField()
            case cr:
                if let peek = next(), peek != lf { pending = peek }
                endRecord()
            case lf:
                endRecord()
            default:
                field.append(ch)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            endRecord()
        }
        return records
    }
}
