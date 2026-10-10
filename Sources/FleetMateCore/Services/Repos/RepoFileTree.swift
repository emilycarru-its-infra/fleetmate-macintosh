import Foundation

/// One entry of a checkout's file tree: a folder with children, or a file.
public struct RepoFileNode: Identifiable, Hashable, Sendable {
    public let name: String
    /// Repository-relative path. A folder's path has no trailing slash.
    public let path: String
    /// Nil for a file, so `OutlineGroup` shows no disclosure triangle.
    public var children: [RepoFileNode]?

    public var id: String { path }
    public var isFolder: Bool { children != nil }

    public init(name: String, path: String, children: [RepoFileNode]? = nil) {
        self.name = name
        self.path = path
        self.children = children
    }
}

/// One visible line of the outline.
public struct RepoFileRow: Identifiable, Hashable, Sendable {
    public let node: RepoFileNode
    public let depth: Int
    public let isExpanded: Bool
    public var id: String { node.path }
}

/// Turns git's flat path list into the outline the Repos view shows, and
/// filters it. Pure, so it is tested without a checkout.
public enum RepoFileTree {

    /// Folders first, then files, each sorted case-insensitively the way
    /// Finder does.
    public static func build(_ paths: [String]) -> [RepoFileNode] {
        let root = Folder()
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var folder = root
            for part in parts.dropLast() {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.insert(parts[parts.count - 1])
        }
        return root.nodes(prefix: "")
    }

    /// The subtree whose file paths contain `query` (case-insensitive). A
    /// folder stays when its own name matches — with all it holds — or when
    /// anything below it matches. An empty query returns `nodes` unchanged.
    public static func filter(_ nodes: [RepoFileNode], matching query: String) -> [RepoFileNode] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { filtered($0, needle) }
    }

    private static func filtered(_ node: RepoFileNode, _ needle: String) -> RepoFileNode? {
        guard let children = node.children else {
            return node.path.lowercased().contains(needle) ? node : nil
        }
        if node.name.lowercased().contains(needle) { return node }
        let kept = children.compactMap { filtered($0, needle) }
        guard !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        return copy
    }

    /// Every folder path in `nodes`, for expanding a filtered tree fully.
    public static func folderPaths(_ nodes: [RepoFileNode]) -> Set<String> {
        var result = Set<String>()
        func walk(_ list: [RepoFileNode]) {
            for node in list {
                guard let children = node.children else { continue }
                result.insert(node.path)
                walk(children)
            }
        }
        walk(nodes)
        return result
    }

    /// The rows an outline shows: each node with its depth, descending only
    /// into folders in `expanded`. Flattened so a lazy list renders a large
    /// checkout without building a view per file.
    public static func visibleRows(_ nodes: [RepoFileNode], expanded: Set<String>) -> [RepoFileRow] {
        var rows: [RepoFileRow] = []
        func walk(_ list: [RepoFileNode], depth: Int) {
            for node in list {
                let isOpen = node.isFolder && expanded.contains(node.path)
                rows.append(RepoFileRow(node: node, depth: depth, isExpanded: isOpen))
                if isOpen, let children = node.children { walk(children, depth: depth + 1) }
            }
        }
        walk(nodes, depth: 0)
        return rows
    }

    /// Number of files in `nodes`, counted through every folder.
    public static func fileCount(_ nodes: [RepoFileNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.children.map(fileCount) ?? 1) }
    }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: Set<String> = []

        func nodes(prefix: String) -> [RepoFileNode] {
            let order: (String, String) -> Bool = {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            let folderNodes = folders.keys.sorted(by: order).map { name -> RepoFileNode in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return RepoFileNode(name: name, path: path, children: folders[name]!.nodes(prefix: path))
            }
            let fileNodes = files.sorted(by: order).map { name in
                RepoFileNode(name: name, path: prefix.isEmpty ? name : prefix + "/" + name)
            }
            return folderNodes + fileNodes
        }
    }
}

/// Repositories grouped the way Settings lists them: by project on Azure
/// DevOps, by owner on GitHub.
public struct RepoRecordGroup: Identifiable, Sendable {
    public let provider: RepoProvider
    /// Project (Azure DevOps), owner (GitHub) or host (other).
    public let scope: String
    public let records: [RepoRecord]

    public var id: String { "\(provider.rawValue):\(scope.lowercased())" }

    public var title: String {
        switch provider {
        case .azureDevOps: "Azure DevOps · \(scope)"
        case .gitHub: "GitHub · \(scope)"
        case .other: scope
        }
    }

    /// Groups `records` after keeping those whose name, id or local path
    /// contains `query`. Providers appear Azure DevOps, GitHub, other; scopes
    /// and repositories alphabetically within each.
    public static func groups(_ records: [RepoRecord], matching query: String = "") -> [RepoRecordGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = needle.isEmpty ? records : records.filter { record in
            record.key.displayName.lowercased().contains(needle)
                || record.key.id.contains(needle)
                || (record.local?.path.lowercased().contains(needle) ?? false)
        }
        let order: [RepoProvider: Int] = [.azureDevOps: 0, .gitHub: 1, .other: 2]
        let grouped = Dictionary(grouping: kept) { GroupKey(provider: $0.key.provider, scope: $0.key.scope.lowercased()) }
        return grouped.map { key, members in
            RepoRecordGroup(
                provider: key.provider,
                scope: members[0].key.scope,
                records: members.sorted { $0.key.name.localizedStandardCompare($1.key.name) == .orderedAscending }
            )
        }
        .sorted {
            let (a, b) = (order[$0.provider] ?? 9, order[$1.provider] ?? 9)
            return a != b ? a < b : $0.scope.localizedStandardCompare($1.scope) == .orderedAscending
        }
    }

    private struct GroupKey: Hashable {
        let provider: RepoProvider
        let scope: String
    }
}

/// Whether a file's bytes can be edited as text.
public enum RepoTextFile {
    /// Files larger than this open read-only in a viewer, not the editor.
    public static let editableLimit = 4 * 1024 * 1024

    /// The file as UTF-8 text, or nil when it looks binary: a NUL byte in its
    /// first 8 KB, as git itself decides, or bytes that are not UTF-8.
    public static func decode(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }
}
