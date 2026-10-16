import Foundation

public struct TdxTicketTask: Decodable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let ticketId: Int
    public let title: String
    public let description: String?
    public let typeId: Int
    public let percentComplete: Int
    public let isActive: Bool
    public let estimatedMinutes: Int
    public let actualMinutes: Int?
    public let startDate: String?
    public let endDate: String?
    public let completeWithinMinutes: Int?
    public let predecessorId: Int
    public let predecessorTitle: String?
    public let responsibleUid: String?
    public let responsibleFullName: String?
    public let responsibleGroupId: Int
    public let responsibleGroupName: String?
    public let notifyResponsible: Bool
    public let modifiedDate: String?
    public let completedDate: String?
    public let completedFullName: String?

    public var isStandard: Bool { typeId == 1 }
    public var typeLabel: String {
        switch typeId {
        case 1: return "Task"
        case 2: return "Maintenance activity"
        case 3: return "Workflow task"
        default: return "Activity"
        }
    }

    public var editableValues: TdxTaskValues {
        .init(title: title, description: description, estimatedMinutes: estimatedMinutes,
              startDate: startDate, endDate: endDate, completeWithinMinutes: completeWithinMinutes,
              predecessorId: predecessorId, responsibleUid: responsibleUid,
              responsibleGroupId: responsibleGroupId, notifyResponsible: notifyResponsible)
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", ticketId = "TicketID", title = "Title", description = "Description"
        case typeId = "TypeID", percentComplete = "PercentComplete", isActive = "IsActive"
        case estimatedMinutes = "EstimatedMinutes", actualMinutes = "ActualMinutes"
        case startDate = "StartDate", endDate = "EndDate", completeWithinMinutes = "CompleteWithinMinutes"
        case predecessorId = "PredecessorID", predecessorTitle = "PredecessorTitle"
        case responsibleUid = "ResponsibleUid", responsibleFullName = "ResponsibleFullName"
        case responsibleGroupId = "ResponsibleGroupID", responsibleGroupName = "ResponsibleGroupName"
        case notifyResponsible = "NotifyResponsible", modifiedDate = "ModifiedDate"
        case completedDate = "CompletedDate", completedFullName = "CompletedFullName"
    }
}

/// Only writable task properties. Progress is updated through the task feed.
public struct TdxTaskValues: Encodable, Sendable, Equatable {
    public var title: String
    public var description: String?
    public var estimatedMinutes: Int
    public var startDate: String?
    public var endDate: String?
    public var completeWithinMinutes: Int?
    public var predecessorId: Int
    public var responsibleUid: String?
    public var responsibleGroupId: Int
    public var notifyResponsible: Bool

    public init(title: String = "", description: String? = nil, estimatedMinutes: Int = 0,
                startDate: String? = nil, endDate: String? = nil, completeWithinMinutes: Int? = nil,
                predecessorId: Int = 0, responsibleUid: String? = nil,
                responsibleGroupId: Int = 0, notifyResponsible: Bool = true) {
        self.title = title
        self.description = description
        self.estimatedMinutes = estimatedMinutes
        self.startDate = startDate
        self.endDate = endDate
        self.completeWithinMinutes = completeWithinMinutes
        self.predecessorId = predecessorId
        self.responsibleUid = responsibleUid
        self.responsibleGroupId = responsibleGroupId
        self.notifyResponsible = notifyResponsible
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              estimatedMinutes >= 0, predecessorId >= 0, responsibleGroupId >= 0,
              completeWithinMinutes.map({ $0 >= 0 }) ?? true else {
            throw TdxWorkflowError.actionFailed("Enter a title of up to 300 characters and nonnegative task durations.")
        }
        func date(_ raw: String?) throws -> Date? {
            guard let raw else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw TdxWorkflowError.actionFailed("Enter a valid task date.")
            }
            return date
        }
        if let start = try date(startDate), let end = try date(endDate), start > end {
            throw TdxWorkflowError.actionFailed("The end date must be on or after the start date.")
        }
    }

    enum CodingKeys: String, CodingKey {
        case title = "Title", description = "Description", estimatedMinutes = "EstimatedMinutes"
        case startDate = "StartDate", endDate = "EndDate", completeWithinMinutes = "CompleteWithinMinutes"
        case predecessorId = "PredecessorID", responsibleUid = "ResponsibleUid"
        case responsibleGroupId = "ResponsibleGroupID", notifyResponsible = "NotifyResponsible"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(estimatedMinutes, forKey: .estimatedMinutes)
        try c.encode(startDate, forKey: .startDate)
        try c.encode(endDate, forKey: .endDate)
        try c.encode(completeWithinMinutes, forKey: .completeWithinMinutes)
        try c.encode(predecessorId, forKey: .predecessorId)
        try c.encode(responsibleUid, forKey: .responsibleUid)
        try c.encode(responsibleGroupId, forKey: .responsibleGroupId)
        try c.encode(notifyResponsible, forKey: .notifyResponsible)
    }
}

public struct TdxTaskUpdate: Encodable, Sendable {
    public let percentComplete: Int?
    public let comments: String
    public let isPrivate: Bool
    public let isRichHtml = false
    public let notify: [String] = []

    public init(percentComplete: Int? = nil, comments: String = "", isPrivate: Bool = false) {
        self.percentComplete = percentComplete
        self.comments = comments
        self.isPrivate = isPrivate
    }

    public func validate() throws {
        guard percentComplete.map({ (0...100).contains($0) }) ?? true,
              percentComplete != nil || !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TdxWorkflowError.actionFailed("Enter a comment or progress between 0 and 100 percent.")
        }
    }

    enum CodingKeys: String, CodingKey {
        case percentComplete = "PercentComplete", comments = "Comments", isPrivate = "IsPrivate"
        case isRichHtml = "IsRichHtml", notify = "Notify"
    }
}

public struct TdxTaskTemplateRequest: Encodable, Sendable {
    public let taskTemplateId: Int
    public let removeExistingTasks: Bool
    public let startDateSource: Int

    public init(taskTemplateId: Int, removeExistingTasks: Bool = false, startDateSource: Int = 0) {
        self.taskTemplateId = taskTemplateId
        self.removeExistingTasks = removeExistingTasks
        self.startDateSource = startDateSource
    }

    enum CodingKeys: String, CodingKey {
        case taskTemplateId = "TaskTemplateId", removeExistingTasks = "RemoveExistingTasks", startDateSource = "StartDateSource"
    }
}
