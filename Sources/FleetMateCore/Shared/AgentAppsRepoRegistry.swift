import Foundation

/// The rendered repository list an outside tool can hand the app: a JSON file
/// at `<config>/agent-apps/repos/<bundle id>.json`, where `<config>` is
/// `$XDG_CONFIG_HOME` or `~/.config`. Schema 1 lists named sections, each with
/// its repositories in order. Its order, flattened (section order, then each
/// section's own), is the app's default repository order; when the file is
/// missing or unreadable the app keeps its built-in list.
public struct AgentAppsRepoRegistry: Equatable, Sendable {
    public struct Repo: Equatable, Sendable {
        public var path: String
        public var name: String?
        /// Whether the repository is offered to agent sessions; true unless
        /// the file says otherwise.
        public var agents: Bool
        /// The machine its lanes run on, when the file names one.
        public var host: String?
        /// `repo`, or `folder` for a lane on a directory that is not a repository.
        public var kind: String?
        /// Whether another app lists the same repository, so a session in it
        /// can be seen in more than one app; false unless the file says so.
        public var shared: Bool

        public init(path: String, name: String? = nil, agents: Bool = true, host: String? = nil, kind: String? = nil,
                    shared: Bool = false) {
            self.shared = shared
            self.path = path
            self.name = name
            self.agents = agents
            self.host = host
            self.kind = kind
        }
    }

    public struct Section: Equatable, Sendable {
        public var name: String
        public var repos: [Repo]

        public init(name: String, repos: [Repo]) {
            self.name = name
            self.repos = repos
        }
    }

    public static let schemaVersion = 1

    public var sections: [Section]
    /// The file's `app.zone`: whose work the listed repositories are.
    public var zone: String?

    public init(sections: [Section], zone: String? = nil) {
        self.sections = sections
        self.zone = zone
    }

    /// Every folder in order, each once: sections in order, then the
    /// repositories within each.
    public var orderedPaths: [String] { Self.unique(sections.flatMap(\.repos).map(\.path)) }

    /// The folders offered to agent sessions, in the same order.
    public var agentPaths: [String] { Self.unique(sections.flatMap(\.repos).filter(\.agents).map(\.path)) }

    /// The section each folder is listed under, by folder as written.
    public var sectionByPath: [String: String] {
        var result: [String: String] = [:]
        for section in sections {
            for repo in section.repos where result[repo.path] == nil { result[repo.path] = section.name }
        }
        return result
    }

    // MARK: Reading

    /// The file for `bundleIdentifier`, under `$XDG_CONFIG_HOME` or `~/.config`.
    /// The registry decides which folders agents may work in, so
    /// `$XDG_CONFIG_HOME` counts only when it is an absolute path that
    /// canonicalizes cleanly and both it and the registry file are owned by
    /// this user and not writable by group or others. Set but failing any of
    /// that, there is no registry (nil), never a fall back to `~/.config`.
    public static func defaultPath(bundleIdentifier: String,
                                   environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = NSHomeDirectory()) -> String? {
        let relative = "agent-apps/repos/" + bundleIdentifier + ".json"
        let fallback = ((home as NSString).appendingPathComponent(".config") as NSString).appendingPathComponent(relative)
        let configured = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if configured.isEmpty { return fallback }
        guard configured.hasPrefix("/"),
              let canonical = try? URL(fileURLWithPath: configured, isDirectory: true)
                  .resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
              isPrivate(canonical) else { return nil }
        let file = (canonical as NSString).appendingPathComponent(relative)
        return isPrivate(file) ? file : nil
    }

    /// Owned by this user, and neither group- nor world-writable.
    static func isPrivate(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        return owner == getuid() && mode & 0o022 == 0
    }

    /// The running app's file, or nil when the bundle has no identifier.
    public static var currentPath: String? {
        Bundle.main.bundleIdentifier.flatMap { defaultPath(bundleIdentifier: $0) }
    }

    /// The running app's registry, or nil when there is none to read.
    public static func loadCurrent() -> AgentAppsRepoRegistry? {
        guard let path = currentPath, let data = FileManager.default.contents(atPath: path) else { return nil }
        return decode(data)
    }

