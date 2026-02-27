import Foundation

// MARK: - Work Item Models

public struct WorkItem: Codable, Identifiable {
    public let id: Int
    public let rev: Int?
    public let fields: WorkItemFields?
    public let url: String?
    public let relations: [WorkItemRelation]?
}

public struct WorkItemFields: Codable {
    public let title: String?
    public let state: String?
    public let workItemType: String?
    public let assignedTo: IdentityRef?
    public let createdDate: String?
    public let changedDate: String?
    public let description: String?
    public let priority: Int?
    public let iterationPath: String?
    public let areaPath: String?
    public let tags: String?
    public let teamProject: String?

    // Extended fields
    public let reason: String?
    public let createdBy: IdentityRef?
    public let changedBy: IdentityRef?
    public let resolvedBy: IdentityRef?
    public let resolvedDate: String?
    public let closedBy: IdentityRef?
    public let closedDate: String?
    public let stateChangeDate: String?
    public let boardColumn: String?
    public let boardColumnDone: Bool?
    public let commentCount: Int?
    public let remainingWork: Double?
    public let originalEstimate: Double?
    public let completedWork: Double?
    public let reproSteps: String?
    public let acceptanceCriteria: String?
    public let dueDate: String?

    enum CodingKeys: String, CodingKey {
        case title = "System.Title"
        case state = "System.State"
        case workItemType = "System.WorkItemType"
        case assignedTo = "System.AssignedTo"
        case createdDate = "System.CreatedDate"
        case changedDate = "System.ChangedDate"
        case description = "System.Description"
        case priority = "Microsoft.VSTS.Common.Priority"
        case iterationPath = "System.IterationPath"
        case areaPath = "System.AreaPath"
        case tags = "System.Tags"
        case teamProject = "System.TeamProject"
        case reason = "System.Reason"
        case createdBy = "System.CreatedBy"
        case changedBy = "System.ChangedBy"
        case resolvedBy = "Microsoft.VSTS.Common.ResolvedBy"
        case resolvedDate = "Microsoft.VSTS.Common.ResolvedDate"
        case closedBy = "Microsoft.VSTS.Common.ClosedBy"
        case closedDate = "Microsoft.VSTS.Common.ClosedDate"
        case stateChangeDate = "Microsoft.VSTS.Common.StateChangeDate"
        case boardColumn = "System.BoardColumn"
        case boardColumnDone = "System.BoardColumnDone"
        case commentCount = "System.CommentCount"
        case remainingWork = "Microsoft.VSTS.Scheduling.RemainingWork"
        case originalEstimate = "Microsoft.VSTS.Scheduling.OriginalEstimate"
        case completedWork = "Microsoft.VSTS.Scheduling.CompletedWork"
        case reproSteps = "Microsoft.VSTS.TCM.ReproSteps"
        case acceptanceCriteria = "Microsoft.VSTS.Common.AcceptanceCriteria"
        case dueDate = "Microsoft.VSTS.Scheduling.DueDate"
    }
}

public struct IdentityRef: Codable {
    public let displayName: String?
    public let uniqueName: String?
    public let id: String?
}

public struct WorkItemQueryResult: Codable {
    public let queryType: String?
    public let queryResultType: String?
    public let asOf: String?
    public let workItems: [WorkItemReference]?
}

public struct WorkItemReference: Codable {
    public let id: Int
    public let url: String?
}

public struct WorkItemBatchResponse: Codable {
    public let count: Int?
    public let value: [WorkItem]?
}

// MARK: - Sprint/Iteration Models

public struct Sprint: Codable {
    public let id: String?
    public let name: String?
    public let path: String?
    public let attributes: SprintAttributes?
    public let url: String?

    public var isCurrent: Bool {
        guard let start = attributes?.startDate,
              let end = attributes?.finishDate else { return false }
        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let startDate = dateFormatter.date(from: start),
              let endDate = dateFormatter.date(from: end) else { return false }
        return now >= startDate && now <= endDate
    }
}

public struct SprintAttributes: Codable {
    public let startDate: String?
    public let finishDate: String?
    public let timeFrame: String?
}

public struct IterationsResponse: Codable {
    public let count: Int?
    public let value: [Sprint]?
}

// MARK: - Board Models

public struct Board: Codable, Identifiable {
    public let id: String?
    public let name: String?
    public let url: String?
}

