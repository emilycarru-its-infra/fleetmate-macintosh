import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct TasksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasks",
        abstract: "Unified task management across all providers",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            CreateSubcommand.self,
            UpdateSubcommand.self,
            BucketsSubcommand.self,
            LabelsSubcommand.self,
            SyncSubcommand.self,
            ProvidersSubcommand.self
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - List Tasks

extension TasksCommand {
    struct ListSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List tasks from all providers"
        )

        @Option(name: .shortAndLong, help: "Filter by provider (github, gitea, azdo)")
        var provider: String?

        @Option(name: .shortAndLong, help: "Filter by state (open, in-progress, closed)")
        var state: String?

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Filter by label(s)")
        var label: [String] = []

        @Option(name: .shortAndLong, help: "Filter by bucket/milestone")
        var bucket: String?

        @Option(name: .shortAndLong, help: "Filter by assignee")
        var assignee: String?

        @Option(name: .shortAndLong, help: "Search in title/description")
        var query: String?

        @Option(name: .shortAndLong, help: "Maximum results per provider")
        var limit: Int = 50

        @Flag(name: .long, help: "Include closed tasks")
        var closed: Bool = false

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            let enabledProviders = await registry.enabledProviders
            guard !enabledProviders.isEmpty else {
                print("No task providers are configured and enabled.".yellow)
                return
            }

            var filter = TaskFilter()
            filter.searchText = query
            filter.bucket = bucket
            filter.limit = limit
            filter.includeClosed = closed

            if let state = state {
                filter.states = parseStates(state)
            }
            if !label.isEmpty {
                filter.labels = label
            }
            if let assignee = assignee {
                filter.assignees = [assignee]
            }

            let tasks: [UnifiedTask]
            if let provider = provider {
                tasks = await registry.listTasks(filter: filter, providerIds: [provider])
            } else {
                tasks = await registry.listTasks(filter: filter)
            }

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(tasks)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if tasks.isEmpty {
                print("No tasks found.".dim)
                return
            }

            // Print table header
            let header = String(format: "%-10s %-6s %-50s %-12s %-15s",
                               "Provider", "ID", "Title", "State", "Bucket")
            print(header.bold)
            print(String(repeating: "-", count: 95))

            for task in tasks.sorted(by: { ($0.state.rawValue, $0.provider) < ($1.state.rawValue, $1.provider) }) {
                let title = task.title.count > 47 ? String(task.title.prefix(47)) + "..." : task.title
                let stateStr: String
                switch task.state {
                case .open: stateStr = "Open".green
                case .inProgress: stateStr = "In Progress".blue
                case .closed: stateStr = "Closed".dim
                }

                let row = String(format: "%-10s %-6s %-50s %-12s %-15s",
                               task.provider.cyan,
                               task.id,
                               title,
                               stateStr,
                               task.bucket ?? "-")
                print(row)
            }

            print("\nTotal: \(tasks.count) tasks".dim)
        }
    }
}

// MARK: - Show Task

extension TasksCommand {
    struct ShowSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show task details"
        )

        @Argument(help: "Provider (github, gitea, azdo)")
        var provider: String

        @Argument(help: "Task ID")
        var id: String

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            guard let task = try await registry.getTask(byCompositeKey: "\(provider):\(id)") else {
                print("Task \(provider)#\(id) not found".red)
                throw ExitCode.failure
            }

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(task)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            print("\n\(provider)#\(id)".bold.cyan)
            print(String(repeating: "=", count: 60))
            print("Title:".bold + " " + task.title)
            print("State:".bold + " " + "\(task.state)")
            print("Provider:".bold + " " + task.provider)
            print("Bucket:".bold + " " + (task.bucket ?? "-"))
            print("Assignees:".bold + " " + (task.assignees.isEmpty ? "-" : task.assignees.joined(separator: ", ")))
            print("Labels:".bold + " " + (task.labels.isEmpty ? "-" : task.labels.joined(separator: ", ")))
            print("Priority:".bold + " " + (task.priority.map(String.init) ?? "-"))

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            if let dueDate = task.dueDate {
                print("Due:".bold + " " + dateFormatter.string(from: dueDate))
            }
            print("Created:".bold + " " + dateFormatter.string(from: task.createdAt))
            print("Updated:".bold + " " + dateFormatter.string(from: task.updatedAt))
            if let url = task.externalUrl {
                print("URL:".bold + " " + url)
            }

            print("\nDescription:".bold)
            print(task.description ?? "(no description)")
        }
    }
}

