import ArgumentParser
import FleetMateCore
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
            QueriesSubcommand.self,
            FromErrorSubcommand.self,
            DevOpsTestSubcommand.self
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

        let header = "ID".col(8) + " " + "Type".col(12) + " " + "State".col(12) + " " + "Title".col(40) + " " + "Assigned To".col(15)
        print(header.underline)

        for item in items {
            let fields = item.fields
            let stateCell = (fields?.state ?? "Unknown").col(12)
            let stateColor: String
            switch (fields?.state ?? "Unknown").lowercased() {
            case "active", "new": stateColor = stateCell.cyan
            case "resolved", "done": stateColor = stateCell.green
            case "closed": stateColor = stateCell.lightBlack
            default: stateColor = stateCell.yellow
            }

            let row = item.id.col(8) + " "
                + (fields?.workItemType ?? "-").col(12) + " "
                + stateColor + " "
                + (fields?.title ?? "-").col(40) + " "
                + (fields?.assignedTo?.displayName ?? "-").col(15)
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

// MARK: - Test Subcommand

struct DevOpsTestSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Test Azure DevOps connectivity end-to-end (SSO token refresh → discovery → WIQL)"
    )

    @Flag(name: .shortAndLong, help: "Show verbose output")
    var verbose: Bool = false

    func run() async throws {
        print("Azure DevOps End-to-End Test".bold)
        print(String(repeating: "─", count: 40))

        // 1. Load config
        let config = try FleetMateConfig.load()
        let org = config.tasks?.providers.azdevops?.organization
                  ?? config.devopsOrganization
                  ?? ""
        let configProject = config.tasks?.providers.azdevops?.project
                            ?? config.devopsProject
                            ?? ""
        let tenantId = config.devopsTenantId ?? config.graphTenantId

        print("\n" + "1. Configuration".cyan.bold)
        print("   Organization: \(org.isEmpty ? "(not set)".red : org.green)")
        print("   Project:      \(configProject.isEmpty ? "(will auto-discover)".yellow : configProject.green)")
        print("   Tenant ID:    \(tenantId ?? "organizations (default)")")

        guard !org.isEmpty else {
            print("\n" + "No organization configured. Set azdevops.organization in config.yaml".red)
            throw ExitCode.failure
        }

        // 2. Token acquisition (az CLI → MSAL cache → refresh token)
        print("\n" + "2. Token Acquisition".cyan.bold)
        let sso = DevOpsSsoService(tenantId: tenantId)

        let result = try await sso.refreshAccessToken()
        guard result.success, let accessToken = result.accessToken else {
            print("   [ERROR] Token acquisition failed: \(result.error ?? "unknown")".red)
            print("   Run 'az login' to authenticate via Platform SSO".yellow)
            throw ExitCode.failure
        }
        print("   + Access token acquired (via az CLI / MSAL cache)".green)
        print("   User:       \(result.userName ?? "unknown")")
        print("   Expires in: \(result.expiresIn ?? 0)s")

        // 3. API service + auth check
        print("\n" + "3. API Auth Verification".cyan.bold)
        let service = AzureDevOpsService(config: config)
        service.setBearerToken(accessToken, expiry: Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600)))

        let authOk = try await service.verifyAuth()
        print("   Auth status: \(authOk ? "OK".green : "FAILED".red)")
        guard authOk else { throw ExitCode.failure }

        // 4. Project discovery / listing
        print("\n" + "4. Projects".cyan.bold)
        let projects = try await service.listProjects()
        if projects.isEmpty {
            print("   [ERROR] No projects found in org '\(org)'".red)
            throw ExitCode.failure
        }
        for p in projects {
            print("   • \(p.name) (\(p.state ?? "?"))")
        }

        let resolvedProject: String
        if configProject.isEmpty {
            print("   Auto-discovering project...")
            guard let discovered = try await service.discoverProject() else {
                print("   [ERROR] Discovery failed".red)
                throw ExitCode.failure
            }
            resolvedProject = discovered
            print("   + Using discovered project: '\(resolvedProject)'".green)
        } else {
            service.setProject(configProject)
            resolvedProject = configProject
            print("   Using configured project: '\(resolvedProject)'".green)
        }

        // 5. Org-level WIQL query — all projects in one call
        print("\n" + "5. Work Items (org-level WIQL)".cyan.bold)
        let wiql = """
        SELECT [System.Id] FROM WorkItems \
        WHERE [System.State] <> 'Closed' AND [System.State] <> 'Done' AND [System.State] <> 'Removed' \
        ORDER BY [System.ChangedDate] DESC
        """
        if verbose {
            print("   WIQL: \(wiql)")
        }
        let allItems = try await service.queryWorkItems(wiql, orgLevel: true)
        let totalItems = allItems.count
        print("   \(totalItems) active work items across all projects".green)

        // Group by project for display
        var byProject: [String: Int] = [:]
        for item in allItems {
            let proj = item.fields?.teamProject ?? "unknown"
            byProject[proj, default: 0] += 1
        }
        for (proj, count) in byProject.sorted(by: { $0.key < $1.key }) {
            print("   • \(proj): \(count) items")
        }

        // Show top items
        if !allItems.isEmpty {
            print("")
            let showCount = min(allItems.count, 10)
            for item in allItems.prefix(showCount) {
                let state = item.fields?.state ?? "?"
                let type = item.fields?.workItemType ?? "?"
                let title = item.fields?.title ?? "(no title)"
                let proj = item.fields?.teamProject ?? "?"
                let assignee = item.fields?.assignedTo?.displayName ?? "unassigned"
                print("   #\(item.id) [\(proj)/\(type)] \(state.cyan) \(title) → \(assignee.dim)")
            }
            if allItems.count > showCount {
                print("   ... and \(allItems.count - showCount) more")
            }
        }

        // Set project for sprints query
        service.setProject(resolvedProject)

        // 6. Sprints
        print("\n" + "6. Sprints".cyan.bold)
        do {
            let sprints = try await service.getSprints()
            print("   \(sprints.count) sprints found")
            if let current = sprints.first(where: { $0.isCurrent }) {
                print("   Current: \(current.name ?? "unknown")".green)
            }
            if verbose {
                for s in sprints {
                    let marker = s.isCurrent ? " ← current".green : ""
                    print("   • \(s.name ?? "?")\(marker)")
                }
            }
        } catch {
            print("   [WARNING] Could not load sprints: \(error.localizedDescription)".yellow)
        }

        // Summary
        print("\n" + String(repeating: "─", count: 40))
        print("+ All checks passed!".green.bold)
        print("  Org:      \(org)")
        print("  Project:  \(resolvedProject)")
        print("  Projects: \(projects.map { $0.name }.joined(separator: ", "))")
        print("  Items:    \(totalItems) active work items across all projects")
    }
}