public struct BoardsResponse: Codable {
    public let count: Int?
    public let value: [Board]?
}

public struct BoardColumnDefinition: Codable, Identifiable {
    public let id: String?
    public let name: String
    public let itemLimit: Int?
    public let columnType: String?
    public let isSplit: Bool?
    public let description: String?
    public let stateMappings: [String: String]?
}

public struct BoardColumnsResponse: Codable {
    public let count: Int?
    public let value: [BoardColumnDefinition]?
}

// MARK: - Work Item Type Models

public struct WorkItemTypeDefinition: Codable {
    public let name: String
    public let description: String?
    public let isDisabled: Bool?
}

public struct WorkItemTypesResponse: Codable {
    public let count: Int?
    public let value: [WorkItemTypeDefinition]?
}

public struct WorkItemTypeState: Codable {
    public let name: String
    public let color: String?
    public let category: String?
}

public struct WorkItemTypeStatesResponse: Codable {
    public let count: Int?
    public let value: [WorkItemTypeState]?
}

// MARK: - Request Models

public struct CreateWorkItemRequest {
    public var title: String
    public var type: String = "Bug"
    public var description: String?
    public var assignedTo: String?
    public var priority: Int?
    public var iterationPath: String?
    public var areaPath: String?
    public var tags: [String]?
    
    public init(
        title: String,
        type: String = "Bug",
        description: String? = nil,
        assignedTo: String? = nil,
        priority: Int? = nil,
        iterationPath: String? = nil,
        areaPath: String? = nil,
        tags: [String]? = nil
    ) {
        self.title = title
        self.type = type
        self.description = description
        self.assignedTo = assignedTo
        self.priority = priority
        self.iterationPath = iterationPath
        self.areaPath = areaPath
        self.tags = tags
    }
}

public struct UpdateWorkItemRequest {
    public var title: String?
    public var state: String?
    public var workItemType: String?
    public var assignedTo: String?
    public var priority: Int?
    public var iterationPath: String?
    public var areaPath: String?
    public var description: String?
    public var tags: String?
    public var comment: String?
    public var remainingWork: Double?
    public var originalEstimate: Double?
    public var completedWork: Double?
    public var reproSteps: String?
    public var acceptanceCriteria: String?
    public var dueDate: String?
    
    public init(
        title: String? = nil,
        state: String? = nil,
        workItemType: String? = nil,
        assignedTo: String? = nil,
        priority: Int? = nil,
        iterationPath: String? = nil,
        areaPath: String? = nil,
        description: String? = nil,
        tags: String? = nil,
        comment: String? = nil,
        remainingWork: Double? = nil,
        originalEstimate: Double? = nil,
        completedWork: Double? = nil,
        reproSteps: String? = nil,
        acceptanceCriteria: String? = nil,
        dueDate: String? = nil
    ) {
        self.title = title
        self.state = state
        self.workItemType = workItemType
        self.assignedTo = assignedTo
        self.priority = priority
        self.iterationPath = iterationPath
        self.areaPath = areaPath
        self.description = description
        self.tags = tags
        self.comment = comment
        self.remainingWork = remainingWork
        self.originalEstimate = originalEstimate
        self.completedWork = completedWork
        self.reproSteps = reproSteps
        self.acceptanceCriteria = acceptanceCriteria
        self.dueDate = dueDate
    }
}

public struct JsonPatchOperation: Codable {
    public var op: String
    public var path: String
    public var value: Any?

    enum CodingKeys: String, CodingKey {
        case op, path, value
    }

