import Foundation

/// What `discover` did with one checkout it found.
public struct DiscoveryResult: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Newly registered.
        case linked
        /// Already registered at this path.
        case alreadyLinked
        /// The repository is registered at another path that still exists;
        /// this copy was left alone.
        case duplicate
        /// No origin remote, or one that could not be parsed.
        case noRemote
        /// Its config can run commands, so it was linked without being
        /// tracked; tracking it is the person's call.
        case needsReview
    }

    public let path: String
    public let id: String?
    public let displayName: String?
    public let inCatalog: Bool
    public let action: Action
    /// For `.duplicate`, the path already registered.
    public let registeredPath: String?
}

/// The one entry point for repository management, shared by `fleetmate repos`
/// and the app. It joins the provider catalog, the local registry and git:
///
/// ```swift
/// let manager = RepoManager()
/// let records = try manager.records()                     // catalog ∪ registry
/// let repo = try manager.resolve("Project/Repo")
/// let copy = try manager.workingCopy(for: repo)            // GitWorkingCopy
/// let status = await manager.status(for: repo)
/// ```
///
/// The catalog is read from the cache written by `refreshCatalog`, so
/// resolving a name needs no network.
public struct RepoManager: Sendable {
    public let store: RepoRegistryStore

    public init(store: RepoRegistryStore = RepoRegistryStore()) {
        self.store = store
    }

    // MARK: - Settings and registry

    public func settings() throws -> RepoSettings { try store.load().settings }

    public func updateSettings(_ change: (inout RepoSettings) -> Void) throws {
        try store.update { change(&$0.settings) }
    }

    public func registry() throws -> RepoRegistryDocument { try store.load() }

    // MARK: - Catalog

    public func cachedCatalog() -> RepoCatalog? { store.loadCatalog() }

