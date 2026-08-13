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

    /// Init with an existing service instance (preserves Bearer token from SSO)
    public init(service: AzureDevOpsService, config: FleetMateConfig) {
        self.mainConfig = config
        self.providerConfig = config.tasks?.providers.azdevops
        self.service = service
    }
    
    public func authenticate() async throws -> Bool {
        dbg.info("AzDO TaskProvider authenticate() starting (enabled=\(isEnabled), hasToken=\(service.hasValidToken), org=\(mainConfig.devopsOrganization ?? "nil"), project=\(mainConfig.devopsProject ?? "nil"), baseUrl=\(service.baseUrl))", category: "azdo-provider")
        guard service.hasValidToken else {
            dbg.warn("AzDO TaskProvider: no valid Bearer token — skipping auth", category: "azdo-provider")
            authenticated = false
            return false
        }
        do {
            let ok = try await service.verifyAuth()
            authenticated = ok
            dbg.info("AzDO TaskProvider authenticate \(ok ? "OK" : "FAILED (verifyAuth returned false)")", category: "azdo-provider")
            return ok
        } catch {
            dbg.error("AzDO TaskProvider authenticate FAILED: \(error)", category: "azdo-provider")
            authenticated = false
            return false
        }
    }
    
    public func listTasks(filter: TaskFilter?) async throws -> [UnifiedTask] {
        dbg.info("AzDO TaskProvider listTasks (authenticated=\(authenticated), hasToken=\(service.hasValidToken))", category: "azdo-provider")
        guard service.hasValidToken else {
            dbg.warn("AzDO TaskProvider listTasks: no token, returning empty", category: "azdo-provider")
            return []
        }
        // Query across ALL projects in the org (org-level WIQL)
        var conditions: [String] = []
        
        // Build filter conditions
        if let filter = filter {
            if let states = filter.states, !states.isEmpty {
                let stateConditions = states.map { "[System.State] = '\(escapeWiql(mapStateToAdo($0)))'" }
                conditions.append("(\(stateConditions.joined(separator: " OR ")))")
            } else if !filter.includeClosed {
                conditions.append("[System.State] <> 'Closed'")
                conditions.append("[System.State] <> 'Done'")
                conditions.append("[System.State] <> 'Removed'")
            }
            
            if let assignees = filter.assignees, !assignees.isEmpty {
                let assigneeConditions = assignees.map { "[System.AssignedTo] = '\(escapeWiql($0))'" }
                conditions.append("(\(assigneeConditions.joined(separator: " OR ")))")
            }
            
            if let labels = filter.labels, !labels.isEmpty {
                for label in labels {
                    conditions.append("[System.Tags] CONTAINS '\(escapeWiql(label))'")
                }
            }
            
            if let bucket = filter.bucket {
                conditions.append("[System.IterationPath] UNDER '\(escapeWiql(bucket))'")
            }
            
            if let searchText = filter.searchText {
                conditions.append("[System.Title] CONTAINS '\(escapeWiql(searchText))'")
            }
        } else {
            // Default: exclude closed
            conditions.append("[System.State] <> 'Closed'")
            conditions.append("[System.State] <> 'Done'")
            conditions.append("[System.State] <> 'Removed'")
        }
        
        let whereClause = conditions.isEmpty ? "" : " WHERE \(conditions.joined(separator: " AND "))"
        let wiql = "SELECT [System.Id] FROM WorkItems\(whereClause) ORDER BY [System.ChangedDate] DESC"
        
        // Use org-level endpoint to query across all projects
        var workItems = try await service.queryWorkItems(wiql, orgLevel: true)
        
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
        workItem.asUnifiedTask()
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
    
    /// Escape a value for safe inclusion in a WIQL single-quoted string literal.
    private func escapeWiql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

// Type alias to avoid ambiguity with our UpdateTaskRequest
typealias DevOpsUpdateWorkItemRequest = UpdateWorkItemRequest
