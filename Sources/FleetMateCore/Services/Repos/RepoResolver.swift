import Foundation

/// A repository as the CLI and app see it: its identity, what the provider
/// says about it (when it is in the catalog), and its local checkout (when
/// registered).
public struct RepoRecord: Codable, Sendable, Identifiable {
    public let key: RepoKey
    public let catalog: CatalogRepo?
    public let local: RepoRegistryEntry?

    public var id: String { key.id }
    public var isLocal: Bool { local != nil }
    public var isTracked: Bool { local?.tracked ?? false }
    public var defaultBranch: String? { catalog?.defaultBranch ?? local?.defaultBranch }

    public init(key: RepoKey, catalog: CatalogRepo?, local: RepoRegistryEntry?) {
        self.key = key
        self.catalog = catalog
        self.local = local
    }

    /// Merges a catalog and registry into one record per repository.
    public static func merge(catalog: [CatalogRepo], registry: [RepoRegistryEntry]) -> [RepoRecord] {
        var byId: [String: (RepoKey, CatalogRepo?, RepoRegistryEntry?)] = [:]
        for repo in catalog { byId[repo.id] = (repo.key, repo, nil) }
        for entry in registry {
            let existing = byId[entry.key.id]
            byId[entry.key.id] = (existing?.0 ?? entry.key, existing?.1, entry)
        }
        return byId.values.map { RepoRecord(key: $0.0, catalog: $0.1, local: $0.2) }.sorted { $0.key < $1.key }
    }
}

/// Turns what a person or agent typed into one repository.
///
/// Accepted forms, all case-insensitive:
/// - the registry id: `github:owner/repo`, `azdo:org/project/repo`
/// - `name`
/// - `project/name` (Azure DevOps) or `owner/name` (GitHub)
/// - `org/project/name` (Azure DevOps)
/// - a path to a registered checkout, when it starts with `/`, `~` or `.`
///
/// More than one match is an error that lists the candidates.
public enum RepoResolver {

    public static func resolve(_ argument: String, in records: [RepoRecord]) throws -> RepoRecord {
        let matches = candidates(argument, in: records)
        switch matches.count {
        case 1: return matches[0]
        case 0: throw RepoError.notFound(argument)
        default: throw RepoError.ambiguous(argument, candidates: matches.map { "\($0.key.displayName)  (\($0.key.id))" })
        }
    }

    public static func candidates(_ argument: String, in records: [RepoRecord]) -> [RepoRecord] {
        let arg = argument.trimmingCharacters(in: .whitespaces)
        guard !arg.isEmpty else { return [] }

        if arg.hasPrefix("/") || arg.hasPrefix("~") || arg.hasPrefix(".") {
            let target = URL(fileURLWithPath: RepoSettings.expand(arg)).standardizedFileURL.path
            return records.filter { record in
                guard let path = record.local?.path else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL.path == target
            }
        }

        let lower = arg.lowercased()
        if lower.contains(":") {
            return records.filter { $0.key.id == lower }
        }

        let parts = lower.split(separator: "/").map(String.init)
        return records.filter { record in
            let key = record.key
            let name = key.name.lowercased()
            switch parts.count {
            case 1:
                return name == parts[0]
            case 2:
                return name == parts[1] && key.scope.lowercased() == parts[0]
            case 3:
                return key.provider == .azureDevOps
                    && key.owner.lowercased() == parts[0]
                    && key.project?.lowercased() == parts[1]
                    && name == parts[2]
            default:
                return false
            }
        }
    }
}
