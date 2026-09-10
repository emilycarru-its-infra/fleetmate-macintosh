import Foundation

/// Carries an operator's ScanLab state into FleetMate once: custom groups
/// and history from ScanLab's preferences, and the commands they added to
/// their ScanLab library. Nothing in ScanLab is changed or removed.
public struct ScanLabImport: Sendable {
    public static let preferencesDomain = "ca.ecuad.scanlab"
    public static let customGroupsKey = "customGroups"
    public static let historyKey = "commandHistory"

    public struct Report: Equatable, Sendable {
        public var groupsAdded = 0
        public var groupsSkipped = 0
        public var historyAdded = 0
        public var commandsAdded = 0
        public var categoriesAdded = 0
        public var libraryPath: String?

        public var isEmpty: Bool {
            groupsAdded == 0 && groupsSkipped == 0 && historyAdded == 0 && commandsAdded == 0 && categoriesAdded == 0
        }

        public var summary: String {
            var parts: [String] = []
            parts.append("\(groupsAdded) group\(groupsAdded == 1 ? "" : "s") added" + (groupsSkipped > 0 ? " (\(groupsSkipped) already present)" : ""))
            parts.append("\(historyAdded) history entr\(historyAdded == 1 ? "y" : "ies") added")
            parts.append("\(commandsAdded) command\(commandsAdded == 1 ? "" : "s") added" + (categoriesAdded > 0 ? " in \(categoriesAdded) new categor\(categoriesAdded == 1 ? "y" : "ies")" : ""))
            return parts.joined(separator: ", ")
        }
    }

    /// Where ScanLab's state is read from. Defaults to the real locations;
    /// tests point at a suite and a temp file.
    public var defaults: UserDefaults?
    public var scanLabLibraryPath: String
    public var store: ManageStateStore

    public init(defaults: UserDefaults? = UserDefaults(suiteName: ScanLabImport.preferencesDomain),
                scanLabLibraryPath: String? = nil,
                store: ManageStateStore = ManageStateStore()) {
        self.defaults = defaults
        self.scanLabLibraryPath = scanLabLibraryPath ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanLab", isDirectory: true)
            .appendingPathComponent("commands.yaml").path
        self.store = store
    }

    /// True when there is anything to import.
    public var hasSource: Bool {
        (defaults?.data(forKey: Self.customGroupsKey) != nil)
            || (defaults?.data(forKey: Self.historyKey) != nil)
            || FileManager.default.fileExists(atPath: scanLabLibraryPath)
    }

    /// Import everything, merging into what FleetMate already has.
    public func run() -> Report {
        var report = Report()
        importGroups(into: &report)
        importHistory(into: &report)
        importLibrary(into: &report)
        return report
    }

    // MARK: - Pieces

    /// ScanLab's group shape is FleetMate's without the optional serial.
    private struct ScanLabDevice: Decodable {
        var id: UUID
        var hostname: String
        var ip: String
    }

    private struct ScanLabGroup: Decodable {
        var id: UUID
        var name: String
        var devices: [ScanLabDevice]
    }

    private struct ScanLabHistoryEntry: Decodable {
        var id: UUID
        var label: String
        var command: String
        var date: Date
    }

    /// ScanLab used JSONEncoder's defaults: dates as seconds since 2001.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }()

    func importGroups(into report: inout Report) {
        guard let data = defaults?.data(forKey: Self.customGroupsKey),
              let groups = try? Self.decoder.decode([ScanLabGroup].self, from: data), !groups.isEmpty else { return }
        var existing = store.loadCustomGroups()
        let names = Set(existing.map { $0.name.lowercased() })
        for group in groups {
            if names.contains(group.name.lowercased()) {
                report.groupsSkipped += 1
                continue
            }
            let devices = group.devices.map { AdhocDevice(id: $0.id, hostname: $0.hostname, ip: $0.ip) }
            existing.append(CustomGroup(id: group.id, name: group.name, devices: devices))
            report.groupsAdded += 1
        }
        if report.groupsAdded > 0 { store.saveCustomGroups(existing) }
    }

    func importHistory(into report: inout Report) {
        guard let data = defaults?.data(forKey: Self.historyKey),
              let entries = try? Self.decoder.decode([ScanLabHistoryEntry].self, from: data), !entries.isEmpty else { return }
        var history = store.loadHistory()
        let known = Set(history.map { $0.command })
        let fresh = entries.filter { !known.contains($0.command) }
            .map { CommandHistoryEntry(id: $0.id, label: $0.label, command: $0.command, date: $0.date) }
        guard !fresh.isEmpty else { return }
        history = Array((history + fresh).sorted { $0.date > $1.date }.prefix(ManageStateStore.historyLimit))
        store.saveHistory(history)
        report.historyAdded = fresh.count
    }

    /// Commands the operator added to ScanLab's library that the bundled
    /// library does not have, merged into FleetMate's per-user library.
    func importLibrary(into report: inout Report) {
        guard FileManager.default.fileExists(atPath: scanLabLibraryPath),
              let theirs = try? CommandLibrary.load(path: scanLabLibraryPath), !theirs.isEmpty else { return }
        let bundled = CommandLibrary.loadBundled()
        var additions: [CommandCategory] = []
        for category in theirs {
            let bundledCategory = bundled.first { CommandLibrary.normalize($0.name) == CommandLibrary.normalize(category.name) }
            let bundledLabels = Set((bundledCategory?.commands ?? []).map { CommandLibrary.normalize($0.label) })
            let extra = category.commands.filter { !bundledLabels.contains(CommandLibrary.normalize($0.label)) }
            if !extra.isEmpty { additions.append(CommandCategory(name: category.name, commands: extra)) }
        }
        guard !additions.isEmpty else { return }

        var mine = store.loadCommandLibrary().categories
        let categoriesBefore = Set(mine.map { CommandLibrary.normalize($0.name) })
        let commandsBefore = mine.reduce(0) { $0 + $1.commands.count }
        guard CommandLibrary.mergeMissing(into: &mine, bundled: additions) else { return }
        try? CommandLibrary.save(mine, to: store.commandsPath)
        report.commandsAdded = mine.reduce(0) { $0 + $1.commands.count } - commandsBefore
        report.categoriesAdded = mine.filter { !categoriesBefore.contains(CommandLibrary.normalize($0.name)) }.count
        report.libraryPath = store.commandsPath
    }
}
