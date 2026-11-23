import Foundation

/// How the Repos sidebar orders repositories within a group (or the whole
/// list when it is not grouped).
public enum RepoSidebarSort: String, Codable, Sendable, CaseIterable {
    /// The one repository order set in Settings › Repositories, which the
    /// Agents sidebar's headings follow too.
    case repositoryOrder
    case name
    /// Most recent commit on HEAD first.
    case recentlyChanged
    /// Most uncommitted paths first.
    case mostChanges
    /// Furthest behind its upstream first.
    case mostBehind

    public var title: String {
        switch self {
        case .repositoryOrder: "Repository Order"
        case .name: "Name"
        case .recentlyChanged: "Recently Changed"
        case .mostChanges: "Most Changes"
        case .mostBehind: "Most Behind"
        }
    }
}

/// One host in the sidebar — Azure DevOps, GitHub, or another — holding its
/// projects or owners, the way checkouts are laid out on disk.
public struct RepoSidebarSection: Identifiable, Sendable {
    public let provider: RepoProvider
    public let groups: [RepoRecordGroup]

    public var id: String { provider.rawValue }

    public var title: String {
        switch provider {
        case .azureDevOps: "Azure DevOps"
        case .gitHub: "GitHub"
        case .other: "Other"
        }
    }

    public var repositoryCount: Int { groups.reduce(0) { $0 + $1.records.count } }
}

/// Builds the Repos sidebar: filter, group by host ▸ project/owner, sort.
/// Pure, so the ordering rules are tested without a view.
public enum RepoSidebarOrganizer {

    /// Host sections, each with its projects or owners alphabetically, and
    /// repositories inside each ordered by `sort`. Empty groups are dropped.
    /// Sorted by repository order, the hosts and groups follow it too: each
    /// goes where its first repository is.
    public static func sections(
        _ records: [RepoRecord],
        statuses: [String: RepoStatus],
        sort: RepoSidebarSort,
        order: RepositoryOrderRank = .empty,
        matching query: String = ""
    ) -> [RepoSidebarSection] {
        var groups = RepoRecordGroup.groups(records, matching: query).map { group in
            RepoRecordGroup(provider: group.provider, scope: group.scope,
                            records: sorted(group.records, statuses: statuses, by: sort, order: order))
        }
        if sort == .repositoryOrder, !order.isEmpty {
            func first(_ group: RepoRecordGroup) -> Int? { group.records.compactMap { rank($0, order) }.min() }
            groups = order.sorted(groups, by: first)
            var providerRank: [RepoProvider: Int] = [:]
            for (index, group) in groups.enumerated() where providerRank[group.provider] == nil {
                providerRank[group.provider] = first(group) ?? (Int.max / 2 + index)
            }
            groups = order.sorted(groups) { providerRank[$0.provider] }
        }
        var sections: [RepoSidebarSection] = []
        for group in groups {
            if let last = sections.last, last.provider == group.provider {
                sections[sections.count - 1] = RepoSidebarSection(provider: last.provider, groups: last.groups + [group])
            } else {
                sections.append(RepoSidebarSection(provider: group.provider, groups: [group]))
            }
        }
        return sections
    }

    /// Every match in one list ordered by `sort`, for the ungrouped sidebar.
    public static func flat(
        _ records: [RepoRecord],
        statuses: [String: RepoStatus],
        sort: RepoSidebarSort,
        order: RepositoryOrderRank = .empty,
        matching query: String = ""
    ) -> [RepoRecord] {
        sorted(RepoRecordGroup.groups(records, matching: query).flatMap(\.records), statuses: statuses, by: sort, order: order)
    }

    /// Where a repository is in the repository order: by its checkout, else
    /// by its `Project/Repo`.
    static func rank(_ record: RepoRecord, _ order: RepositoryOrderRank) -> Int? {
        record.local.flatMap { order.rank(path: $0.path) } ?? order.rank(name: record.key.displayName)
    }

    /// Orders by the chosen key, falling back to the display name so the order
    /// is stable while statuses load.
    public static func sorted(_ records: [RepoRecord], statuses: [String: RepoStatus], by sort: RepoSidebarSort,
                              order: RepositoryOrderRank = .empty) -> [RepoRecord] {
        let byName: (RepoRecord, RepoRecord) -> Bool = {
            let order = $0.key.name.localizedStandardCompare($1.key.name)
            return order != .orderedSame ? order == .orderedAscending : $0.key.displayName < $1.key.displayName
        }
        switch sort {
        case .repositoryOrder:
            return order.sorted(records.sorted(by: byName)) { rank($0, order) }
        case .name:
            return records.sorted(by: byName)
        case .recentlyChanged:
            return records.sorted { a, b in
                let (x, y) = (statuses[a.id]?.lastCommitAt ?? .distantPast, statuses[b.id]?.lastCommitAt ?? .distantPast)
                return x != y ? x > y : byName(a, b)
            }
        case .mostChanges:
            return records.sorted { a, b in
                let (x, y) = (statuses[a.id]?.changedCount ?? 0, statuses[b.id]?.changedCount ?? 0)
                return x != y ? x > y : byName(a, b)
            }
        case .mostBehind:
            return records.sorted { a, b in
                let (x, y) = (statuses[a.id]?.behind ?? 0, statuses[b.id]?.behind ?? 0)
                return x != y ? x > y : byName(a, b)
            }
        }
    }
}
