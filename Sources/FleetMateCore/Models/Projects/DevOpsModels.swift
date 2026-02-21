import Foundation

// MARK: - Work Item Models

public struct WorkItem: Codable, Identifiable {
    public let id: Int
    public let rev: Int?
    public let fields: WorkItemFields?
    public let url: String?
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

public struct Board: Codable {
    public let id: String?
    public let name: String?
    public let url: String?
}

public struct BoardsResponse: Codable {
    public let count: Int?
    public let value: [Board]?
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
    public var assignedTo: String?
    public var priority: Int?
    public var iterationPath: String?
    public var comment: String?
    
    public init(
        title: String? = nil,
        state: String? = nil,
        assignedTo: String? = nil,
        priority: Int? = nil,
        iterationPath: String? = nil,
        comment: String? = nil
    ) {
        self.title = title
        self.state = state
        self.assignedTo = assignedTo
        self.priority = priority
        self.iterationPath = iterationPath
        self.comment = comment
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
