import Foundation

// MARK: - Work Item Models

struct WorkItem: Codable {
    let id: Int
    let rev: Int?
    let fields: WorkItemFields?
    let url: String?
}

struct WorkItemFields: Codable {
    let title: String?
    let state: String?
    let workItemType: String?
    let assignedTo: IdentityRef?
    let createdDate: String?
    let changedDate: String?
    let description: String?
    let priority: Int?
    let iterationPath: String?
    let areaPath: String?
    let tags: String?

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

struct IdentityRef: Codable {
    let displayName: String?
    let uniqueName: String?
    let id: String?
}

struct WorkItemQueryResult: Codable {
    let queryType: String?
    let queryResultType: String?
    let asOf: String?
    let workItems: [WorkItemReference]?
}

struct WorkItemReference: Codable {
    let id: Int
    let url: String?
}

struct WorkItemBatchResponse: Codable {
    let count: Int?
    let value: [WorkItem]?
}

// MARK: - Sprint/Iteration Models

struct Sprint: Codable {
    let id: String?
    let name: String?
    let path: String?
    let attributes: SprintAttributes?
    let url: String?

    var isCurrent: Bool {
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

struct SprintAttributes: Codable {
    let startDate: String?
    let finishDate: String?
    let timeFrame: String?
}

struct IterationsResponse: Codable {
    let count: Int?
    let value: [Sprint]?
}

// MARK: - Board Models

struct Board: Codable {
    let id: String?
    let name: String?
    let url: String?
}

struct BoardsResponse: Codable {
    let count: Int?
    let value: [Board]?
}

// MARK: - Request Models

struct CreateWorkItemRequest {
    var title: String
    var type: String = "Bug"
    var description: String?
    var assignedTo: String?
    var priority: Int?
    var iterationPath: String?
    var areaPath: String?
    var tags: [String]?
}

struct UpdateWorkItemRequest {
    var title: String?
    var state: String?
    var assignedTo: String?
    var priority: Int?
    var iterationPath: String?
    var comment: String?
}

struct JsonPatchOperation: Codable {
    var op: String
    var path: String
    var value: Any?

    enum CodingKeys: String, CodingKey {
        case op, path, value
    }

    init(op: String, path: String, value: Any?) {
        self.op = op
        self.path = path
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        path = try container.decode(String.self, forKey: .path)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}
