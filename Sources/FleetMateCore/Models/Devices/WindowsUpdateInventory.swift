import Foundation

/// How many Windows devices report each OS build, as `fleetmate intune
/// updates` summarises it. Shared with FleetMate for Windows, so the counts
/// and the build normalisation match between the two.
public struct WindowsBuildCount: Codable, Sendable, Equatable {
    public let build: String
    public let count: Int
    public let percentage: Double
}

public struct WindowsUpdateDevice: Codable, Sendable, Equatable {
    public let deviceName: String
    public let serialNumber: String?
    public let build: String
    public let osVersion: String
    public let lastSyncDateTime: Date
}

public struct WindowsUpdateInventory: Codable, Sendable {
    public let since: Date
    public let totalDevices: Int
    public let matchingDevices: Int
    public let coveragePercentage: Double
    public let selectedBuilds: [String]
    public let builds: [WindowsBuildCount]
    public let devices: [WindowsUpdateDevice]

    /// Windows devices that synced since `since`, grouped by build. With
    /// `selectedBuilds`, `devices` and the coverage count only those builds.
    public static func build(from devices: [IntuneDevice], since: Date, selectedBuilds: [String] = []) -> WindowsUpdateInventory {
        let selected = Array(Set(selectedBuilds.map(normalizeBuild).filter { !$0.isEmpty }.map { $0.lowercased() })).sorted()
        let selectedSet = Set(selected)

        let current: [WindowsUpdateDevice] = devices.compactMap { device in
            guard device.operatingSystem?.caseInsensitiveCompare("Windows") == .orderedSame,
                  let synced = parseDate(device.lastSyncDateTime), synced >= since else { return nil }
            let build = normalizeBuild(device.osVersion)
            guard !build.isEmpty else { return nil }
            return WindowsUpdateDevice(deviceName: device.deviceName ?? "", serialNumber: device.serialNumber,
                                       build: build, osVersion: device.osVersion ?? "", lastSyncDateTime: synced)
        }
        .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }

        let matching = selected.isEmpty ? current : current.filter { selectedSet.contains($0.build.lowercased()) }
        let groups = Dictionary(grouping: current) { $0.build.lowercased() }
        let summaries = groups.map { _, members in
            WindowsBuildCount(build: members[0].build, count: members.count, percentage: percentage(members.count, current.count))
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.build < $1.build }

        return WindowsUpdateInventory(since: since, totalDevices: current.count, matchingDevices: matching.count,
                                      coveragePercentage: percentage(matching.count, current.count),
                                      selectedBuilds: selected, builds: summaries, devices: matching)
    }

    /// `10.0.26100.9457` → `26100.9457`; anything shorter is kept as it is.
    public static func normalizeBuild(_ osVersion: String?) -> String {
        let value = (osVersion ?? "").trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count >= 4 ? parts.suffix(2).joined(separator: ".") : value
    }

    private static func percentage(_ count: Int, _ total: Int) -> Double {
        total == 0 ? 0 : (Double(count) * 1000 / Double(total)).rounded() / 10
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
