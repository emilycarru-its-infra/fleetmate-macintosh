import Foundation

/// Settings for finding and cloning repositories. Stored in the registry file
/// so the CLI and the app read and write the same values.
public struct RepoSettings: Codable, Sendable, Equatable {
    /// Folders `discover` scans for git checkouts. `~` is expanded.
    public var scanRoots: [String]
    /// How many folder levels below each root to look.
    public var scanDepth: Int
    /// Folder names never descended into. Hidden folders are always skipped.
    public var skipDirectories: [String]
    /// Root of the default clone layout:
    /// `<root>/AzDevOps/<Project>/<Repo>` and `<root>/GitHub/<owner>/<repo>`.
    public var cloneRoot: String
    /// GitHub owners listed in the catalog beyond the ones the signed-in user
    /// belongs to.
    public var gitHubOwners: [String]
    /// Branches `commit` and `push` refuse without `allowMain`. A repository's
    /// own default branch is always included.
    public var protectedBranches: [String]
    /// Upper bound on git processes a batch command runs at once.
    public var concurrency: Int

    public static let `default` = RepoSettings(
        scanRoots: ["~/Developer"],
        scanDepth: 4,
        skipDirectories: [".worktrees", "node_modules", ".build", "build", "DerivedData", "Pods", "vendor"],
        cloneRoot: "~/Developer",
        gitHubOwners: [],
        protectedBranches: ["main", "master"],
        concurrency: 6
    )

    public init(scanRoots: [String], scanDepth: Int, skipDirectories: [String], cloneRoot: String, gitHubOwners: [String], protectedBranches: [String], concurrency: Int) {
        self.scanRoots = scanRoots
        self.scanDepth = scanDepth
        self.skipDirectories = skipDirectories
        self.cloneRoot = cloneRoot
        self.gitHubOwners = gitHubOwners
        self.protectedBranches = protectedBranches
        self.concurrency = concurrency
    }

    /// Missing keys fall back to the defaults, so an older or hand-edited file
    /// keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RepoSettings.default
        scanRoots = try c.decodeIfPresent([String].self, forKey: .scanRoots) ?? d.scanRoots
        scanDepth = try c.decodeIfPresent(Int.self, forKey: .scanDepth) ?? d.scanDepth
        skipDirectories = try c.decodeIfPresent([String].self, forKey: .skipDirectories) ?? d.skipDirectories
        cloneRoot = try c.decodeIfPresent(String.self, forKey: .cloneRoot) ?? d.cloneRoot
        gitHubOwners = try c.decodeIfPresent([String].self, forKey: .gitHubOwners) ?? d.gitHubOwners
        protectedBranches = try c.decodeIfPresent([String].self, forKey: .protectedBranches) ?? d.protectedBranches
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? d.concurrency
    }

    public static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

/// One local checkout FleetMate knows about.
public struct RepoRegistryEntry: Codable, Sendable, Equatable {
    public var key: RepoKey
    /// Absolute path of the checkout.
    public var path: String
    /// A tracked repository is one of the team's core repositories: batch
    /// commands act on tracked repositories by default.
    public var tracked: Bool
    public var remoteUrl: String?
    public var defaultBranch: String?
    public var addedAt: Date

    public init(key: RepoKey, path: String, tracked: Bool, remoteUrl: String? = nil, defaultBranch: String? = nil, addedAt: Date = Date()) {
        self.key = key
        self.path = path
        self.tracked = tracked
        self.remoteUrl = remoteUrl
        self.defaultBranch = defaultBranch
        self.addedAt = addedAt
    }
}

/// The on-disk registry document.
///
/// ```json
/// {
///   "version": 1,
///   "settings": { "scanRoots": ["~/Developer"], "cloneRoot": "~/Developer", ... },
///   "repos": {
///     "github:example-org/example-repo": {
///       "key": { "provider": "github", "owner": "example-org", "name": "example-repo" },
///       "path": "/Users/me/Developer/GitHub/example-org/example-repo",
///       "tracked": true, "remoteUrl": "...", "defaultBranch": "main", "addedAt": "..."
///     }
///   }
/// }
/// ```
public struct RepoRegistryDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var settings: RepoSettings
    /// Registry id (`RepoKey.id`) → entry.
    public var repos: [String: RepoRegistryEntry]

    public init(version: Int = 1, settings: RepoSettings = .default, repos: [String: RepoRegistryEntry] = [:]) {
        self.version = version
        self.settings = settings
        self.repos = repos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try c.decodeIfPresent(RepoSettings.self, forKey: .settings) ?? .default
        repos = try c.decodeIfPresent([String: RepoRegistryEntry].self, forKey: .repos) ?? [:]
    }

    public var entries: [RepoRegistryEntry] { repos.values.sorted { $0.key < $1.key } }
    public var trackedEntries: [RepoRegistryEntry] { entries.filter(\.tracked) }
}

/// Reads and writes the shared registry (`repos.json`) and catalog cache
/// (`repos-catalog.json`) in FleetMate's support folder. Plain JSON files, so
/// the CLI and the app see each other's changes; no Keychain.
///
/// Every mutation is a load-modify-save of the whole file with an atomic
/// write, which keeps the window for two writers racing to milliseconds.
public struct RepoRegistryStore: Sendable {
    public let registryPath: String
    public let catalogPath: String

    public static var defaultRegistryPath: String { AppEdition.current.supportPath("repos.json") }
    public static var defaultCatalogPath: String { AppEdition.current.supportPath("repos-catalog.json") }

    public init(registryPath: String = RepoRegistryStore.defaultRegistryPath,
                catalogPath: String = RepoRegistryStore.defaultCatalogPath) {
        self.registryPath = registryPath
        self.catalogPath = catalogPath
    }

    // MARK: Registry

    public func load() throws -> RepoRegistryDocument {
        guard FileManager.default.fileExists(atPath: registryPath) else { return RepoRegistryDocument() }
        let data = try Data(contentsOf: URL(fileURLWithPath: registryPath))
        return try Self.decoder.decode(RepoRegistryDocument.self, from: data)
    }

    public func save(_ document: RepoRegistryDocument) throws {
        try write(Self.encoder.encode(document), to: registryPath)
    }

    /// Applies `change` to the current document and saves it.
    @discardableResult
    public func update<T>(_ change: (inout RepoRegistryDocument) throws -> T) throws -> T {
        var document = try load()
        let result = try change(&document)
        try save(document)
        return result
    }

    // MARK: Catalog cache

    public func loadCatalog() -> RepoCatalog? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: catalogPath)) else { return nil }
        return try? Self.decoder.decode(RepoCatalog.self, from: data)
    }

    public func saveCatalog(_ catalog: RepoCatalog) throws {
        try write(Self.encoder.encode(catalog), to: catalogPath)
    }

    // MARK: Private

    private func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
