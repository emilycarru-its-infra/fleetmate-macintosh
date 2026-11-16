import Foundation

/// The icon and colour a person chose for one repository.
public struct RepoIconChoice: Codable, Sendable, Equatable {
    /// The icon in its stored string form, such as `sf:hammer` or `svg:rocket`.
    public var icon: String
    /// The colour as `#RRGGBB`; nil draws the icon in the accent colour.
    public var tint: String?

    public init(icon: String, tint: String? = nil) {
        self.icon = icon
        self.tint = tint
    }
}

/// Per-repository icons and colours, kept in a small file of FleetMate's own
/// beside the repository registry, so the registry file the command-line tool
/// reads keeps its format. Keyed by `RepoKey.id`, which stays the same when a
/// clone moves on disk.
public struct RepoIconStore: Sendable {
    public let path: String

    public static var defaultPath: String { AppEdition.current.supportPath("repo-icons.json") }

    public init(path: String = RepoIconStore.defaultPath) {
        self.path = path
    }

    /// Every saved choice. A missing or unreadable file is no choices.
    public func load() -> [String: RepoIconChoice] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let choices = try? JSONDecoder().decode([String: RepoIconChoice].self, from: data) else { return [:] }
        return choices
    }

    public func save(_ choices: [String: RepoIconChoice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(choices).write(to: url, options: .atomic)
    }

    /// Records a choice for a repository, or removes it when `choice` is nil.
    /// Returns the choices as they are afterwards.
    @discardableResult
    public func set(_ choice: RepoIconChoice?, for repoId: String) throws -> [String: RepoIconChoice] {
        var choices = load()
        if let choice { choices[repoId] = choice } else { choices.removeValue(forKey: repoId) }
        try save(choices)
        return choices
    }
}