    public init(op: String, path: String, value: Any?) {
        self.op = op
        self.path = path
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(op, forKey: .op)
        try container.encode(path, forKey: .path)
        if let stringValue = value as? String {
            try container.encode(stringValue, forKey: .value)
        } else if let intValue = value as? Int {
            try container.encode(intValue, forKey: .value)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        path = try container.decode(String.self, forKey: .path)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}

// MARK: - Work Item Relation Models

public struct WorkItemRelation: Codable {
    public let rel: String?
    public let url: String?
    public let attributes: RelationAttributes?

    /// Common relation type constants
    public var relationType: RelationType {
        switch rel {
        case "System.LinkTypes.Hierarchy-Forward": return .child
        case "System.LinkTypes.Hierarchy-Reverse": return .parent
        case "System.LinkTypes.Related": return .related
        case "System.LinkTypes.Dependency-Forward": return .successor
        case "System.LinkTypes.Dependency-Reverse": return .predecessor
        case let r where r?.contains("ArtifactLink") == true: return .artifact
        default: return .other
        }
    }

    /// Extract work item ID from the relation URL (e.g., "https://.../_apis/wit/workItems/42" → 42)
    public var linkedWorkItemId: Int? {
        guard let url = url else { return nil }
        let parts = url.components(separatedBy: "/")
        return parts.last.flatMap(Int.init)
    }

    public enum RelationType: String {
        case parent, child, related, successor, predecessor, artifact, other
    }
}

public struct RelationAttributes: Codable {
    public let name: String?
    public let comment: String?
    public let isLocked: Bool?
    public let id: Int?
}

// MARK: - Work Item Comment Models

public struct WorkItemComment: Codable, Identifiable {
    public let id: Int
    public let workItemId: Int?
    public let text: String?
    public let renderedText: String?
    public let createdBy: IdentityRef?
    public let createdDate: String?
    public let modifiedBy: IdentityRef?
    public let modifiedDate: String?
    public let version: Int?
    public let reactions: [CommentReaction]?
}

public struct WorkItemCommentsResponse: Codable {
    public let totalCount: Int?
    public let count: Int?
    public let comments: [WorkItemComment]?
}

// MARK: - Comment Reaction Models

/// Azure DevOps comment reaction types
public enum CommentReactionType: String, Codable, CaseIterable {
    case like
    case dislike
    case heart
    case hooray
    case confused
    case thumbsUp
    case thumbsDown

    public var emoji: String {
        switch self {
        case .like, .thumbsUp: return "👍"
        case .dislike, .thumbsDown: return "👎"
        case .heart: return "❤️"
        case .hooray: return "🎉"
        case .confused: return "😕"
        }
    }
}

public struct CommentReaction: Codable {
    public let type: String?
    public let count: Int?
    public let isCurrentUserEngaged: Bool?
}

// MARK: - Classification Node Models

public struct ClassificationNode: Codable {
    public let id: Int?
    public let name: String?
    public let structureType: String?
    public let hasChildren: Bool?
    public let children: [ClassificationNode]?
    public let path: String?
}

// MARK: - Git Repository Models

public struct GitRepository: Codable, Identifiable {
    public let id: String
    public let name: String
    public let url: String?
    public let defaultBranch: String?
    public let project: GitRepoProject?
    public let webUrl: String?

    public struct GitRepoProject: Codable {
        public let id: String?
        public let name: String?
    }
}

public struct GitRepositoriesResponse: Codable {
    public let count: Int?
    public let value: [GitRepository]?
}

public struct GitRef: Codable, Identifiable {
    public let name: String
    public let objectId: String?

    public var id: String { name }

    /// Strips "refs/heads/" prefix to give the short branch name.
    public var shortName: String {
        if name.hasPrefix("refs/heads/") {
            return String(name.dropFirst("refs/heads/".count))
        }
        if name.hasPrefix("refs/tags/") {
            return String(name.dropFirst("refs/tags/".count))
        }
        return name
    }
}

public struct GitRefsResponse: Codable {
    public let count: Int?
    public let value: [GitRef]?
}

public struct GitCommitRef: Codable, Identifiable {
    public let commitId: String
    public let comment: String?
    public let author: GitUserDate?
    public let committer: GitUserDate?
    public let url: String?
    public let remoteUrl: String?

    public var id: String { commitId }

    /// Short commit hash (first 7 characters).
    public var shortId: String { String(commitId.prefix(7)) }
}

public struct GitUserDate: Codable {
    public let name: String?
    public let email: String?
    public let date: String?
}

public struct GitCommitsResponse: Codable {
    public let count: Int?
    public let value: [GitCommitRef]?
}

public struct GitPullRequest: Codable, Identifiable {
    public let pullRequestId: Int
    public let title: String?
    public let status: String?
    public let createdBy: IdentityRef?
    public let creationDate: String?
    public let sourceRefName: String?
    public let targetRefName: String?
    public let url: String?
    public let repository: GitRepository?

    public var id: Int { pullRequestId }

    /// Short source branch name.
    public var sourceBranch: String? {
        sourceRefName.map { ref in
            ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
    }
}

public struct GitPullRequestsResponse: Codable {
    public let count: Int?
    public let value: [GitPullRequest]?
}