    /// Nil for a file of another schema, or one that lists no repositories.
    public static func decode(_ data: Data) -> AgentAppsRepoRegistry? {
        struct Surfaces: Decodable { var agents: Bool? }
        struct RawRepo: Decodable { var path: String?; var name: String?; var surfaces: Surfaces?; var host: String?; var kind: String?; var shared: Bool? }
        struct RawSection: Decodable { var name: String?; var repos: [RawRepo]? }
        struct RawApp: Decodable { var zone: String? }
        struct RawFile: Decodable {
            var schema_version: Int?
            var app: RawApp?
            var sections: [RawSection]?
        }
        guard let raw = try? JSONDecoder().decode(RawFile.self, from: data),
              raw.schema_version == schemaVersion else { return nil }
        let sections: [Section] = (raw.sections ?? []).map { section in
            Section(name: section.name ?? "", repos: (section.repos ?? []).compactMap { repo in
                guard let path = repo.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
                return Repo(path: path, name: repo.name, agents: repo.surfaces?.agents ?? true, host: repo.host, kind: repo.kind,
                            shared: repo.shared ?? false)
            })
        }
        let registry = AgentAppsRepoRegistry(sections: sections, zone: raw.app?.zone)
        return registry.orderedPaths.isEmpty ? nil : registry
    }

    /// Whether `directory` is in a repository the file marks `shared`: the
    /// repository's folder, or a worktree under its `.worktrees` or
    /// `.claude/worktrees` folder. False for a folder the file does not list.
    public func isShared(directory: String?) -> Bool {
        guard let directory, !directory.isEmpty else { return false }
        let folder = AgentRepoList.normalized(directory)
        return sections.flatMap(\.repos).contains { repo in
            guard repo.shared else { return false }
            let root = AgentRepoList.normalized(repo.path)
            return folder == root || folder.hasPrefix(root + "/.worktrees/") || folder.hasPrefix(root + "/.claude/worktrees/")
        }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(AgentRepoList.normalized($0)).inserted }
    }
}

/// When the files that decide the app's repositories last changed, so a
/// running app notices that an outside tool rewrote one of them.
public struct RegistryStamp: Equatable, Sendable {
    private var dates: [Date?]

    /// The modification date of each file, in order; nil for one that is missing.
    public init(files: [String?]) {
        dates = files.map { path in
            path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        }
    }
}

/// A rank for each repository in the one repository order, so lists keyed by
/// folder or by `Project/Repo` can follow it.
public struct RepositoryOrderRank: Equatable, Sendable {
    private var byPath: [String: Int]
    private var byName: [String: Int]

    public static let empty = RepositoryOrderRank(byPath: [:], byName: [:])

    /// `orderedPaths` is the repository order; `names` gives each folder's
    /// `Project/Repo` or `owner/repo` where it is known.
    public init(orderedPaths: [String], names: [String: String] = [:]) {
        var byPath: [String: Int] = [:]
        for (index, path) in orderedPaths.enumerated() where byPath[Self.key(path)] == nil {
            byPath[Self.key(path)] = index
        }
        var byName: [String: Int] = [:]
        for (path, name) in names {
            guard let rank = byPath[Self.key(path)] else { continue }
            let key = name.lowercased()
            byName[key] = Swift.min(byName[key] ?? rank, rank)
        }
        self.byPath = byPath
        self.byName = byName
    }

    private init(byPath: [String: Int], byName: [String: Int]) {
        self.byPath = byPath
        self.byName = byName
    }

    public var isEmpty: Bool { byPath.isEmpty }

    public func rank(path: String) -> Int? { byPath[Self.key(path)] }

    public func rank(name: String) -> Int? { byName[name.lowercased()] }

    /// `items` in the order, those it does not know after the rest in the
    /// order they came.
    public func sorted<T>(_ items: [T], by rank: (T) -> Int?) -> [T] {
        items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element) ?? Int.max, rank(b.element) ?? Int.max)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    static func key(_ path: String) -> String {
        let normalized = AgentRepoList.normalized(path)
        return (normalized.hasSuffix("/") && normalized.count > 1 ? String(normalized.dropLast()) : normalized).lowercased()
    }
}
