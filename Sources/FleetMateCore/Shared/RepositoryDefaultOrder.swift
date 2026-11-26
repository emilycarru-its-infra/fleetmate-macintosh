import Foundation

/// The order FleetMate's repositories, and so its lane sections, take until
/// the person sets one of their own.
///
/// Sections follow the order of their first repository, so ordering the
/// repositories orders the sections. The rules, strongest first:
///
/// 1. Azure DevOps repositories come first and GitHub repositories last,
///    folders that are neither between them.
/// 2. Within each, a repository the rendered registry lists keeps the
///    registry's order, ahead of one it does not list.
/// 3. The rest are ordered by section (the Azure DevOps project or GitHub
///    owner), with `leadingSections` first, then by repository name.
///
/// With no registry, rules 1 and 3 alone give every install the same default.
public enum RepositoryDefaultOrder {
    /// A tracked checkout, as the order needs it.
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var provider: RepoProvider
        /// The Azure DevOps project or GitHub owner: the section it is under.
        public var scope: String
        public var name: String

        public init(path: String, provider: RepoProvider, scope: String, name: String) {
            self.path = path
            self.provider = provider
            self.scope = scope
            self.name = name
        }
    }

    /// Sections that lead their provider's group, in this order, by name
    /// compared without case. Devices is FleetMate's own subject, so it is
    /// the first section a new install shows.
    public static let leadingSections = ["Devices"]

    /// `listed` is the registry's order (or the Agent's list when there is no
    /// registry); `entries` are the checkouts. Every folder from either
    /// appears once, as written in the first place it was named.
    public static func make(listed: [String], entries: [Entry]) -> [String] {
        let byPath = Dictionary(entries.map { (key($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var listedRank: [String: Int] = [:]
        for (index, path) in listed.enumerated() where listedRank[key(path)] == nil { listedRank[key(path)] = index }

        var seen = Set<String>()
        let all = (listed + entries.map(\.path)).filter { seen.insert(key($0)).inserted }
        let leading = leadingSections.map { $0.lowercased() }

        struct Sortable { var path: String; var group: Int; var listed: Int; var lead: Int; var scope: String; var name: String; var index: Int }
        let rows = all.enumerated().map { index, path -> Sortable in
            let entry = byPath[key(path)]
            let scope = (entry?.scope ?? "").lowercased()
            return Sortable(path: path, group: group(of: path, entry: entry),
                            listed: listedRank[key(path)] ?? Int.max,
                            lead: leading.firstIndex(of: scope) ?? Int.max,
                            scope: scope, name: (entry?.name ?? (path as NSString).lastPathComponent).lowercased(),
                            index: index)
        }
        return rows.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.listed != b.listed { return a.listed < b.listed }
            if a.lead != b.lead { return a.lead < b.lead }
            if a.scope != b.scope { return a.scope < b.scope }
            if a.name != b.name { return a.name < b.name }
            return a.index < b.index
        }.map(\.path)
    }

    /// 0 Azure DevOps, 1 neither, 2 GitHub. A folder that is no checkout is
    /// GitHub's only when a component of its path says so.
    static func group(of path: String, entry: Entry?) -> Int {
        if let entry {
            switch entry.provider {
            case .azureDevOps: return 0
            case .other: return 1
            case .gitHub: return 2
            }
        }
        return path.split(separator: "/").contains { $0.lowercased() == "github" } ? 2 : 1
    }

    private static func key(_ path: String) -> String { AgentRepoList.normalized(path).lowercased() }
}
