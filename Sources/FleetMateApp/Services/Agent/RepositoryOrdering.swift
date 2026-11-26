import AppKit
import Combine
import Foundation
import FleetMateCore
import AgentsMate

/// The one repository order, for every list of repositories FleetMate shows:
/// the Agents sidebar's headings, Settings › Repositories, the Repos sidebar
/// and the repository filters. The person's saved order lives in the lane
/// store's layout; the default is the rendered agent-apps registry's order
/// when there is one (``AgentAppsRepoRegistry``), else the Agent's own list.
@MainActor
final class RepositoryOrdering: ObservableObject {
    static let shared = RepositoryOrdering()

    /// The rendered registry, re-read on each refresh; nil when there is none.
    @Published private(set) var registry: AgentAppsRepoRegistry?
    /// Each known repository's place in the order.
    @Published private(set) var rank: RepositoryOrderRank = .empty
    /// Every known repository, in the order, as Settings lists them.
    @Published private(set) var items: [AgentRepositoryItem] = []

    private var subscriptions = Set<AnyCancellable>()
    private weak var store: AgentLaneStore?
    private var fallback: () -> [String] = { [] }

    private init() {
        registry = AgentAppsRepoRegistry.loadCurrent()
    }

    /// The default order: the registry's (else `fallback`, the Agent's list)
    /// with Azure DevOps first and GitHub last, Devices leading, and the
    /// checkouts the registry does not list after those it does
    /// (``RepositoryDefaultOrder``).
    func defaultOrder(fallback: [String], records: [RepoRecord] = []) -> [String] {
        let entries = records.compactMap { record -> RepositoryDefaultOrder.Entry? in
            guard let path = record.local?.path else { return nil }
            return RepositoryDefaultOrder.Entry(path: path, provider: record.key.provider,
                                                scope: record.key.scope, name: record.key.name)
        }
        return RepositoryDefaultOrder.make(listed: registry?.orderedPaths ?? AgentRepoList.localPaths(fallback), entries: entries)
    }

    /// Follow `store`, re-reading whenever the saved order, the registry or
    /// the Agent's list changes, and when the app comes to the front (the
    /// rendered registry is written by another tool). Safe to call once.
    func attach(to store: AgentLaneStore, fallback: @escaping () -> [String]) {
        guard self.store == nil else { return }
        self.store = store
        self.fallback = fallback
        refresh()
        let changes: [AnyPublisher<Void, Never>] = [
            store.$layout.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .repoRegistryChanged).map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.eraseToAnyPublisher(),
            RepoIcons.shared.$choices.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
    }

    /// Re-read the registry and the checkouts, and recompute the order.
    func refresh() {
        let loaded = AgentAppsRepoRegistry.loadCurrent()
        if loaded != registry { registry = loaded }
        guard let store else { return }
        let agent = fallback()
        let records = ((try? RepoManager().records()) ?? []).filter { $0.isLocal && !$0.isHidden }
        let defaults = defaultOrder(fallback: agent, records: records.filter(\.isTracked))
        if store.defaultRepositoryOrder != defaults { store.defaultRepositoryOrder = defaults }

        var byPath: [String: RepoRecord] = [:]
        for record in records {
            guard let path = record.local?.path else { continue }
            byPath[AgentRepoList.normalized(path)] = byPath[AgentRepoList.normalized(path)] ?? record
        }
        var seen = Set<String>()
        let candidates = (defaults + records.filter(\.isTracked).compactMap { $0.local?.path }
                          + AgentRepoList.localPaths(agent))
            .map { AgentRepoList.normalized($0) }
            .filter { seen.insert($0.lowercased()).inserted }
        let ordered = store.orderedRepositories(candidates)
        var names: [String: String] = [:]
        for path in ordered { if let record = byPath[path] { names[path] = record.key.displayName } }
        let newRank = RepositoryOrderRank(orderedPaths: ordered, names: names)
        if newRank != rank { rank = newRank }

        let sections = registry?.sectionByPath.reduce(into: [String: String]()) {
            $0[AgentRepoList.normalized($1.key)] = $1.value
        } ?? [:]
        let registryNames = (registry?.sections.flatMap(\.repos) ?? []).reduce(into: [String: String]()) {
            if let name = $1.name, !name.isEmpty { $0[AgentRepoList.normalized($1.path)] = name }
        }
        let newItems = ordered.map { path -> AgentRepositoryItem in
            let record = byPath[path]
            let title = record?.key.name ?? registryNames[path] ?? (path as NSString).lastPathComponent
            let subtitle = [sections[path], repoAbbreviatedPath(path)].compactMap { $0 }.joined(separator: " · ")
            let choice = record.flatMap { RepoIcons.shared.choice(for: $0.id) }
            return AgentRepositoryItem(path: path, title: title, subtitle: subtitle,
                                       icon: choice.flatMap { LaneIcon($0.icon) }, tintHex: choice?.tint)
        }
        if newItems != items { items = newItems }
    }

    /// Agent list entries (folders written with `~`, or clone URLs) in the
    /// order; clone URLs keep their place after the folders it knows.
    func sorted(agentEntries entries: [String]) -> [String] {
        rank.sorted(entries) { $0.contains("://") ? nil : rank.rank(path: $0) }
    }
}
