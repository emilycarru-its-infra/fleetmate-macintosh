import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// GitHub Projects v2 commands — board, list, items, and management.
/// Inspired by Backlog.md's terminal kanban + markdown export.
struct ProjectsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "projects",
        abstract: "GitHub Projects v2 board and management",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            ItemsSubcommand.self,
            BoardSubcommand.self,
            AddSubcommand.self,
            CreateDraftSubcommand.self,
            MoveSubcommand.self,
            ExportSubcommand.self,
            FieldsSubcommand.self,
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - List Projects

extension ProjectsCommand {
    struct ListSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List GitHub Projects v2"
        )

        @Option(name: .shortAndLong, help: "Scope: org, user, repo")
        var scope: String?

        @Option(name: .shortAndLong, help: "Owner (org or user login)")
        var owner: String?

        @Option(name: .shortAndLong, help: "Repository name (for repo scope)")
        var repo: String?

        @Flag(name: .long, help: "Include closed projects")
        var closed: Bool = false

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let (service, ghConfig) = try await createService()

            let resolvedScope = parseScope(scope ?? ghConfig.projectScope ?? "organization")
            let resolvedOwner = owner ?? ghConfig.organization ?? ghConfig.owner ?? ""
            let resolvedRepo = repo ?? ghConfig.repo

            let projects = try await service.listProjects(
                scope: resolvedScope, owner: resolvedOwner, repo: resolvedRepo,
                includeClosed: closed
            )

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(projects)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if projects.isEmpty {
                print("No projects found.".dim)
                return
            }

            let header = String(format: "%-6s %-35s %-10s %-12s",
                               "#", "Title", "Status", "Updated")
            print(header.bold)
            print(String(repeating: "─", count: 65))

            for p in projects {
                let status = p.closed ? "Closed".dim : (p.isPublic ? "Public".green : "Private".blue)
                let title = p.title.count > 32 ? String(p.title.prefix(32)) + "…" : p.title
                let row = String(format: "%-6d %-35s %-10s %-12s",
                               p.number, title, status,
                               formatDate(p.updatedAt))
                print(row)
            }
        }
    }
}

// MARK: - Show Project

extension ProjectsCommand {
    struct ShowSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show project details"
        )

        @Argument(help: "Project number")
        var number: Int

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let (service, ghConfig) = try await createService()
            let scope = parseScope(ghConfig.projectScope ?? "organization")
            let owner = ghConfig.organization ?? ghConfig.owner ?? ""

            guard let project = try await service.getProject(
                scope: scope, owner: owner, projectNumber: number, repo: ghConfig.repo
            ) else {
                print("Project #\(number) not found.".red)
                throw ExitCode.failure
            }

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(project)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            let fields = try await service.listProjectFields(projectId: project.id)
            let views = try await service.listProjectViews(projectId: project.id)

            print("\nProject #\(project.number)".bold.cyan)
            print(String(repeating: "═", count: 60))
            print("Title:".bold + " " + project.title)
            print("Description:".bold + " " + (project.shortDescription ?? "-"))
            print("URL:".bold + " " + (project.url ?? "-"))
            print("Visibility:".bold + " " + (project.isPublic ? "Public" : "Private"))
            print("Status:".bold + " " + (project.closed ? "Closed" : "Open"))
            print("Created:".bold + " " + formatDate(project.createdAt))
            print("Updated:".bold + " " + formatDate(project.updatedAt))
            print()
            print("Fields:".bold + " " + fields.map { "\($0.name) (\($0.dataType))" }.joined(separator: ", "))
            print("Views:".bold + " " + views.map { "\($0.name) (\($0.layout))" }.joined(separator: ", "))
        }
    }
}

// MARK: - Items

extension ProjectsCommand {
    struct ItemsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "items",
            abstract: "List project items"
        )

        @Option(name: .shortAndLong, help: "Project number (default: from config)")
        var project: Int?

        @Option(name: .shortAndLong, help: "Max items")
        var limit: Int = 50

        @Flag(name: .long, help: "Include archived items")
        var archived: Bool = false

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            let items = try await service.listProjectItems(
                projectId: projectId, limit: limit, includeArchived: archived
            )

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(items)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if items.isEmpty {
                print("No items found.".dim)
                return
            }

            let header = String(format: "%-5s %-40s %-15s %-15s %-15s",
                               "Type", "Title", "Status", "Assignees", "Labels")
            print(header.bold)
            print(String(repeating: "─", count: 92))

            for item in items {
                let title = item.content?.title ?? item.draftContent?.title ?? "(redacted)"
                let truncTitle = title.count > 37 ? String(title.prefix(37)) + "…" : title

                let status = item.fieldValues
                    .first { $0.fieldName.lowercased() == "status" }?
                    .singleSelectValue ?? "-"

                let assignees = item.content?.assignees.prefix(3).joined(separator: ", ") ?? "-"
                let labels = item.content?.labels.prefix(3).joined(separator: ", ") ?? "-"

                let typeIcon: String
                switch item.type {
                case "ISSUE": typeIcon = "●".green
                case "PULL_REQUEST": typeIcon = "⊙".magenta
                case "DRAFT_ISSUE": typeIcon = "○".dim
                default: typeIcon = "?"
                }

                print(String(format: " %-4s %-40s %-15s %-15s %-15s",
                           typeIcon, truncTitle, status, assignees, labels))
            }
            print("\n\(items.count) items".dim)
        }
    }
}

