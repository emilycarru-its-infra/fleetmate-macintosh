import Foundation

/// Wire shapes from TeamDynamix's TicketWorkflow OpenAPI schema.
public struct TdxWorkflow: Decodable, Sendable {
    public let id: Int
    public let name: String?
    public let isComplete: Bool
    public let status: Int
    public let currentStepIds: [UUID]?
    public let steps: [TdxWorkflowStep]?

    public var activeSteps: [TdxWorkflowStep] {
        guard !isComplete else { return [] }
        let current = Set(currentStepIds ?? [])
        return (steps ?? []).filter { $0.isCurrent || current.contains($0.id) }
    }

    public var statusLabel: String {
        switch status {
        case 1: return "Approved"
        case 2: return "Rejected"
        default: return isComplete ? "Complete" : "In progress"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", isComplete = "IsComplete", status = "Status"
        case currentStepIds = "CurrentStepIDs", steps = "Steps"
    }
}

public struct TdxWorkflowStep: Decodable, Identifiable, Sendable {
    public let id: UUID
    public let name: String?
    public let description: String?
    public let typeName: String?
    public let isCurrent: Bool
    public let isInError: Bool

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", description = "Description", typeName = "TypeName"
        case isCurrent = "IsCurrent", isInError = "IsInError"
    }
}

public struct TdxWorkflowAction: Decodable, Identifiable, Sendable {
    /// Opaque string: this is neither a numeric ID nor necessarily a GUID.
    public let id: String
    public let name: String?
    public let tooltip: String?

    public var label: String {
        guard let name, !name.isEmpty else { return "Perform action" }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "Name", tooltip = "Tooltip"
    }
}

public struct TdxWorkflowActionRequest: Encodable, Sendable {
    public let stepId: UUID
    public let actionId: String
    public let comments: String?

    public init(stepId: UUID, actionId: String, comments: String? = nil) {
        self.stepId = stepId
        self.actionId = actionId
        self.comments = comments
    }

    enum CodingKeys: String, CodingKey {
        case stepId = "StepID", actionId = "ActionID", comments = "Comments"
    }
}

public struct TdxWorkflowActionResult: Decodable, Sendable {
    public let isSuccessful: Bool
    public let message: String?
    public let errors: [TdxWorkflowValidationMessage]?
    public let wasWorkflowUpdated: Bool

    public func validate() throws {
        guard isSuccessful else {
            let messages = ([message] + (errors ?? []).map { $0.message })
                .compactMap { $0 }.filter { !$0.isEmpty }
            throw TdxWorkflowError.actionFailed(messages.isEmpty
                ? "TeamDynamix did not accept this action. Refresh the workflow and try again."
                : messages.joined(separator: "\n"))
        }
    }

    enum CodingKeys: String, CodingKey {
        case isSuccessful = "IsSuccessful", message = "Message", errors = "Errors"
        case wasWorkflowUpdated = "WasWorkflowUpdated"
    }
}

public struct TdxWorkflowValidationMessage: Decodable, Sendable {
    public let message: String?
    enum CodingKeys: String, CodingKey { case message = "Message" }
}

public enum TdxWorkflowError: LocalizedError {
    case actionFailed(String)
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .actionFailed(let message): return message
        case .requestFailed(401): return "Your TeamDynamix session has expired. Sign in again."
        case .requestFailed(403): return "You don't have permission for this workflow operation."
        case .requestFailed(404): return "This ticket or workflow is no longer available. Refresh the ticket."
        case .requestFailed(let status): return "TeamDynamix could not complete the workflow request (HTTP \(status)). Refresh and try again."
        }
    }
}
