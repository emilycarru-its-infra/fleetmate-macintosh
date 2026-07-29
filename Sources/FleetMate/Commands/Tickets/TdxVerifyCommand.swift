import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// Exercises every TDX call the Tickets tab makes, against the real API.
///
/// The unit tests pin what each action *sends*; only the server can say whether
/// the endpoint exists and accepts it. Both silent failures this was written
/// after — a reply posted to a route that 404s, a PATCH body the server refused
/// to parse — looked like working code and passing types.
struct VerifySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check that every TDX action the app performs still works"
    )

    @Option(name: .long, help: "Ticket ID to read during the checks. Defaults to the newest ticket found.")
    var ticket: Int?

    @Option(name: .long, help: "Exercise write paths against this ticket ID (updates its title to its current value, posts a comment, and replies to that comment).")
    var write: Int?

    @Flag(name: .long, help: "Skip the confirmation prompt before write checks.")
    var yes: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    // MARK: - Result collection

    private struct Check {
        let name: String
        let call: String
        var passed: Bool
        var detail: String
    }

    private final class Results {
        var checks: [Check] = []

        func record(_ name: String, _ call: String, passed: Bool, detail: String) {
            checks.append(Check(name: name, call: call, passed: passed, detail: detail))
        }

        var failures: Int { checks.filter { !$0.passed }.count }
    }

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = TdxService(config: config)

        guard service.isConfigured else {
            print("TeamDynamix not configured.".red)
            throw ExitCode.failure
        }

        let results = Results()
        let appId = config.tdxTicketingAppId ?? config.tdxAppId ?? 0

        let sampleTicketId = try await runReadChecks(service: service, appId: appId, results: results)

        if let writeTicketId = write {
            guard try confirmWrites(on: writeTicketId) else {
                print("Write checks skipped.".yellow)
                try report(results)
                return
            }
            await runWriteChecks(service: service, appId: appId, ticketId: writeTicketId, results: results)
        } else if !json {
            print("Write paths not checked. Re-run with --write <ticketId> to include them.".yellow)
        }

        _ = sampleTicketId
        try report(results)
    }

    // MARK: - Reads

    private func runReadChecks(service: TdxService, appId: Int, results: Results) async throws -> Int? {
        var sampleTicketId = ticket

        await check(results, "Search tickets", "POST /api/\(appId)/tickets/search") {
            let tickets = try await service.searchTickets(maxResults: 5)
            if sampleTicketId == nil { sampleTicketId = tickets.first?.id }
            return "\(tickets.count) returned"
        }

        if let id = sampleTicketId {
            await check(results, "Get ticket", "GET /api/\(appId)/tickets/\(id)") {
                guard let ticket = try await service.getTicket(id: id) else { return "not found" }
                let parent = ticket.parentTicketId.map { " parent #\($0)" } ?? " no parent"
                return "#\(ticket.id ?? 0)\(parent)"
            }

            await check(results, "Get ticket feed", "GET /api/\(appId)/tickets/\(id)/feed") {
                let feed = try await service.getTicketFeed(ticketId: id)
                let threaded = feed.filter { !$0.replyList.isEmpty }.count
                return "\(feed.count) entries, \(threaded) threaded"
            }

            await check(results, "Get feed entry", "GET /api/feed/{id}") {
                let feed = try await service.getTicketFeed(ticketId: id)
                guard let entryId = feed.first?.id else { return "no feed entries to read" }
                guard let entry = try await service.getFeedEntry(id: entryId) else { return "not found" }
                return "entry \(entry.id ?? 0)"
            }
        } else {
            results.record("Get ticket", "GET /api/\(appId)/tickets/{id}", passed: false,
                           detail: "no ticket available — pass --ticket <id>")
        }

        await check(results, "Statuses", "GET /api/\(appId)/tickets/statuses") {
            "\(try await service.getStatuses().count) statuses"
        }
        await check(results, "Types", "GET /api/\(appId)/tickets/types") {
            "\(try await service.getTypeItems().count) types"
        }
        await check(results, "Priorities", "GET /api/\(appId)/tickets/priorities") {
            "\(try await service.getPriorities().count) priorities"
        }
        await check(results, "Forms", "GET /api/\(appId)/tickets/forms") {
            "\(try await service.getForms().count) forms"
        }
        await check(results, "Sources", "GET /api/\(appId)/tickets/sources") {
            "\(try await service.getSources().count) sources"
        }
        await check(results, "Accounts", "POST /api/accounts/search") {
            "\(try await service.getAccounts().count) accounts"
        }
        await check(results, "Groups", "POST /api/groups/search") {
            "\(try await service.getGroups().count) groups"
        }
        await check(results, "Services", "GET /api/services") {
            "\(try await service.getServices().count) services"
        }
        await check(results, "People lookup", "GET /api/people/lookup") {
            "\(try await service.searchPeople(searchText: "a", maxResults: 5).count) matches"
        }

        return sampleTicketId
    }

    // MARK: - Writes

    private func confirmWrites(on ticketId: Int) throws -> Bool {
        if yes { return true }
        print("""

        Write checks will modify ticket #\(ticketId) on the live service desk:
          • re-save its title (same value, but this records an edit in its history)
          • post a private comment
          • post a threaded reply to that comment

        """.yellow)
        print("Continue? [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private func runWriteChecks(service: TdxService, appId: Int, ticketId: Int, results: Results) async {
        var commentId: Int?

        await check(results, "Update ticket", "PATCH /api/\(appId)/tickets/\(ticketId)") {
            guard let existing = try await service.getTicket(id: ticketId) else {
                throw VerifyError.message("ticket #\(ticketId) not found")
            }
            // Writing the title back unchanged still proves the JSON Patch body
            // parses, without altering the ticket's content.
            let updated = try await service.updateTicket(
                id: ticketId,
                updates: ["Title": existing.title ?? ""]
            )
            guard updated != nil else { throw VerifyError.message("no ticket returned") }
            return "title round-tripped"
        }

        await check(results, "Add comment", "POST /api/\(appId)/tickets/\(ticketId)/feed") {
            guard let entry = try await service.addComment(
                ticketId: ticketId,
                comment: "FleetMate API verification — safe to ignore.",
                isPrivate: true
            ) else { throw VerifyError.message("no feed entry returned") }
            commentId = entry.id
            return "feed entry \(entry.id ?? 0)"
        }

        await check(results, "Reply in thread", "POST /api/feed/{id}/comment") {
            guard let parentId = commentId else {
                throw VerifyError.message("no comment to reply to")
            }
            guard let reply = try await service.replyToFeedEntry(
                feedEntryId: parentId,
                comment: "FleetMate API verification reply — safe to ignore.",
                isPrivate: true
            ) else { throw VerifyError.message("no reply returned") }

            // A reply that posts but doesn't thread is still a failure.
            let parent = try await service.getFeedEntry(id: parentId)
            let threaded = parent?.replyList.contains { $0.id == reply.id } ?? false
            guard threaded else {
                throw VerifyError.message("reply \(reply.id ?? 0) posted but is not nested under \(parentId)")
            }
            return "reply \(reply.id ?? 0) nested under \(parentId)"
        }
    }

    // MARK: - Plumbing

    private func check(
        _ results: Results,
        _ name: String,
        _ call: String,
        _ body: () async throws -> String
    ) async {
        do {
            let detail = try await body()
            results.record(name, call, passed: true, detail: detail)
        } catch {
            results.record(name, call, passed: false, detail: error.localizedDescription)
        }
    }

    private func report(_ results: Results) throws {
        if json {
            let payload = results.checks.map {
                ["name": $0.name, "call": $0.call, "passed": $0.passed, "detail": $0.detail] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "TDX API verification".bold + "\n")
            let width = results.checks.map(\.name.count).max() ?? 20
            for check in results.checks {
                let mark = check.passed ? "PASS".green : "FAIL".red
                let name = check.name.padding(toLength: width, withPad: " ", startingAt: 0)
                print("  \(mark)  \(name)  \(check.call.dim)")
                print("        \(check.detail.dim)")
            }
            let failures = results.failures
            let summary = "\(results.checks.count - failures)/\(results.checks.count) checks passed"
            print("\n" + (failures == 0 ? summary.green.bold : summary.red.bold) + "\n")
        }

        if results.failures > 0 {
            throw ExitCode.failure
        }
    }
}

private enum VerifyError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