// MARK: - Board (Terminal Kanban)

extension ProjectsCommand {
    struct BoardSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "board",
            abstract: "Display terminal kanban board (Backlog.md-inspired)"
        )

        @Option(name: .shortAndLong, help: "Project number")
        var project: Int?

        @Option(name: .shortAndLong, help: "Max items")
        var limit: Int = 100

        @Flag(name: .shortAndLong, help: "Compact card style")
        var compact: Bool = false

        @Flag(name: .shortAndLong, help: "Output board data as JSON")
        var json: Bool = false

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            guard let statusField = try await service.getStatusField(projectId: projectId) else {
                print("No Status field found on this project.".yellow)
                return
            }

            let items = try await service.listProjectItems(projectId: projectId, limit: limit)

            // Group items by status column
            var columns: [(name: String, items: [GitHubProjectItem])] = statusField.options.map { ($0.name, []) }
            var noStatus: [GitHubProjectItem] = []

            for item in items {
                let statusValue = item.fieldValues
                    .first { $0.fieldName.lowercased() == "status" }?
                    .singleSelectValue

                if let statusValue = statusValue,
                   let idx = columns.firstIndex(where: { $0.name == statusValue }) {
                    columns[idx].items.append(item)
                } else {
                    noStatus.append(item)
                }
            }

            if !noStatus.isEmpty {
                columns.append(("(No Status)", noStatus))
            }

            if json {
                var boardData: [String: [[String: Any]]] = [:]
                for col in columns {
                    boardData[col.name] = col.items.map { item in
                        [
                            "id": item.id,
                            "type": item.type,
                            "title": item.content?.title ?? item.draftContent?.title ?? "",
                            "assignees": item.content?.assignees ?? [],
                            "labels": item.content?.labels ?? []
                        ] as [String: Any]
                    }
                }
                // Simple JSON output since we have [String: Any]
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                // Encode columns as array of named groups
                struct BoardColumn: Encodable {
                    let name: String
                    let items: [BoardItem]
                }
                struct BoardItem: Encodable {
                    let id: String
                    let type: String
                    let title: String
                    let assignees: [String]
                    let labels: [String]
                }
                let encodable = columns.map { col in
                    BoardColumn(name: col.name, items: col.items.map { item in
                        BoardItem(
                            id: item.id,
                            type: item.type,
                            title: item.content?.title ?? item.draftContent?.title ?? "",
                            assignees: item.content?.assignees ?? [],
                            labels: item.content?.labels ?? []
                        )
                    })
                }
                let data = try encoder.encode(encodable)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            renderKanbanBoard(columns: columns, compact: compact)
        }
    }
}

// MARK: - Add Item

extension ProjectsCommand {
    struct AddSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add an issue or PR to a project"
        )

        @Argument(help: "Issue/PR node ID")
        var contentId: String

        @Option(name: .shortAndLong, help: "Project number")
        var project: Int?

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            let itemId = try await service.addItemToProject(projectId: projectId, contentId: contentId)
            print("Added item to project:".green + " \(itemId)")
        }
    }
}

// MARK: - Create Draft

extension ProjectsCommand {
    struct CreateDraftSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-draft",
            abstract: "Create a draft issue in a project"
        )

        @Option(name: .shortAndLong, help: "Draft title")
        var title: String

        @Option(name: .shortAndLong, help: "Draft body")
        var body: String?

        @Option(name: .shortAndLong, help: "Initial status column")
        var status: String?

        @Option(name: .shortAndLong, help: "Project number")
        var project: Int?

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            let itemId = try await service.addDraftItem(projectId: projectId, title: title, body: body)

            // Move to status if specified
            if let status = status {
                if let statusField = try await service.getStatusField(projectId: projectId),
                   let option = statusField.options.first(where: { $0.name.lowercased() == status.lowercased() }) {
                    try await service.moveItemToStatus(
                        projectId: projectId, itemId: itemId,
                        statusFieldId: statusField.id, optionId: option.id
                    )
                }
            }

            print("Created draft:".green + " \(title) (\(itemId))")
        }
    }
}