    /// Fetches the catalog and caches it. Registered entries pick up the
    /// default branch the provider reports.
    @discardableResult
    public func refreshCatalog(using service: RepoCatalogService) async throws -> RepoCatalog {
        let catalog = await service.fetch()
        // Keep the previous cache when a fetch came back empty with errors:
        // a lapsed token should not wipe what resolution relies on.
        if !catalog.repos.isEmpty || catalog.errors.isEmpty {
            try store.saveCatalog(catalog)
            let byId = Dictionary(catalog.repos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            try store.update { doc in
                for (id, entry) in doc.repos {
                    if let branch = byId[id]?.defaultBranch, entry.defaultBranch != branch {
                        doc.repos[id]?.defaultBranch = branch
                    }
                }
            }
        }
        return catalog
    }

    /// Catalog and registry merged, one record per repository.
    public func records() throws -> [RepoRecord] {
        RepoRecord.merge(catalog: cachedCatalog()?.repos ?? [], registry: try store.load().entries)
    }

    public func resolve(_ argument: String) throws -> RepoRecord {
        try RepoResolver.resolve(argument, in: records())
    }

    /// Resolves each argument, or every tracked repository when there are none.
    public func resolveLocal(_ arguments: [String]) throws -> [RepoRecord] {
        if arguments.isEmpty {
            return try records().filter(\.isTracked)
        }
        return try arguments.map { argument in
            let record = try resolve(argument)
            guard record.isLocal else { throw RepoError.notLocal(record.key.displayName) }
            return record
        }
    }

    // MARK: - Linking

    /// Registers `path` as the checkout of the repository its origin names.
    /// When `argument` is given, the origin must match it.
    @discardableResult
    public func link(path rawPath: String, to argument: String? = nil, tracked: Bool = true) async throws -> RepoRegistryEntry {
        let path = URL(fileURLWithPath: RepoSettings.expand(rawPath)).standardizedFileURL.path
        let copy = GitWorkingCopy(path: path)
        guard await copy.isRepository else { throw RepoError.notAGitRepository(path) }
        let origin = await copy.originURL()
        let originKey = origin.flatMap(RepoRemoteURL.parse)

        let key: RepoKey
        let defaultBranch: String?
        if let argument {
            // The checkout's own origin is a candidate too, so a repository
            // missing from the catalog can still be linked by name.
            var candidates = try records()
            if let originKey, !candidates.contains(where: { $0.id == originKey.id }) {
                candidates.append(RepoRecord(key: originKey, catalog: nil, local: nil))
            }
            let record = try RepoResolver.resolve(argument, in: candidates)
            if let originKey, originKey.id != record.key.id {
                throw RepoError.invalidArgument("\(path) has origin \(originKey.displayName), not \(record.key.displayName).")
            }
            key = record.key
            defaultBranch = record.defaultBranch
        } else {
            guard let originKey else {
                throw RepoError.invalidArgument("\(path) has no origin remote; name the repository to link it to.")
            }
            key = originKey
            defaultBranch = cachedCatalog()?.repos.first { $0.id == originKey.id }?.defaultBranch
        }
        let entry = RepoRegistryEntry(key: key, path: path, tracked: tracked, remoteUrl: origin, defaultBranch: defaultBranch)
        try store.update { doc in
            var updated = entry
            if let existing = doc.repos[key.id] {
                updated.addedAt = existing.addedAt
                updated.tracked = tracked || existing.tracked
            }
            doc.repos[key.id] = updated
        }
        return entry
    }

    public func unlink(_ argument: String) throws {
        let record = try resolve(argument)
        try store.update { $0.repos[record.key.id] = nil }
    }

    public func setTracked(_ argument: String, _ tracked: Bool) throws -> RepoRecord {
        let record = try resolve(argument)
        guard record.isLocal else { throw RepoError.notLocal(record.key.displayName) }
        try store.update { $0.repos[record.key.id]?.tracked = tracked }
        return try resolve(record.key.id)
    }

    public func setHidden(_ argument: String, _ hidden: Bool) throws -> RepoRecord {
        let record = try resolve(argument)
        guard record.isLocal else { throw RepoError.notLocal(record.key.displayName) }
        try store.update { $0.repos[record.key.id]?.hidden = hidden }
        return try resolve(record.key.id)
    }

    /// Scans the configured roots and registers every checkout whose origin
    /// names a repository. Existing links are kept; a second copy of an
    /// already-linked repository is reported as a duplicate, not re-linked.
    ///
    /// `track` marks every checkout found as tracked, linked before or not.
    /// `trackNew` tracks only checkouts registered by this scan, leaving the
    /// person's earlier choice for the rest alone.
    public func discover(track: Bool = false, trackNew: Bool = false, settings override: RepoSettings? = nil) async throws -> [DiscoveryResult] {
        let settings = try override ?? self.settings()
        let found = await RepoDiscovery.discover(settings: settings)
        return try register(found, track: track, trackNew: trackNew)
    }

    /// Checkouts under `roots` without registering anything, for a preview
    /// the person picks from (onboarding). Includes the folders VS Code
    /// workspace files in those roots name, marked `fromWorkspace`.
    public func preview(roots: [String]) async throws -> [DiscoveredCheckout] {
        var settings = try self.settings()
        settings.scanRoots = roots
        return await RepoDiscovery.discover(settings: settings, includeWorkspaceFolders: true)
    }

    /// Registers checkouts found by `preview` or `RepoDiscovery`, under the
    /// same rules as `discover`.
    ///
    /// A clone whose config can run commands is never tracked here unless
    /// `trustCommandConfig` says the person ticked it knowing that; it is
    /// linked untracked and reported as `needsReview`.
    @discardableResult
    public func register(_ found: [DiscoveredCheckout], track: Bool = false, trackNew: Bool = false, trustCommandConfig: Bool = false) throws -> [DiscoveryResult] {
        let catalog = Dictionary((cachedCatalog()?.repos ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        return try store.update { doc in
            var results: [DiscoveryResult] = []
            for checkout in found {
                guard let key = checkout.key else {
                    results.append(DiscoveryResult(path: checkout.path, id: nil, displayName: nil, inCatalog: false, action: .noRemote, registeredPath: nil))
                    continue
                }
                let catalogEntry = catalog[key.id]
                let canonicalKey = catalogEntry?.key ?? key
                let held = checkout.runsCommands && !trustCommandConfig
                if let existing = doc.repos[key.id] {
                    if existing.path == checkout.path {
                        if track && !held { doc.repos[key.id]?.tracked = true }
                        results.append(DiscoveryResult(path: checkout.path, id: key.id, displayName: canonicalKey.displayName, inCatalog: catalogEntry != nil, action: .alreadyLinked, registeredPath: nil))
                        continue
                    }
                    if FileManager.default.fileExists(atPath: existing.path) {
                        results.append(DiscoveryResult(path: checkout.path, id: key.id, displayName: canonicalKey.displayName, inCatalog: catalogEntry != nil, action: .duplicate, registeredPath: existing.path))
                        continue
                    }
                }
                let previous = doc.repos[key.id]
                let wantsTracking = track || (previous?.tracked ?? trackNew)
                doc.repos[key.id] = RepoRegistryEntry(
                    key: canonicalKey,
                    path: checkout.path,
                    tracked: wantsTracking && !held,
                    remoteUrl: checkout.remoteUrl,
                    defaultBranch: catalogEntry?.defaultBranch,
                    hidden: previous?.hidden ?? false
                )
                results.append(DiscoveryResult(path: checkout.path, id: key.id, displayName: canonicalKey.displayName, inCatalog: catalogEntry != nil,
                                               action: wantsTracking && held ? .needsReview : .linked, registeredPath: nil))
            }
            return results
        }
    }

    /// Adds `folders` to the scan roots, marks the roots as chosen, and
    /// tracks every clone found in them: what the Repos sidebar's Choose
    /// Folder does, with no further questions. Clones whose config can run
    /// commands are left unregistered and returned for review instead.
    @discardableResult
    public func trackFolders(_ folders: [String]) async throws -> (results: [DiscoveryResult], review: [DiscoveredCheckout]) {
        let roots = folders.map(RepoSettings.abbreviate)
        try addScanRoots(roots)
        var settings = try self.settings()
        settings.scanRoots = roots
        let found = await RepoDiscovery.discover(settings: settings)
        let known = try store.load().repos
        let review = found.filter { $0.runsCommands && ($0.key.map { known[$0.id]?.tracked != true } ?? false) }
        let reviewPaths = Set(review.map(\.path))
        return (try register(found.filter { !reviewPaths.contains($0.path) }, track: true), review)
    }

    /// Adds roots (deduplicated, stored as `~/…`) and marks them as chosen.
    /// Until roots were chosen the list is only the default guess, so the
    /// first choice replaces it rather than adding to it.
    public func addScanRoots(_ folders: [String]) throws {
        try updateSettings { settings in
            if !settings.rootsChosen { settings.scanRoots = [] }
            for root in folders.map(RepoSettings.abbreviate) where !settings.scanRoots.contains(where: { RepoSettings.abbreviate($0) == root }) {
                settings.scanRoots.append(root)
            }
            settings.rootsChosen = true
        }
    }

    /// Clones in the scan roots the registry has never seen, when looking for
    /// them is on (nil when it is off). Nothing is registered: the person
    /// adds or ignores them. Found without running git, since an unknown
    /// clone's config is not trusted.
    public func newClones() async throws -> [DiscoveredCheckout]? {
        let settings = try self.settings()
        guard settings.looksForNewClones, !settings.scanRoots.isEmpty else { return nil }
        let found = await RepoDiscovery.discover(settings: settings)
        let doc = try store.load()
        let knownPaths = Set(doc.repos.values.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        var seen = Set<String>()
        return found.filter { checkout in
            guard let key = checkout.key, doc.repos[key.id] == nil,
                  !knownPaths.contains(URL(fileURLWithPath: checkout.path).standardizedFileURL.path) else { return false }
            return seen.insert(key.id).inserted
        }
    }

    /// The scan root each checkout sits in, for "found in ~/Code".
    public func scanRoot(containing path: String) -> String? {
        let roots = (try? settings().scanRoots) ?? []
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.first { root in
            let base = URL(fileURLWithPath: RepoSettings.expand(root)).standardizedFileURL.path
            return standard.hasPrefix(base + "/")
        }
    }

    /// Links new clones without tracking them, so they are not offered again.
    @discardableResult
    public func ignore(_ found: [DiscoveredCheckout]) throws -> [DiscoveryResult] {
        try register(found, track: false)
    }

    // MARK: - Removing a clone

    /// What deleting the checkout of `argument` would lose.
    public func removalCheck(_ argument: String) async throws -> CloneRemovalCheck {
        let record = try resolve(argument)
        guard let local = record.local else { throw RepoError.notLocal(record.key.displayName) }
        return await CloneRemovalCheck.inspect(path: local.path)
    }

    /// Moves the checkout of `argument` to the Trash and forgets it. Refuses
    /// when anything would be lost unless `force` is set; the error lists
    /// exactly what. A checkout already gone from disk is simply forgotten.
    @discardableResult
    public func removeClone(_ argument: String, force: Bool = false) async throws -> CloneRemovalCheck {
        let record = try resolve(argument)
        guard let local = record.local else { throw RepoError.notLocal(record.key.displayName) }
        let path = local.path
        guard FileManager.default.fileExists(atPath: path) else {
            try store.update { $0.repos[record.key.id] = nil }
            return CloneRemovalCheck(path: path)
        }
        try Self.refuseUnsafeTarget(path, settings: try settings())
        let check = await CloneRemovalCheck.inspect(path: path)
        if !check.isSafe && !force {
            throw RepoError.wouldLoseWork(record.key.displayName, check.lossDescription)
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            throw RepoError.invalidArgument("Could not move \(path) to the Trash: \(error.localizedDescription)")
        }
        try store.update { $0.repos[record.key.id] = nil }
        return check
    }

    /// Never trash the home folder, a filesystem root or a scan root itself,
    /// whatever the registry says.
    static func refuseUnsafeTarget(_ path: String, settings: RepoSettings) throws {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let roots = settings.scanRoots.map { URL(fileURLWithPath: RepoSettings.expand($0)).standardizedFileURL.path }
        let clone = URL(fileURLWithPath: RepoSettings.expand(settings.cloneRoot)).standardizedFileURL.path
        if standard == "/" || standard == home || roots.contains(standard) || standard == clone
            || standard.split(separator: "/").count < 2 {
            throw RepoError.invalidArgument("Refusing to delete \(path): it is not a single clone.")
        }
        guard RepoDiscovery.isCheckout(standard) else {
            throw RepoError.notAGitRepository(path)
        }
    }

    // MARK: - Cloning

    /// Where `clone` puts a repository: `<root>/AzDevOps/<Project>/<Repo>` or
    /// `<root>/GitHub/<owner>/<repo>`.
    public static func defaultClonePath(for key: RepoKey, root: String) -> String {
        let base = RepoSettings.expand(root)
        let components: [String]
        switch key.provider {
        case .azureDevOps: components = [key.provider.layoutFolder, key.project ?? key.owner, key.name]
        case .gitHub: components = [key.provider.layoutFolder, key.owner, key.name]
        case .other: components = [key.provider.layoutFolder, key.owner] + key.name.split(separator: "/").map(String.init)
        }
        return components.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Clones a catalog repository with the user's own git credentials and
    /// registers it as tracked.
    @discardableResult
    public func clone(_ argument: String, root: String? = nil, destination: String? = nil, useSSH: Bool = false) async throws -> RepoRegistryEntry {
        let record = try resolve(argument)
        guard let catalog = record.catalog else {
            throw RepoError.invalidArgument("\(record.key.displayName) is not in the catalog; run 'fleetmate repos catalog' first.")
        }
        if let local = record.local, FileManager.default.fileExists(atPath: local.path) {
            throw RepoError.destinationExists("\(record.key.displayName) is already at \(local.path)")
        }
        let cloneRoot = try root ?? settings().cloneRoot
        let target = destination.map(RepoSettings.expand) ?? Self.defaultClonePath(for: record.key, root: cloneRoot)
        if FileManager.default.fileExists(atPath: target) { throw RepoError.destinationExists(target) }
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        let url = useSSH ? (catalog.sshUrl ?? catalog.cloneUrl) : catalog.cloneUrl
        let result = await GitWorkingCopy.runGit(["clone", "--", url, target])
        guard result.succeeded else {
            throw RepoError.gitFailed(command: "clone", message: result.stderr.trimmed)
        }
        let entry = RepoRegistryEntry(key: record.key, path: target, tracked: true, remoteUrl: url, defaultBranch: catalog.defaultBranch)
        try store.update { $0.repos[record.key.id] = entry }
        return entry
    }

    // MARK: - Git

    public func workingCopy(for record: RepoRecord) throws -> GitWorkingCopy {
        guard let local = record.local else { throw RepoError.notLocal(record.key.displayName) }
        return GitWorkingCopy(path: local.path)
    }

    /// Branches `commit` and `push` refuse for this repository: the configured
    /// list plus the repository's own default branch.
    public func protectedBranches(for record: RepoRecord) -> Set<String> {
        var branches = Set((try? settings().protectedBranches) ?? RepoSettings.default.protectedBranches)
        if let branch = record.defaultBranch { branches.insert(branch) }
        return branches
    }

    public func status(for record: RepoRecord) async -> RepoStatus {
        guard let local = record.local else {
            return RepoStatus(id: record.id, displayName: record.key.displayName, path: "", snapshot: nil, worktrees: [], agentsFile: nil, error: RepoError.notLocal(record.key.displayName).localizedDescription)
        }
        let copy = GitWorkingCopy(path: local.path)
        guard FileManager.default.fileExists(atPath: local.path) else {
            return RepoStatus(id: record.id, displayName: record.key.displayName, path: local.path, snapshot: nil, worktrees: [], agentsFile: nil, error: "checkout missing at \(local.path)")
        }
        do {
            let snapshot = try await copy.statusSnapshot()
            let worktrees = await copy.worktrees()
            let lastCommit = await copy.lastCommitDate()
            return RepoStatus(id: record.id, displayName: record.key.displayName, path: local.path, snapshot: snapshot, worktrees: worktrees, agentsFile: copy.agentsFile, lastCommitAt: lastCommit, error: nil)
        } catch {
            return RepoStatus(id: record.id, displayName: record.key.displayName, path: local.path, snapshot: nil, worktrees: [], agentsFile: copy.agentsFile, error: error.localizedDescription)
        }
    }

    /// Status of many repositories, `settings.concurrency` at a time.
    public func status(for records: [RepoRecord]) async -> [RepoStatus] {
        let limit = (try? settings().concurrency) ?? RepoSettings.default.concurrency
        let manager = self
        return await boundedMap(records, limit: limit) { await manager.status(for: $0) }
    }

    public enum BatchOperation: String, Sendable {
        case fetch, pull
    }

    /// Runs fetch or pull across repositories with bounded concurrency. One
    /// repository failing never stops the others.
    public func run(_ operation: BatchOperation, on records: [RepoRecord]) async -> [RepoOperationResult] {
        let limit = (try? settings().concurrency) ?? RepoSettings.default.concurrency
        return await boundedMap(records, limit: limit) { record in
            guard let local = record.local else {
                return RepoOperationResult(id: record.id, displayName: record.key.displayName, operation: operation.rawValue, succeeded: false, output: "", error: RepoError.notLocal(record.key.displayName).localizedDescription)
            }
            let copy = GitWorkingCopy(path: local.path)
            do {
                let output = try await (operation == .fetch ? copy.fetch() : copy.pull())
                return RepoOperationResult(id: record.id, displayName: record.key.displayName, operation: operation.rawValue, succeeded: true, output: output.trimmed, error: nil)
            } catch {
                return RepoOperationResult(id: record.id, displayName: record.key.displayName, operation: operation.rawValue, succeeded: false, output: "", error: error.localizedDescription)
            }
        }
    }
}
