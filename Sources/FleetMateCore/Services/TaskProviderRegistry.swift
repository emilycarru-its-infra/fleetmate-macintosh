import Foundation
import os.log

/// Aggregates tasks from multiple enabled providers.
/// Acts as the central point for unified task operations.
public actor TaskProviderRegistry {
    private var providers: [String: any TaskProvider] = [:]
    private let logger = Logger(subsystem: "com.fleetmate", category: "TaskProviderRegistry")
    
    public init() {}
    
    // MARK: - Provider Registration
    
    /// Registers a task provider.
    /// - Parameter provider: The provider to register.
    public func registerProvider(_ provider: any TaskProvider) async {
        let providerId = await provider.providerId
        let providerName = await provider.providerName
        providers[providerId] = provider
        logger.debug("Registered task provider: \(providerId) (\(providerName))")
    }
    
    /// Gets all registered providers.
    public var allProviders: [any TaskProvider] {
        Array(providers.values)
    }
    
    /// Gets only enabled providers.
    public var enabledProviders: [any TaskProvider] {
        get async {
            var enabled: [any TaskProvider] = []
            for provider in providers.values {
                if await provider.isEnabled {
                    enabled.append(provider)
                }
            }
            return enabled
        }
    }
    
    /// Gets a provider by its ID.
    /// - Parameter providerId: Provider identifier (e.g., "azdevops", "github").
    /// - Returns: The provider, or nil if not found.
    public func getProvider(_ providerId: String) -> (any TaskProvider)? {
        providers[providerId]
    }
    
    // MARK: - Authentication
    
    /// Authenticates all enabled providers.
    /// - Returns: Dictionary of provider ID to authentication result.
    public func authenticateAll() async -> [String: Bool] {
        var results: [String: Bool] = [:]
        
        for provider in await enabledProviders {
            let providerId = await provider.providerId
            do {
                results[providerId] = try await provider.authenticate()
                logger.info("Authenticated with \(providerId): \(results[providerId] ?? false)")
            } catch {
                logger.error("Failed to authenticate with \(providerId): \(error.localizedDescription)")
                results[providerId] = false
            }
        }
        
        return results
    }
    
    // MARK: - Task Operations
    
    /// Lists tasks from all enabled providers (or specific providers).
    /// - Parameters:
    ///   - filter: Optional filter criteria.
    ///   - providerIds: Provider IDs to query. Nil = all enabled providers.
    /// - Returns: Aggregated list of tasks from all queried providers.
    public func listTasks(
        filter: TaskFilter? = nil,
        providerIds: [String]? = nil
    ) async -> [UnifiedTask] {
        let providersToQuery: [any TaskProvider]
        
        if let ids = providerIds {
            providersToQuery = ids.compactMap { getProvider($0) }
        } else {
            providersToQuery = await enabledProviders
        }
        
        // Query providers concurrently
        var allTasks: [UnifiedTask] = []
        
        await withTaskGroup(of: [UnifiedTask].self) { group in
            for provider in providersToQuery {
                group.addTask {
                    do {
                        return try await provider.listTasks(filter: filter)
                    } catch {
                        let providerId = await provider.providerId
                        self.logger.error("Failed to list tasks from \(providerId): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            
            for await tasks in group {
                allTasks.append(contentsOf: tasks)
            }
        }
        
        // Sort by updated date descending (most recent first)
        return allTasks.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    /// Gets a task by its composite key (provider:id).
    /// - Parameter compositeKey: Composite key in format "provider:id".
    /// - Returns: The task, or nil if not found.
    public func getTask(byCompositeKey compositeKey: String) async throws -> UnifiedTask? {
        let parts = compositeKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            logger.warning("Invalid composite key format: \(compositeKey)")
            return nil
        }
        
        let providerId = String(parts[0])
        let taskId = String(parts[1])
        
        guard let provider = getProvider(providerId) else {
            logger.warning("Provider not found: \(providerId)")
            return nil
        }
        
        return try await provider.getTask(taskId: taskId)
    }
    
    /// Creates a task in the specified provider.
    /// - Parameters:
    ///   - providerId: Provider to create the task in.
    ///   - request: Task creation request.
    /// - Returns: The created task.
    public func createTask(
        inProvider providerId: String,
        request: CreateTaskRequest
    ) async throws -> UnifiedTask {
        guard let provider = getProvider(providerId) else {
            throw TaskProviderError.notConfigured
        }
        
        guard await provider.isEnabled else {
            throw TaskProviderError.notConfigured
        }
        
        return try await provider.createTask(request: request)
    }
    
    /// Updates a task by its composite key.
    /// - Parameters:
    ///   - compositeKey: Composite key in format "provider:id".
    ///   - request: Update request.
    /// - Returns: The updated task.
    public func updateTask(
        byCompositeKey compositeKey: String,
        request: UpdateTaskRequest
    ) async throws -> UnifiedTask {
        let parts = compositeKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            throw TaskProviderError.apiError("Invalid composite key format: \(compositeKey)")
        }
        
        let providerId = String(parts[0])
        let taskId = String(parts[1])
        
        guard let provider = getProvider(providerId) else {
            throw TaskProviderError.notConfigured
        }
        
        return try await provider.updateTask(taskId: taskId, request: request)
    }
    
    // MARK: - Bucket & Label Operations
    
    /// Lists all buckets from all enabled providers.
    /// - Returns: Dictionary of provider ID to list of buckets.
    public func listAllBuckets() async -> [String: [TaskBucket]] {
        var results: [String: [TaskBucket]] = [:]
        
        for provider in await enabledProviders {
            let providerId = await provider.providerId
            do {
                results[providerId] = try await provider.listBuckets()
            } catch {
                logger.error("Failed to list buckets from \(providerId): \(error.localizedDescription)")
                results[providerId] = []
            }
        }
        
        return results
    }
    
    /// Lists all labels from all enabled providers.
    /// - Returns: Dictionary of provider ID to list of labels.
    public func listAllLabels() async -> [String: [TaskLabel]] {
        var results: [String: [TaskLabel]] = [:]
        
        for provider in await enabledProviders {
            let providerId = await provider.providerId
            do {
                results[providerId] = try await provider.listLabels()
            } catch {
                logger.error("Failed to list labels from \(providerId): \(error.localizedDescription)")
                results[providerId] = []
            }
        }
        
        return results
    }
}