// MARK: - Move Item

extension ProjectsCommand {
    struct MoveSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move an item to a different status column"
        )

        @Argument(help: "Project item ID")
        var itemId: String

        @Argument(help: "Target status column name")
        var status: String

        @Option(name: .shortAndLong, help: "Project number")
        var project: Int?

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            guard let statusField = try await service.getStatusField(projectId: projectId) else {
                print("No Status field found.".red)
                throw ExitCode.failure
            }

            guard let option = statusField.options.first(where: { $0.name.lowercased() == status.lowercased() }) else {
                let available = statusField.options.map(\.name).joined(separator: ", ")
                print("Status '\(status)' not found.".red + " Available: \(available)")
                throw ExitCode.failure
            }

            try await service.moveItemToStatus(
                projectId: projectId, itemId: itemId,
                statusFieldId: statusField.id, optionId: option.id
            )
            print("Moved item to \(option.name)".green)
        }
    }
}

// MARK: - Export to Markdown

extension ProjectsCommand {
    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export project board to markdown"
        )

        @Option(name: .shortAndLong, help: "Project number")
        var project: Int?

        @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
        var output: String?

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            let statusField = try await service.getStatusField(projectId: projectId)
            let items = try await service.listProjectItems(projectId: projectId, limit: 200)

            var md = "# Project Board\n\n"

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            md += "*Exported \(dateFormatter.string(from: Date()))*\n\n"

            if let statusField = statusField {
                // Group by status
                var grouped: [(name: String, items: [GitHubProjectItem])] = statusField.options.map { ($0.name, []) }
                var noStatus: [GitHubProjectItem] = []

                for item in items {
                    let sv = item.fieldValues
                        .first { $0.fieldName.lowercased() == "status" }?
                        .singleSelectValue
                    if let sv = sv, let idx = grouped.firstIndex(where: { $0.name == sv }) {
                        grouped[idx].items.append(item)
                    } else {
                        noStatus.append(item)
                    }
                }

                if !noStatus.isEmpty {
                    grouped.append(("(No Status)", noStatus))
                }

                for col in grouped {
                    if col.items.isEmpty && col.name == "(No Status)" { continue }

                    md += "## \(col.name) (\(col.items.count))\n\n"

                    for item in col.items {
                        let title = item.content?.title ?? item.draftContent?.title ?? "(untitled)"
                        let typeLabel: String
                        switch item.type {
                        case "ISSUE": typeLabel = "Issue"
                        case "PULL_REQUEST": typeLabel = "PR"
                        case "DRAFT_ISSUE": typeLabel = "Draft"
                        default: typeLabel = "?"
                        }

                        md += "- **[\(typeLabel)]** \(title)\n"

                        if let assignees = item.content?.assignees, !assignees.isEmpty {
                            md += "  - Assignees: \(assignees.map { "@\($0)" }.joined(separator: ", "))\n"
                        }
                        if let labels = item.content?.labels, !labels.isEmpty {
                            md += "  - Labels: \(labels.map { "`\($0)`" }.joined(separator: ", "))\n"
                        }
                        if let url = item.content?.url {
                            md += "  - \(url)\n"
                        }
                    }
                    md += "\n"
                }
            } else {
                for item in items {
                    let title = item.content?.title ?? item.draftContent?.title ?? "(untitled)"
                    md += "- \(title)\n"
                }
            }

            if let output = output {
                try md.write(toFile: output, atomically: true, encoding: .utf8)
                print("Exported to \(output)".green)
            } else {
                print(md)
            }
        }
    }
}

// MARK: - Fields

extension ProjectsCommand {
    struct FieldsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fields",
            abstract: "List project fields and their options"
        )

        @Option(name: .shortAndLong, help: "Project number")
        var project: Int?

        @Flag(name: .shortAndLong, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let (service, config) = try await createService()

            guard let projectId = try await resolveProjectId(
                service: service, config: config, projectNumber: project
            ) else { return }

            let fields = try await service.listProjectFields(projectId: projectId)

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(fields)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            for field in fields {
                print("\(field.name)".bold + " (\(field.dataType))".dim)
                for opt in field.options {
                    let colorDot = opt.color != nil ? "●" : " "
                    print("  \(colorDot) \(opt.name)" + " (\(opt.id))".dim)
                }
                for iter in field.iterations {
                    print("  ⟳ \(iter.title)" + " \(iter.startDate ?? "")".dim)
                }
            }
        }
    }
}

// MARK: - Kanban Board Renderer

