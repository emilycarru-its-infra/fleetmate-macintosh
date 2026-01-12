import ArgumentParser
import Foundation
import Rainbow

struct DevOpsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devops",
        abstract: "Query Azure DevOps work items",
        subcommands: [
            ItemsSubcommand.self,
            ItemSubcommand.self,
            CreateItemSubcommand.self,
            UpdateItemSubcommand.self,
            SprintsSubcommand.self,
            BoardsSubcommand.self,
            FromErrorSubcommand.self
        ],
        defaultSubcommand: ItemsSubcommand.self
    )
}

// MARK: - List Items

struct ItemsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "items",
        abstract: "List work items"
    )

    @Option(name: .shortAndLong, help: "Filter by state (Active, Resolved, Closed)")
    var state: String?

    @Option(name: .shortAndLong, help: "Filter by type (Bug, Task, User Story)")
    var type: String?

    @Option(name: .shortAndLong, help: "Filter by assignee")
    var assignee: String?

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured. Set DEVOPS_ORGANIZATION and DEVOPS_PROJECT.".red)
            throw ExitCode.failure
        }

        let items = try await service.getWorkItems(state: state, type: type, assignedTo: assignee, limit: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printItemsTable(items)
        }
    }

    private func printItemsTable(_ items: [WorkItem]) {
        print("\n" + "Azure DevOps Work Items".bold + " (\(items.count) shown)\n")

        let header = String(format: "%-8s %-12s %-12s %-40s %-15s",
            "ID", "Type", "State", "Title", "Assigned To")
        print(header.underline)

        for item in items {
            let fields = item.fields
            let stateStr = fields?.state ?? "Unknown"
            let stateColor: String
            switch stateStr.lowercased() {
            case "active", "new": stateColor = stateStr.cyan
            case "resolved", "done": stateColor = stateStr.green
            case "closed": stateColor = stateStr.lightBlack
            default: stateColor = stateStr.yellow
            }

            let row = String(format: "%-8d %-12s %-12s %-40s %-15s",
                item.id,
                String((fields?.workItemType ?? "-").prefix(10)),
                stateColor,
                String((fields?.title ?? "-").prefix(38)),
                String((fields?.assignedTo?.displayName ?? "-").prefix(13)))
            print(row)
        }
        print("")
    }
}

// MARK: - Single Item

struct ItemSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item",
        abstract: "Get details for a specific work item"
    )

    @Argument(help: "Work item ID")
    var id: Int

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        guard let item = try await service.getWorkItem(id: id) else {
            print("Work item not found: \(id)".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(item)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printItemDetails(item)
        }
    }

    private func printItemDetails(_ item: WorkItem) {
        let fields = item.fields

        print("\n" + "Work Item #\(item.id): \(fields?.title ?? "Unknown")".bold.green + "\n")
        print("  Type:".lightBlue + "        \(fields?.workItemType ?? "-")")
        print("  State:".lightBlue + "       \(fields?.state ?? "-")")
        print("  Assigned To:".lightBlue + " \(fields?.assignedTo?.displayName ?? "-")")
        print("  Priority:".lightBlue + "    \(fields?.priority ?? 0)")
        print("  Iteration:".lightBlue + "   \(fields?.iterationPath ?? "-")")
        print("  Area:".lightBlue + "        \(fields?.areaPath ?? "-")")
        print("  Created:".lightBlue + "     \(fields?.createdDate ?? "-")")
        print("  Changed:".lightBlue + "     \(fields?.changedDate ?? "-")")

        if let tags = fields?.tags, !tags.isEmpty {
            print("  Tags:".lightBlue + "        \(tags)")
        }

        if let desc = fields?.description, !desc.isEmpty {
            // Strip HTML for display
            let cleanDesc = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            print("\n  Description:".bold)
            print("  \(cleanDesc.prefix(500))")
        }
        print("")
    }
}

// MARK: - Create Item

struct CreateItemSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new work item"
    )

    @Argument(help: "Title for the work item")
    var title: String

    @Option(name: .shortAndLong, help: "Work item type (Bug, Task, User Story)")
    var type: String = "Bug"

    @Option(name: .shortAndLong, help: "Description")
    var description: String?

    @Option(name: .shortAndLong, help: "Assign to (email or name)")
    var assignee: String?

    @Option(name: .shortAndLong, help: "Priority (1-4)")
    var priority: Int?

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        let request = CreateWorkItemRequest(
            title: title,
            type: type,
            description: description,
            assignedTo: assignee,
            priority: priority
        )

        guard let item = try await service.createWorkItem(request) else {
            print("Failed to create work item".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(item)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("\n" + "Created work item #\(item.id)".green.bold + "\n")
            print("  Title: \(item.fields?.title ?? title)")
            print("  Type: \(type)")
            print("")
        }
    }
}

// MARK: - Update Item

struct UpdateItemSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a work item"
    )

    @Argument(help: "Work item ID")
    var id: Int

    @Option(name: .shortAndLong, help: "New state (Active, Resolved, Closed)")
    var state: String?

    @Option(name: .shortAndLong, help: "Assign to")
    var assignee: String?

    @Option(name: .shortAndLong, help: "Add comment")
    var comment: String?

    @Option(name: .shortAndLong, help: "Priority (1-4)")
    var priority: Int?

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        let request = UpdateWorkItemRequest(
            state: state,
            assignedTo: assignee,
            priority: priority,
            comment: comment
        )

        guard let item = try await service.updateWorkItem(id: id, request: request) else {
            print("Failed to update work item".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(item)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("\n" + "Updated work item #\(item.id)".green.bold + "\n")
        }
    }
}

// MARK: - Sprints

struct SprintsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sprints",
        abstract: "List sprints/iterations"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        let sprints = try await service.getSprints()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sprints)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Sprints/Iterations".bold + " (\(sprints.count) total)\n")

            for sprint in sprints {
                let current = sprint.isCurrent ? " (current)".green.bold : ""
                let timeFrame = sprint.attributes?.timeFrame ?? ""
                let timeFrameColor = timeFrame == "current" ? timeFrame.green : timeFrame

                print("[\(timeFrameColor)] \(sprint.name ?? "Unknown")\(current)")
                if let start = sprint.attributes?.startDate, let end = sprint.attributes?.finishDate {
                    print("    \(start.prefix(10)) - \(end.prefix(10))")
                }
            }
            print("")
        }
    }
}

// MARK: - Boards

struct BoardsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boards",
        abstract: "List boards"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        let boards = try await service.getBoards()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(boards)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Boards".bold + " (\(boards.count) total)\n")

            for board in boards {
                print("  - \(board.name ?? "Unknown")")
            }
            print("")
        }
    }
}

// MARK: - From Error

struct FromErrorSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "from-error",
        abstract: "Create work item from FleetMate error"
    )

    @Argument(help: "Package/item name that failed")
    var itemName: String

    @Option(name: .shortAndLong, help: "Device name")
    var device: String = "Unknown Device"

    @Option(name: .shortAndLong, help: "Error message")
    var error: String = "Installation failed"

    @Option(name: .shortAndLong, help: "Assign to")
    var assignee: String?

    @Option(name: .shortAndLong, help: "Priority (1-4)")
    var priority: Int = 2

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)

        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        guard let item = try await service.createFromError(
            deviceName: device,
            itemName: itemName,
            errorMessage: error,
            assignedTo: assignee,
            priority: priority
        ) else {
            print("Failed to create work item".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(item)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("\n" + "Created error work item #\(item.id)".green.bold)
            print("  Title: \(item.fields?.title ?? itemName)")
            print("  Device: \(device)")
            print("")
        }
    }
}
