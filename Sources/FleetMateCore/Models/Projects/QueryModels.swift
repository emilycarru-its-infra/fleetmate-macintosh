import Foundation

// MARK: - Stored Query Models (Azure DevOps Shared Queries)

/// A saved query (or query folder) from the Azure DevOps Queries API.
public struct AdoQuery: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let path: String?
    public let isFolder: Bool?
    public let isPublic: Bool?
    public let hasChildren: Bool?
    public let queryType: String?
    public let children: [AdoQuery]?

    public var isLeafQuery: Bool { !(isFolder ?? false) }

    /// "tree", "oneHop" or "flat" — defaults to flat when the API omits it.
    public var resolvedQueryType: String { queryType ?? "flat" }
}

public struct AdoQueriesResponse: Codable {
    public let count: Int?
    public let value: [AdoQuery]?
}

/// A leaf query flattened out of the Shared Queries folder tree.
/// `folderPath` is the human path between "Shared Queries" and the query
/// itself ("" for queries sitting directly in Shared Queries).
public struct AdoSharedQuery: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let folderPath: String
    public let queryType: String

    public init(id: String, name: String, folderPath: String, queryType: String) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.queryType = queryType
    }
}

/// One row of a stored query run, pre-order flattened for display.
/// `depth` is 0 for roots; tree queries indent children below their parent
/// exactly as the Azure DevOps results grid does.
public struct StoredQueryRow: Identifiable {
    public let item: WorkItem
    public let depth: Int
    public let hasChildren: Bool

    public var id: Int { item.id }

    public init(item: WorkItem, depth: Int, hasChildren: Bool) {
        self.item = item
        self.depth = depth
        self.hasChildren = hasChildren
    }
}

/// The materialized result of running one stored query.
public struct StoredQueryRun {
    public let queryId: String
    public let queryType: String
    public let rows: [StoredQueryRow]
    /// True when the run was capped and more rows exist server-side.
    public let truncated: Bool

    public init(queryId: String, queryType: String, rows: [StoredQueryRow], truncated: Bool) {
        self.queryId = queryId
        self.queryType = queryType
        self.rows = rows
        self.truncated = truncated
    }
}

// MARK: - WorkItem → UnifiedTask

public extension WorkItem {
    /// The same mapping AzureDevOpsTaskProvider applies, exposed so views can
    /// promote raw query results into the unified task shape the detail
    /// sidebar and context menus already understand.
    func asUnifiedTask() -> UnifiedTask {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func parseDate(_ str: String?) -> Date? {
            guard let str else { return nil }
            return dateFormatter.date(from: str)
        }

        let assigneeList: [String] = {
            if let assignedTo = fields?.assignedTo {
                return [assignedTo.displayName ?? assignedTo.uniqueName ?? ""]
            }
            return []
        }()

        var metadata: [String: String] = [:]
        if let area = fields?.areaPath { metadata["areaPath"] = area }
        if let iter = fields?.iterationPath { metadata["iterationPath"] = iter }
        if let wiType = fields?.workItemType { metadata["workItemType"] = wiType }
        if let state = fields?.state { metadata["state"] = state }
        if let board = fields?.boardColumn { metadata["boardColumn"] = board }
        if let project = fields?.teamProject { metadata["teamProject"] = project }

        let state: TaskState
        switch (fields?.state ?? "New").lowercased() {
        case "new", "to do", "proposed":
            state = .open
        case "active", "in progress", "doing", "committed":
            state = .inProgress
        case "closed", "done", "resolved", "completed", "removed":
            state = .closed
        default:
            state = .open
        }

        let labels: [String] = (fields?.tags ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return UnifiedTask(
            id: String(id),
            provider: "azdevops",
            title: fields?.title ?? "",
            description: fields?.description,
            state: state,
            assignees: assigneeList,
            labels: labels,
            bucket: fields?.iterationPath,
            dueDate: nil,
            createdAt: parseDate(fields?.createdDate) ?? .distantPast,
            updatedAt: parseDate(fields?.changedDate) ?? .distantPast,
            closedAt: nil,
            externalUrl: url?.replacingOccurrences(of: "_apis/wit/workItems", with: "_workitems/edit"),
            priority: fields?.priority,
            metadata: metadata
        )
    }
}
