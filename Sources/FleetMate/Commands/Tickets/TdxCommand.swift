import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct TdxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tdx",
        abstract: "Query TeamDynamix tickets",
        subcommands: [
            TicketsSubcommand.self,
            TicketSubcommand.self,
            CreateTicketSubcommand.self,
            CommentSubcommand.self,
            StatusesSubcommand.self,
            VerifySubcommand.self
        ],
        defaultSubcommand: TicketsSubcommand.self
    )
}

// MARK: - List Tickets

struct TicketsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tickets",
        abstract: "Search for tickets"
    )

    @Option(name: .shortAndLong, help: "Search text")
    var search: String?

    @Option(name: [.customShort("S"), .long], help: "Filter by status ID")
    var status: Int?

    @Option(name: .shortAndLong, help: "Filter by type ID")
    var type: Int?

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 50

    @Flag(name: .long, help: "Show only on-hold tickets")
    var onHold: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = TdxService(config: config)

        guard service.isConfigured else {
            print("TeamDynamix not configured. Set TDX_BASE_URL and TDX_APP_ID.".red)
            throw ExitCode.failure
        }

        var searchRequest = TicketSearchRequest()
        searchRequest.searchText = search
        if let status = status {
            searchRequest.statusIds = [status]
        }
        if let type = type {
            searchRequest.typeIds = [type]
        }
        if onHold {
            searchRequest.isOnHold = true
        }

        let tickets = try await service.searchTickets(search: searchRequest, maxResults: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tickets)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printTicketsTable(tickets)
        }
    }

    private func printTicketsTable(_ tickets: [TdxTicket]) {
        print("\n" + "TeamDynamix Tickets".bold + " (\(tickets.count) shown)\n")

        // Use Swift string padding instead of C format specifiers
        let header = "ID".padding(toLength: 8, withPad: " ", startingAt: 0) +
                     "Status".padding(toLength: 14, withPad: " ", startingAt: 0) +
                     "Priority".padding(toLength: 12, withPad: " ", startingAt: 0) +
                     "Title".padding(toLength: 35, withPad: " ", startingAt: 0) +
                     "Requestor"
        print(header.underline)

        for ticket in tickets {
            let statusStr = ticket.statusName ?? "Unknown"
            let statusColor: String
            switch statusStr.lowercased() {
            case "new", "open": statusColor = statusStr.cyan
            case "in progress", "in process": statusColor = statusStr.yellow
            case "resolved", "closed": statusColor = statusStr.green
            case "on hold": statusColor = statusStr.lightBlack
            default: statusColor = statusStr
            }

            let row = String(ticket.id ?? 0).padding(toLength: 8, withPad: " ", startingAt: 0) +
                      statusColor.padding(toLength: 14, withPad: " ", startingAt: 0) +
                      String((ticket.priorityName ?? "-").prefix(10)).padding(toLength: 12, withPad: " ", startingAt: 0) +
                      String((ticket.title ?? "-").prefix(33)).padding(toLength: 35, withPad: " ", startingAt: 0) +
                      String((ticket.requestorName ?? "-").prefix(18))
            print(row)
        }
        print("")
    }
}

// MARK: - Single Ticket

