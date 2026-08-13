import Foundation

// MARK: - Stored Queries (Shared Queries)
//
// The Projects tab's List view renders every Shared Query with its results
// expanded, the way the Azure DevOps query grid does. Three pieces make that
// possible: enumerating the Shared Queries folder tree, running a stored
// query by id (flat and tree results differ structurally), and a type-scoped
// item fetch so boards can load *all* items of their types instead of only
// whatever survived the recency-capped org-wide fetch.

public extension AzureDevOpsService {
    /// Rows per query the UI will materialize. Queries can legally return
    /// thousands of items; past this cap the run is marked truncated.
    static let storedQueryRowCap = 500

    /// All leaf queries under the project's "Shared Queries" folder,
    /// including those nested one folder deep, in display order.
    func getSharedQueries(project: String? = nil) async throws -> [AdoSharedQuery] {
        dbg.info("AzDO getSharedQueries project=\(project ?? resolvedProject)", category: "azdo")
        let root: AdoQuery = try await request(
            "GET",
            path: "/_apis/wit/queries/Shared%20Queries?$depth=2&$expand=all&api-version=7.0",
            forProject: project
        )

        var leaves: [AdoSharedQuery] = []
        func walk(_ node: AdoQuery, folderPath: String) {
            for child in node.children ?? [] {
                if child.isLeafQuery {
                    leaves.append(AdoSharedQuery(
                        id: child.id,
                        name: child.name ?? "Untitled query",
                        folderPath: folderPath,
                        queryType: child.resolvedQueryType
                    ))
                } else {
                    let nested = folderPath.isEmpty
                        ? (child.name ?? "")
                        : "\(folderPath)/\(child.name ?? "")"
                    walk(child, folderPath: nested)
                }
            }
        }
        walk(root, folderPath: "")
        dbg.info("AzDO getSharedQueries → \(leaves.count) queries", category: "azdo")
        return leaves
    }

    /// Run a stored query by id and materialize its rows in display order.
    /// Flat queries return `workItems`; tree and one-hop queries return
    /// `workItemRelations` edges that are rebuilt into a pre-order flattened
    /// hierarchy with depths, matching the Azure DevOps results grid.
    func runStoredQuery(id queryId: String, project: String? = nil) async throws -> StoredQueryRun {
        let result: WorkItemQueryResult = try await request(
            "GET",
            path: "/_apis/wit/wiql/\(queryId)?api-version=7.0",
            forProject: project
        )

        let queryType = result.queryType ?? "flat"

        if let links = result.workItemRelations {
            return try await materializeTree(queryId: queryId, queryType: queryType, links: links)
        }

        let refs = result.workItems ?? []
        let truncated = refs.count > Self.storedQueryRowCap
        let ids = refs.prefix(Self.storedQueryRowCap).map { $0.id }
        let items = try await getWorkItemsByIds(Array(ids))
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let rows = ids.compactMap { byId[$0] }.map {
            StoredQueryRow(item: $0, depth: 0, hasChildren: false)
        }
        return StoredQueryRun(queryId: queryId, queryType: queryType, rows: rows, truncated: truncated)
    }

    /// Rebuild tree/one-hop edges into ordered rows. Edges arrive in display
    /// order: a nil source marks a root, any other edge hangs `target` under
    /// `source`.
    private func materializeTree(queryId: String, queryType: String, links: [WorkItemLink]) async throws -> StoredQueryRun {
        struct Node {
            let id: Int
            var children: [Int] = []
        }

        var order: [Int] = []           // roots in appearance order
        var nodes: [Int: Node] = [:]
        var childIds = Set<Int>()

        for link in links {
            guard let targetId = link.target?.id else { continue }
            if nodes[targetId] == nil { nodes[targetId] = Node(id: targetId) }
            if let sourceId = link.source?.id {
                if nodes[sourceId] == nil { nodes[sourceId] = Node(id: sourceId) }
                // The same target can legally appear under several sources in
                // one-hop queries; keep the first placement only.
                if !childIds.contains(targetId) {
                    nodes[sourceId]?.children.append(targetId)
                    childIds.insert(targetId)
                }
            } else if !order.contains(targetId) {
                order.append(targetId)
            }
        }

        // Pre-order flatten with depths, capped.
        var flattened: [(id: Int, depth: Int, hasChildren: Bool)] = []
        var truncated = false
        func visit(_ id: Int, depth: Int) {
            guard flattened.count < Self.storedQueryRowCap else {
                truncated = true
                return
            }
            let children = nodes[id]?.children ?? []
            flattened.append((id, depth, !children.isEmpty))
            for child in children { visit(child, depth: depth + 1) }
        }
        for rootId in order { visit(rootId, depth: 0) }

        let items = try await getWorkItemsByIds(flattened.map { $0.id })
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let rows: [StoredQueryRow] = flattened.compactMap { entry in
            guard let item = byId[entry.id] else { return nil }
            return StoredQueryRow(item: item, depth: entry.depth, hasChildren: entry.hasChildren)
        }
        return StoredQueryRun(queryId: queryId, queryType: queryType, rows: rows, truncated: truncated)
    }

    /// Every work item of the given types in one project, no recency cap.
    /// Boards filter to their column types; the org-wide task fetch keeps
    /// only the most recently changed items, so without this, long-lived
    /// items (Initiatives especially) silently vanish from board views.
    func getWorkItemsOfTypes(_ types: [String], project: String) async throws -> [WorkItem] {
        guard !types.isEmpty else { return [] }
        let list = types.map { "'\(escapeWiql($0))'" }.joined(separator: ", ")
        let wiql = """
        SELECT [System.Id] FROM WorkItems \
        WHERE [System.TeamProject] = '\(escapeWiql(project))' \
        AND [System.WorkItemType] IN (\(list)) \
        ORDER BY [System.ChangedDate] DESC
        """
        return try await queryWorkItems(wiql, orgLevel: true)
    }

    /// Web URL for a stored query's results page.
    func storedQueryWebUrl(queryId: String, project: String? = nil) -> String {
        let proj = project ?? resolvedProject
        let encoded = proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj
        return "\(baseUrl)/\(encoded)/_queries/query/\(queryId)/"
    }
}