private func renderKanbanBoard(
    columns: [(name: String, items: [GitHubProjectItem])],
    compact: Bool
) {
    let maxItems = columns.map(\.items.count).max() ?? 0
    let colWidth = 26

    // Color map for status columns
    func colorize(_ text: String, column: String) -> String {
        let lower = column.lowercased()
        if lower.contains("done") || lower.contains("closed") { return text.green }
        if lower.contains("progress") || lower.contains("active") { return text.blue }
        if lower.contains("review") { return text.magenta }
        if lower.contains("backlog") { return text.dim }
        if lower.contains("todo") { return text.white }
        return text.yellow
    }

    // Header row
    var headerLine = ""
    for col in columns {
        let label = "\(col.name) (\(col.items.count))"
        let padded = label.count > colWidth ? String(label.prefix(colWidth)) : label + String(repeating: " ", count: colWidth - label.count)
        headerLine += colorize(padded, column: col.name).bold + "  "
    }
    print(headerLine)

    // Separator
    var sepLine = ""
    for _ in columns {
        sepLine += String(repeating: "─", count: colWidth) + "  "
    }
    print(sepLine.dim)

    // Card rows
    for i in 0..<maxItems {
        var cardLines: [[String]] = []
        var maxLines = 1

        for col in columns {
            if i < col.items.count {
                let lines = renderCard(item: col.items[i], width: colWidth, compact: compact)
                cardLines.append(lines)
                maxLines = max(maxLines, lines.count)
            } else {
                cardLines.append([""])
            }
        }

        for line in 0..<maxLines {
            var row = ""
            for colIdx in 0..<columns.count {
                let lines = cardLines[colIdx]
                let text = line < lines.count ? lines[line] : ""
                // Pad without counting ANSI escape sequences
                let visibleLen = text.replacingOccurrences(
                    of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression
                ).count
                let padding = max(0, colWidth - visibleLen)
                row += text + String(repeating: " ", count: padding) + "  "
            }
            print(row)
        }
    }

    let totalItems = columns.reduce(0) { $0 + $1.items.count }
    print("\nTotal: \(totalItems) items across \(columns.count) columns".dim)
}

private func renderCard(item: GitHubProjectItem, width: Int, compact: Bool) -> [String] {
    let title = item.content?.title ?? item.draftContent?.title ?? "(untitled)"
    let maxTitleLen = width - 3
    let truncTitle = title.count > maxTitleLen ? String(title.prefix(maxTitleLen - 1)) + "…" : title

    let typeIcon: String
    switch item.type {
    case "ISSUE": typeIcon = "●".green
    case "PULL_REQUEST": typeIcon = "⊙".magenta
    case "DRAFT_ISSUE": typeIcon = "○".dim
    default: typeIcon = " "
    }

    if compact {
        return ["\(typeIcon) \(truncTitle)"]
    }

    var lines = ["\(typeIcon) \(truncTitle.bold)"]

    if let assignees = item.content?.assignees, !assignees.isEmpty {
        let text = "  @" + assignees.prefix(2).joined(separator: ", ")
        lines.append(text.dim)
    }

    if let labels = item.content?.labels, !labels.isEmpty {
        let text = "  " + labels.prefix(3).map { "[\($0)]" }.joined(separator: " ")
        lines.append(text.cyan)
    }

    return lines
}

// MARK: - Helpers

private func createService() async throws -> (GitHubProjectsService, GitHubProviderConfig) {
    let config = try FleetMateConfig.load()

    guard let ghConfig = config.tasks?.providers.github, ghConfig.enabled else {
        print("GitHub provider is not configured or enabled.".yellow)
        print("Configure tasks.providers.github in your config.yaml".dim)
        throw ExitCode.failure
    }

    let service = GitHubProjectsService(config: ghConfig)
    guard try await service.authenticate() else {
        print("Failed to authenticate with GitHub.".red)
        throw ExitCode.failure
    }

    return (service, ghConfig)
}

private func resolveProjectId(
    service: GitHubProjectsService, config: GitHubProviderConfig, projectNumber: Int?
) async throws -> String? {
    let scope = parseScope(config.projectScope ?? "organization")
    let owner = config.organization ?? config.owner ?? ""
    let num = projectNumber ?? config.projectNumber

    if let num = num {
        guard let project = try await service.getProject(
            scope: scope, owner: owner, projectNumber: num, repo: config.repo
        ) else {
            print("Project #\(num) not found.".red)
            return nil
        }
        return project.id
    }

    // Use first available project
    let projects = try await service.listProjects(scope: scope, owner: owner, repo: config.repo, limit: 1)
    guard let first = projects.first else {
        print("No projects found. Specify --project or configure project_number.".red)
        return nil
    }
    return first.id
}

private func parseScope(_ scope: String) -> ProjectScope {
    switch scope.lowercased() {
    case "user": return .user
    case "repository", "repo": return .repository
    default: return .organization
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