// MARK: - Create Task

extension TasksCommand {
    struct CreateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new task"
        )

        @Argument(help: "Provider (github, gitea, azdo)")
        var provider: String

        @Option(name: .shortAndLong, help: "Task title")
        var title: String

        @Option(name: .shortAndLong, help: "Task description")
        var description: String?

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Labels")
        var label: [String] = []

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Assignees")
        var assignee: [String] = []

        @Option(name: .shortAndLong, help: "Bucket/milestone")
        var bucket: String?

        @Option(name: .shortAndLong, help: "Priority (1=highest, 4=lowest)")
        var priority: Int?

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            let request = CreateTaskRequest(
                title: title,
                description: description,
                assignees: assignee.isEmpty ? nil : assignee,
                labels: label.isEmpty ? nil : label,
                bucket: bucket,
                priority: priority
            )

            let task = try await registry.createTask(inProvider: provider, request: request)
            print("Created task \(task.provider)#\(task.id):".green + " " + task.title)
            if let url = task.externalUrl {
                print(url.dim)
            }
        }
    }
}

// MARK: - Update Task

extension TasksCommand {
    struct UpdateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Update an existing task"
        )

        @Argument(help: "Provider")
        var provider: String

        @Argument(help: "Task ID")
        var id: String

        @Option(name: .shortAndLong, help: "New title")
        var title: String?

        @Option(name: .shortAndLong, help: "New state (open, in-progress, closed)")
        var state: String?

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Replace labels")
        var label: [String] = []

        @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Replace assignees")
        var assignee: [String] = []

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            var request = UpdateTaskRequest()
            request.title = title
            request.labels = label.isEmpty ? nil : label
            request.assignees = assignee.isEmpty ? nil : assignee

            if let state = state {
                request.state = parseState(state)
            }

            let task = try await registry.updateTask(byCompositeKey: "\(provider):\(id)", request: request)
            print("Updated".green + " \(task.provider)#\(task.id): \(task.title)")
        }

        private func parseState(_ state: String) -> TaskState {
            switch state.lowercased() {
            case "closed", "done", "resolved": return .closed
            case "in-progress", "inprogress", "active": return .inProgress
            default: return .open
            }
        }
    }
}

// MARK: - Buckets

extension TasksCommand {
    struct BucketsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "buckets",
            abstract: "List available buckets/milestones"
        )

        @Option(name: .shortAndLong, help: "Filter by provider")
        var provider: String?

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            var allBuckets: [String: [TaskBucket]] = [:]

            for p in await registry.allProviders {
                let providerId = await p.providerId
                if let provider = provider, providerId != provider { continue }
                
                let buckets = try await p.listBuckets()
                allBuckets[providerId] = buckets
            }

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(allBuckets)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            for (providerId, buckets) in allBuckets.sorted(by: { $0.key < $1.key }) {
                print("\(providerId)".bold.cyan)
                for bucket in buckets {
                    print("  \(bucket.name) (\(bucket.id))".dim)
                }
            }
        }
    }
}

// MARK: - Labels

extension TasksCommand {
    struct LabelsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "labels",
            abstract: "List available labels"
        )

        @Option(name: .shortAndLong, help: "Filter by provider")
        var provider: String?

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            var allLabels: [String: [TaskLabel]] = [:]

            for p in await registry.allProviders {
                let providerId = await p.providerId
                if let provider = provider, providerId != provider { continue }
                
                let labels = try await p.listLabels()
                allLabels[providerId] = labels
            }

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(allLabels)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            for (providerId, labels) in allLabels.sorted(by: { $0.key < $1.key }) {
                print("\(providerId)".bold.cyan)
                for label in labels {
                    print("  ● \(label.name)")
                }
            }
        }
    }
}

