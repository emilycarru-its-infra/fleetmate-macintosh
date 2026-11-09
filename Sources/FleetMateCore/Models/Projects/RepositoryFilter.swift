import Foundation

/// Provider-qualified identity for a repository filter, independent of its visible label.
public struct RepositoryFilterScope: Hashable, Sendable {
    public let source: PullRequestSource
    public let container: String
    public let repository: String?
    private static let identityCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(source: PullRequestSource, container: String, repository: String?) {
        self.source = source
        self.container = container
        self.repository = repository.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var id: String {
        func encode(_ value: String) -> String {
            value.lowercased().addingPercentEncoding(withAllowedCharacters: Self.identityCharacters) ?? value.lowercased()
        }
        return "repository/\(source.rawValue)/\(encode(container))/\(encode(repository ?? ""))"
    }

    public init?(id: String) {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "repository", let source = PullRequestSource(rawValue: parts[1]),
              let container = parts[2].removingPercentEncoding, let repository = parts[3].removingPercentEncoding else { return nil }
        self.init(source: source, container: container, repository: repository.isEmpty ? nil : repository)
    }

    public var displayPath: String { repository.map { "\(container)/\($0)" } ?? container }
    public var repositoryTitle: String { repository ?? "Project pipelines" }

    /// Graphs may still select their existing aggregate labels; menus select exact scopes.
    public func matches(_ selection: String, legacyKey: String) -> Bool {
        Self(id: selection) != nil ? id == selection : legacyKey == selection
    }

    public static func displayKey(_ selection: String?) -> String? {
        selection.map { RepositoryFilterScope(id: $0)?.displayPath ?? $0 }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct RepositoryFilterEntry: Identifiable, Sendable {
    public let scope: RepositoryFilterScope
    public let count: Int
    public let legacyKey: String
    public var id: String { scope.id }

    public init(scope: RepositoryFilterScope, count: Int, legacyKey: String? = nil) {
        self.scope = scope
        self.count = count
        self.legacyKey = legacyKey ?? scope.repository ?? scope.container
    }

    public static func counts<T>(_ items: [T], scope: (T) -> RepositoryFilterScope,
                                  legacyKey: ((T) -> String)? = nil, weight: (T) -> Int = { _ in 1 }) -> [Self] {
        var entries: [String: Self] = [:]
        for item in items {
            let identity = scope(item)
            let old = entries[identity.id]
            entries[identity.id] = Self(scope: old?.scope ?? identity, count: (old?.count ?? 0) + weight(item),
                                        legacyKey: old?.legacyKey ?? legacyKey?(item))
        }
        return entries.values.sorted { $0.scope.displayPath.localizedStandardCompare($1.scope.displayPath) == .orderedAscending }
    }
}

public struct RepositoryFilterContainer: Identifiable, Sendable {
    public let name: String
    public let entries: [RepositoryFilterEntry]
    public var id: String { name.lowercased() }
    public var count: Int { entries.reduce(0) { $0 + $1.count } }
}

public struct RepositoryFilterProvider: Identifiable, Sendable {
    public let source: PullRequestSource
    public let containers: [RepositoryFilterContainer]
    public var id: PullRequestSource { source }
    public var count: Int { containers.reduce(0) { $0 + $1.count } }

    public static func groups(_ entries: [RepositoryFilterEntry]) -> [Self] {
        PullRequestSource.allCases.compactMap { source in
            let rows = entries.filter { $0.scope.source == source }
            guard !rows.isEmpty else { return nil }
            let containers = Dictionary(grouping: rows, by: { $0.scope.container.lowercased() }).values.map { rows in
                RepositoryFilterContainer(name: rows[0].scope.container,
                    entries: rows.sorted { $0.scope.repositoryTitle.localizedStandardCompare($1.scope.repositoryTitle) == .orderedAscending })
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return Self(source: source, containers: containers)
        }
    }
}

public extension UnifiedPullRequest {
    var repositoryFilterScope: RepositoryFilterScope {
        .init(source: source, container: container, repository: repository)
    }
}

public extension RepositoryCommits {
    var repositoryFilterScope: RepositoryFilterScope {
        .init(source: source, container: container, repository: repository)
    }
}

public extension PipelineRun {
    var repositoryFilterScope: RepositoryFilterScope {
        .init(source: source, container: container, repository: repository)
    }
}
