import Foundation

/// Persists the Manage tab's operator state as JSON files under one folder:
/// command history and custom groups, plus the per-user command library.
/// Default root is `~/Library/Application Support/FleetMate/manage`; tests
/// pass a temp folder. No secrets live here; the Screen Sharing credential
/// is in Keychain.
public struct ManageStateStore: Sendable {
    public static let historyLimit = 50

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate", isDirectory: true)
            .appendingPathComponent("manage", isDirectory: true)
    }

    public var historyURL: URL { root.appendingPathComponent("history.json") }
    public var customGroupsURL: URL { root.appendingPathComponent("custom-groups.json") }
    public var commandsURL: URL { root.appendingPathComponent("commands.yaml") }
    public var commandsPath: String { commandsURL.path }

    // MARK: - History

    public func loadHistory() -> [CommandHistoryEntry] {
        load([CommandHistoryEntry].self, from: historyURL) ?? []
    }

    public func saveHistory(_ entries: [CommandHistoryEntry]) {
        save(Array(entries.prefix(Self.historyLimit)), to: historyURL)
    }

    /// Insert at the front, trim to the limit, save, and return the new list.
    public func addHistory(_ history: [CommandHistoryEntry], label: String, command: String) -> [CommandHistoryEntry] {
        var updated = history
        updated.insert(CommandHistoryEntry(label: label, command: command), at: 0)
        if updated.count > Self.historyLimit { updated.removeLast(updated.count - Self.historyLimit) }
        saveHistory(updated)
        return updated
    }

    public func clearHistory() {
        try? FileManager.default.removeItem(at: historyURL)
    }

    // MARK: - Custom groups

    public func loadCustomGroups() -> [CustomGroup] {
        load([CustomGroup].self, from: customGroupsURL) ?? []
    }

    public func saveCustomGroups(_ groups: [CustomGroup]) {
        save(groups, to: customGroupsURL)
    }

    // MARK: - Command library

    /// The operator's library: seeded from the bundled one on first use, and
    /// topped up with bundled additions afterwards. Returns the categories
    /// and whether the file on disk changed.
    @discardableResult
    public func loadCommandLibrary(path: String? = nil) -> (categories: [CommandCategory], changed: Bool) {
        let target = path.map { NSString(string: $0).expandingTildeInPath } ?? commandsPath
        let usesDefault = URL(fileURLWithPath: target).standardizedFileURL == commandsURL.standardizedFileURL
        let bundled = CommandLibrary.loadBundled()

        guard FileManager.default.fileExists(atPath: target) else {
            try? CommandLibrary.save(bundled, to: target)
            return (bundled, true)
        }

        var categories: [CommandCategory]
        do {
            categories = try CommandLibrary.load(path: target)
        } catch {
            dbg.warn("Could not parse command library at \(target): \(error.localizedDescription)", category: "manage")
            return (bundled, false)
        }
        guard usesDefault else { return (categories, false) }

        if CommandLibrary.mergeMissing(into: &categories, bundled: bundled) {
            try? CommandLibrary.save(categories, to: target)
            return (categories, true)
        }
        return (categories, false)
    }

    // MARK: - JSON

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            dbg.warn("Could not read \(url.lastPathComponent); starting empty: \(error.localizedDescription)", category: "manage")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            dbg.warn("Could not write \(url.lastPathComponent): \(error.localizedDescription)", category: "manage")
        }
    }
}