// MARK: - Sync

extension TasksCommand {
    struct SyncSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Sync tasks to external destinations"
        )

        @Flag(name: .long, help: "Sync to Microsoft Planner")
        var planner: Bool = false

        @Flag(name: .long, help: "Sync to/from markdown file")
        var markdown: Bool = false

        @Flag(name: .long, help: "Show what would be synced without making changes")
        var dryRun: Bool = false

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            var filter = TaskFilter()
            filter.includeClosed = false
            let tasks = await registry.listTasks(filter: filter)

            if dryRun {
                print("Dry run:".yellow + " Would sync \(tasks.count) tasks")
                for task in tasks.prefix(10) {
                    print("  - \(task.provider)#\(task.id): \(task.title)")
                }
                if tasks.count > 10 {
                    print("  ... and \(tasks.count - 10) more".dim)
                }
                return
            }

            if planner {
                let plannerService = PlannerSyncService(config: config)
                guard await plannerService.isEnabled else {
                    print("Planner sync not configured".yellow)
                    return
                }
                
                guard try await plannerService.authenticate() else {
                    print("Failed to authenticate with Planner".red)
                    return
                }
                
                let result = try await plannerService.syncTasks(tasks)
                print(result.success ? result.message.green : result.message.red)
            }

            if markdown {
                let mdService = MarkdownSyncService(config: config)
                guard await mdService.isEnabled else {
                    print("Markdown sync not configured".yellow)
                    return
                }
                
                let result = try await mdService.syncBidirectional(providerTasks: tasks)
                print(result.success ? result.message.green : result.message.red)
            }

            if !planner && !markdown {
                print("Specify --planner or --markdown to sync".yellow)
            }
        }
    }
}

// MARK: - Providers

extension TasksCommand {
    struct ProvidersSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "providers",
            abstract: "List configured task providers"
        )

        func run() async throws {
            let config = try FleetMateConfig.load()
            let registry = try await createRegistry(config: config)

            print("\nProvider".bold.padded(to: 12) + "Name".bold.padded(to: 15) + "Status".bold.padded(to: 12) + "Auth".bold)
            print(String(repeating: "-", count: 50))

            for provider in await registry.allProviders {
                let providerId = await provider.providerId
                let providerName = await provider.providerName
                let isEnabled = await provider.isEnabled
                
                let status = isEnabled ? "Enabled".green : "Disabled".dim
                var auth = "-".dim
                
                if isEnabled {
                    let authenticated = try await provider.authenticate()
                    auth = authenticated ? "Yes".green : "No".red
                }

                print(providerId.padded(to: 12) + providerName.padded(to: 15) + status.padded(to: 12) + auth)
            }
        }
    }
}

// MARK: - Helpers

private func createRegistry(config: FleetMateConfig) async throws -> TaskProviderRegistry {
    let registry = TaskProviderRegistry()

    let azdo = AzureDevOpsTaskProvider(config: config)
    let github = GitHubProjectsTaskProvider(config: config.tasks?.providers.github ?? GitHubProviderConfig())
    let gitea = GiteaTaskProvider(config: config)

    await registry.registerProvider(azdo)
    await registry.registerProvider(github)
    await registry.registerProvider(gitea)

    // Use the registry's built-in authenticateAll() which isolates per-provider failures
    let authResults = await registry.authenticateAll()
    for (id, success) in authResults {
        if !success {
            print("Warning: Provider \(id) auth failed (non-fatal)")
        }
    }

    return registry
}

private func parseStates(_ state: String) -> [TaskState]? {
    switch state.lowercased() {
    case "open": return [.open]
    case "in-progress", "inprogress", "active": return [.inProgress]
    case "closed", "done", "resolved": return [.closed]
    case "all": return [.open, .inProgress, .closed]
    default: return nil
    }
}

private extension String {
    func padded(to length: Int) -> String {
        if count >= length { return self }
        return self + String(repeating: " ", count: length - count)
    }
}
