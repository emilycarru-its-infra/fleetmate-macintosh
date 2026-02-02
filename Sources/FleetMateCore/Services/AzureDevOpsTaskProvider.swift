import Foundation

/// Azure DevOps task provider that wraps AzureDevOpsService.
/// Implements TaskProvider protocol for unified task management.
public actor AzureDevOpsTaskProvider: TaskProvider {
    private let service: AzureDevOpsService
    private let providerConfig: AzureDevOpsProviderConfig?
    private let mainConfig: FleetMateConfig
    private var authenticated: Bool = false
    
    public nonisolated let providerId: String = "azdevops"
    public nonisolated let providerName: String = "Azure DevOps"
    
    public var isEnabled: Bool {
        providerConfig?.enabled ?? mainConfig.isDevOpsConfigured
    }
    
    public init(config: FleetMateConfig) {
        self.mainConfig = config
        self.providerConfig = config.tasks?.providers.azdevops
        self.service = AzureDevOpsService(config: config)
    }
    
    public func authenticate() async throws -> Bool {
        // Try a simple query to verify auth works
        do {
            _ = try await service.getSprints()
            authenticated = true
            print("Authenticated with Azure DevOps: \(mainConfig.devopsOrganization ?? "")/\(mainConfig.devopsProject ?? "")")
            return true
        } catch {
            print("Failed to authenticate with Azure DevOps: \(error)")
            authenticated = false
            return false
        }
    }
    
    public func listTasks(filter: TaskFilter?) async throws -> [UnifiedTask] {
        var conditions = ["[System.TeamProject] = @project"]
        
        // Build filter conditions
        if let filter = filter {
            if let states = filter.states, !states.isEmpty {
                let stateConditions = states.map { "[System.State] = '\(mapStateToAdo($0))'" }
                conditions.append("(\(stateConditions.joined(separator: " OR ")))")
            } else if !filter.includeClosed {
                conditions.append("[System.State] <> 'Closed'")
                conditions.append("[System.State] <> 'Done'")
                conditions.append("[System.State] <> 'Removed'")
            }
            
            if let assignees = filter.assignees, !assignees.isEmpty {
                let assigneeConditions = assignees.map { "[System.AssignedTo] = '\($0)'" }
                conditions.append("(\(assigneeConditions.joined(separator: " OR ")))")
            }
            
            if let labels = filter.labels, !labels.isEmpty {
                for label in labels {
                    conditions.append("[System.Tags] CONTAINS '\(label)'")
                }
            }
            
            if let bucket = filter.bucket {
                conditions.append("[System.IterationPath] UNDER '\(bucket)'")
            }
            
            if let searchText = filter.searchText {
                conditions.append("[System.Title] CONTAINS '\(searchText)'")
            }
        } else {
            // Default: exclude closed
            conditions.append("[System.State] <> 'Closed'")
            conditions.append("[System.State] <> 'Done'")
            conditions.append("[System.State] <> 'Removed'")
        }
        
        let wiql = "SELECT [System.Id] FROM WorkItems WHERE \(conditions.joined(separator: " AND ")) ORDER BY [System.ChangedDate] DESC"
        
        var workItems = try await service.queryWorkItems(wiql)
        
        if let limit = filter?.limit, limit > 0 {
            workItems = Array(workItems.prefix(limit))
        }
        
        return workItems.map { mapToUnifiedTask($0) }
    }
    
    public func getTask(taskId: String) async throws -> UnifiedTask? {
        guard let id = Int(taskId) else {
            print("Invalid Azure DevOps work item ID: \(taskId)")
            return nil
        }
        
        guard let workItem = try await service.getWorkItem(id: id) else {
            return nil
        }
        
        return mapToUnifiedTask(workItem)
    }
    
    public func createTask(request: CreateTaskRequest) async throws -> UnifiedTask {
        let adoRequest = CreateWorkItemRequest(
            title: request.title,
            type: providerConfig?.defaultWorkItemType ?? mainConfig.devopsDefaultWorkItemType,
            description: request.description,
            assignedTo: request.assignees?.first,
            priority: request.priority,
            iterationPath: request.bucket,
            areaPath: providerConfig?.areaPath,
            tags: request.labels
        )
        
        guard let workItem = try await service.createWorkItem(adoRequest) else {
            throw TaskProviderError.apiError("Failed to create work item in Azure DevOps")
        }
        
        return mapToUnifiedTask(workItem)
    }
    
    public func updateTask(taskId: String, request: UpdateTaskRequest) async throws -> UnifiedTask {
        guard let id = Int(taskId) else {
            throw TaskProviderError.apiError("Invalid Azure DevOps work item ID: \(taskId)")
        }
        
        let adoRequest = DevOpsUpdateWorkItemRequest(
            title: request.title,
            state: request.state.map { mapStateToAdo($0) },
            assignedTo: request.assignees?.first,
            priority: request.priority,
            iterationPath: request.bucket
        )
        
        guard let workItem = try await service.updateWorkItem(id: id, request: adoRequest) else {
            throw TaskProviderError.apiError("Failed to update work item \(taskId) in Azure DevOps")
        }
        
        return mapToUnifiedTask(workItem)
    }
    
    public func deleteTask(taskId: String) async throws -> Bool {
        // Azure DevOps doesn't typically support direct deletion via API
        // Instead, we set the state to "Removed"
        guard let id = Int(taskId) else {
            return false
        }
        
        let request = DevOpsUpdateWorkItemRequest(state: "Removed")
        let result = try await service.updateWorkItem(id: id, request: request)
        return result != nil
    }
    
    public func listBuckets() async throws -> [TaskBucket] {
        let sprints = try await service.getSprints()
        
        return sprints.enumerated().map { index, sprint in
            TaskBucket(
                id: sprint.path ?? sprint.name ?? "Unknown",
                name: sprint.name ?? "Unknown",
                order: index
            )
        }
    }
    
    public func listLabels() async throws -> [TaskLabel] {
        // Azure DevOps doesn't have a dedicated labels API
        // Tags are free-form text on work items
        return []
    }
    
    // MARK: - Mapping Helpers
    
    private func mapToUnifiedTask(_ workItem: WorkItem) -> UnifiedTask {
        let fields = workItem.fields
        
        // Parse date strings to Date objects
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let createdDate: Date = {
            if let dateStr = fields?.createdDate {
                return dateFormatter.date(from: dateStr) ?? Date.distantPast
            }
            return Date.distantPast
        }()
        
        let changedDate: Date = {
            if let dateStr = fields?.changedDate {
                return dateFormatter.date(from: dateStr) ?? Date.distantPast
            }
            return Date.distantPast
        }()
        
        // Extract assignee display name from IdentityRef
        let assigneeList: [String] = {
            if let assignedTo = fields?.assignedTo {
                return [assignedTo.displayName ?? assignedTo.uniqueName ?? ""]
            }
            return []
        }()
        
        return UnifiedTask(
            id: String(workItem.id),
            provider: providerId,
            title: fields?.title ?? "",
            description: fields?.description,
            state: mapStateFromAdo(fields?.state ?? "New"),
            assignees: assigneeList,
            labels: parseTags(fields?.tags),
            bucket: fields?.iterationPath,
            dueDate: nil,
            createdAt: createdDate,
            updatedAt: changedDate,
            closedAt: nil,
            externalUrl: workItem.url?.replacingOccurrences(of: "_apis/wit/workItems", with: "_workitems/edit"),
            priority: fields?.priority
        )
    }
    
    private func mapStateFromAdo(_ adoState: String) -> TaskState {
        switch adoState.lowercased() {
        case "new", "to do", "proposed":
            return .open
        case "active", "in progress", "doing", "committed":
            return .inProgress
        case "closed", "done", "resolved", "completed", "removed":
            return .closed
        default:
            return .open
        }
    }
    
    private func mapStateToAdo(_ state: TaskState) -> String {
        switch state {
        case .open:
            return "New"
        case .inProgress:
            return "Active"
        case .closed:
            return "Closed"
        }
    }
    
    private func parseTags(_ tags: String?) -> [String] {
        guard let tags = tags, !tags.isEmpty else {
            return []
        }
        
        return tags.components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// Type alias to avoid ambiguity with our UpdateTaskRequest
typealias DevOpsUpdateWorkItemRequest = UpdateWorkItemRequest
