import Foundation

/// One ReportMate device as global search sees it: the fields worth typing.
public struct ReportingDeviceRecord: Equatable, Sendable {
    public var serial: String
    public var name: String
    public var hostname: String?
    public var user: String?
    public var assetTag: String?
    public var platform: String?

    public init(serial: String, name: String, hostname: String? = nil, user: String? = nil,
                assetTag: String? = nil, platform: String? = nil) {
        self.serial = serial
        self.name = name
        self.hostname = hostname
        self.user = user
        self.assetTag = assetTag
        self.platform = platform
    }
}

/// Matches ReportMate devices for the global search, field by field, so a row
/// can say which field matched.
public enum ReportingDeviceSearch {
    public struct Hit: Equatable, Sendable {
        public let device: ReportingDeviceRecord
        public let field: String
        public let value: String
    }

    /// Case-insensitive substring matches in name, serial, asset tag, user and
    /// hostname order; an exact serial or asset tag sorts first.
    public static func search(_ query: String, in devices: [ReportingDeviceRecord], limit: Int) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, limit > 0 else { return [] }
        var exact: [Hit] = []
        var partial: [Hit] = []
        for device in devices {
            let fields: [(String, String?)] = [
                ("Name", device.name),
                ("Serial", device.serial),
                ("Asset tag", device.assetTag),
                ("User", device.user),
                ("Host", device.hostname),
            ]
            for (field, value) in fields {
                guard let value, !value.isEmpty, value.localizedCaseInsensitiveContains(q) else { continue }
                let hit = Hit(device: device, field: field, value: value)
                let isExactId = (field == "Serial" || field == "Asset tag")
                    && value.caseInsensitiveCompare(q) == .orderedSame
                if isExactId { exact.append(hit) } else { partial.append(hit) }
                break
            }
        }
        return Array((exact + partial).prefix(limit))
    }
}