struct TicketSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ticket",
        abstract: "Get details for a specific ticket"
    )

    @Argument(help: "Ticket ID")
    var id: Int

    @Flag(name: .shortAndLong, help: "Include feed/comments")
    var feed: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = TdxService(config: config)

        guard service.isConfigured else {
            print("TeamDynamix not configured.".red)
            throw ExitCode.failure
        }

        guard let ticket = try await service.getTicket(id: id) else {
            print("Ticket not found: \(id)".red)
            throw ExitCode.failure
        }

        var feedEntries: [TdxFeedEntry] = []
        if feed {
            feedEntries = try await service.getTicketFeed(ticketId: id)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var output: [String: Any] = [:]
            if let ticketData = try? encoder.encode(ticket) {
                output["ticket"] = try? JSONSerialization.jsonObject(with: ticketData)
            }
            if feed, let feedData = try? encoder.encode(feedEntries) {
                output["feed"] = try? JSONSerialization.jsonObject(with: feedData)
            }
            let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        } else {
            printTicketDetails(ticket, feed: feedEntries)
        }
    }

    private func printTicketDetails(_ ticket: TdxTicket, feed: [TdxFeedEntry]) {
        print("\n" + "Ticket #\(ticket.id ?? 0): \(ticket.title ?? "Unknown")".bold.green + "\n")
        print("  Status:".lightBlue + "      \(ticket.statusName ?? "-")")
        print("  Type:".lightBlue + "        \(ticket.typeName ?? "-")")
        print("  Priority:".lightBlue + "    \(ticket.priorityName ?? "-")")
        print("  Source:".lightBlue + "      \(ticket.sourceName ?? "-")")
        print("  Account:".lightBlue + "     \(ticket.accountName ?? "-")")
        print("  Requestor:".lightBlue + "   \(ticket.requestorName ?? "-") <\(ticket.requestorEmail ?? "-")>")
        print("  Responsible:".lightBlue + " \(ticket.responsibleFullName ?? "-")")
        print("  Created:".lightBlue + "     \(ticket.createdDate ?? "-")")
        print("  Modified:".lightBlue + "    \(ticket.modifiedDate ?? "-")")

        if ticket.isOnHold == true {
            print("  On Hold:".lightBlue + "     " + "Yes".yellow + " (until \(ticket.goesOffHoldDate ?? "unknown"))")
        }

        if ticket.slaViolated == true {
            print("  SLA:".lightBlue + "         " + "VIOLATED".red.bold)
        }

        if let desc = ticket.description, !desc.isEmpty {
            // Strip HTML
            let cleanDesc = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            print("\n  Description:".bold)
            print("  \(cleanDesc.prefix(500))")
        }

        if !feed.isEmpty {
            print("\n  Recent Activity:".bold)
            for entry in feed.prefix(10) {
                let privateTag = entry.isPrivate == true ? " [Private]".yellow : ""
                print("\n  [\(entry.createdDate?.prefix(16) ?? "-")] \(entry.createdFullName ?? "Unknown")\(privateTag)")
                if let body = entry.body {
                    let cleanBody = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    print("    \(cleanBody.prefix(200))")
                }
            }
        }
        print("")
    }
}

// MARK: - Create Ticket

struct CreateTicketSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new ticket"
    )

    @Argument(help: "Ticket title")
    var title: String

    @Option(name: .shortAndLong, help: "Type ID")
    var type: Int?

    @Option(name: .shortAndLong, help: "Description")
    var description: String?

    @Option(name: .shortAndLong, help: "Priority ID")
    var priority: Int?

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = TdxService(config: config)

        guard service.isConfigured else {
            print("TeamDynamix not configured.".red)
            throw ExitCode.failure
        }

        let request = CreateTicketRequest(
            typeId: type ?? config.tdxDefaultTypeId ?? 0,
            title: title,
            description: description,
            priorityId: priority
        )

        guard let ticket = try await service.createTicket(request: request) else {
            print("Failed to create ticket".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ticket)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("\n" + "Created ticket #\(ticket.id ?? 0)".green.bold + "\n")
            print("  Title: \(ticket.title ?? title)")
            print("")
        }
    }
}

// MARK: - Add Comment

struct CommentSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "comment",
        abstract: "Add a comment to a ticket"
    )

    @Argument(help: "Ticket ID")
    var id: Int

    @Argument(help: "Comment text")
    var comment: String

    @Flag(name: .shortAndLong, help: "Mark as private")
    var privateComment: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = TdxService(config: config)

        guard service.isConfigured else {
            print("TeamDynamix not configured.".red)
            throw ExitCode.failure
        }

        guard let entry = try await service.addComment(ticketId: id, comment: comment, isPrivate: privateComment) else {
            print("Failed to add comment — not authenticated".red)
            throw ExitCode.failure
        }

        print("\n" + "Comment added to ticket #\(id) (feed entry \(entry.id ?? 0))".green.bold + "\n")
    }
}

// MARK: - Statuses

struct StatusesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statuses",
        abstract: "List available ticket statuses"
    )

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = TdxService(config: config)

        guard service.isConfigured else {
            print("TeamDynamix not configured.".red)
            throw ExitCode.failure
        }

        let statuses = try await service.getStatuses()

        if json {
            let output = statuses.map { ["id": $0.key, "name": $0.value] }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Ticket Statuses".bold + "\n")

            for (id, name) in statuses.sorted(by: { $0.key < $1.key }) {
                print("  [\(id)] \(name)")
            }
            print("")
        }
    }
}
