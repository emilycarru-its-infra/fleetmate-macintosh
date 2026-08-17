import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

// MARK: - Shared Queries

struct QueriesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "queries",
        abstract: "List and run Shared Queries (the same view the app's Projects list renders)"
    )

    @Argument(help: "Query name (substring) or GUID to run; omit to list all queries")
    var query: String?

    @Flag(name: .long, help: "Run every shared query and show row counts")
    var runAll: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let service = try await Self.authenticatedService()
        let queries = try await service.getSharedQueries()

        if let needle = query {
            guard let match = resolve(needle, in: queries) else {
                print("No shared query matches '\(needle)'".red)
                throw ExitCode.failure
            }
            let run = try await service.runStoredQuery(id: match.id)
            if json {
                printRowsJson(run)
            } else {
                printRows(match, run)
            }
            return
        }

        if runAll {
            print("\n" + "Shared Queries — full run".bold + " (\(queries.count) queries)\n")
            for q in queries {
                do {
                    let run = try await service.runStoredQuery(id: q.id)
                    let suffix = run.truncated ? " (truncated)".yellow : ""
                    let folder = q.folderPath.isEmpty ? "" : " [\(q.folderPath)]".dim
                    print("  \(String(run.rows.count).col(5)) \(q.name)\(folder)\(suffix)")
                } catch {
                    print("  " + "ERR".red + "   \(q.name): \(error.localizedDescription)")
                }
            }
            print("")
            return
        }

        if json {
            struct Row: Encodable { let id, name, folder, type: String }
            let rows = queries.map { Row(id: $0.id, name: $0.name, folder: $0.folderPath, type: $0.queryType) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(rows), encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Shared Queries".bold + " (\(queries.count) total)\n")
            let header = "Type".col(8) + " " + "Folder".col(26) + " " + "Name"
            print(header.underline)
            for q in queries {
                print(q.queryType.col(8) + " " + (q.folderPath.isEmpty ? "-" : q.folderPath).col(26) + " " + q.name)
            }
            print("")
        }
    }

    private func resolve(_ needle: String, in queries: [AdoSharedQuery]) -> AdoSharedQuery? {
        if let byId = queries.first(where: { $0.id.caseInsensitiveCompare(needle) == .orderedSame }) {
            return byId
        }
        if let exact = queries.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) {
            return exact
        }
        return queries.first { $0.name.range(of: needle, options: .caseInsensitive) != nil }
    }

    private func printRows(_ query: AdoSharedQuery, _ run: StoredQueryRun) {
        print("\n" + query.name.bold + " (\(run.queryType), \(run.rows.count) rows)\n")
        for row in run.rows {
            let fields = row.item.fields
            let indent = String(repeating: "  ", count: row.depth)
            let state = (fields?.state ?? "?").col(12)
            let stateColored: String
            switch (fields?.state ?? "").lowercased() {
            case "active", "in progress": stateColored = state.cyan
            case "closed", "done", "completed": stateColored = state.green
            case "resolved": stateColored = state.yellow
            default: stateColored = state
            }
            let type = (fields?.workItemType ?? "?").col(12)
            let assignee = fields?.assignedTo?.displayName ?? ""
            print("  \(String(row.item.id).col(6)) \(type) \(stateColored) \(indent)\(fields?.title ?? "-")" + (assignee.isEmpty ? "" : "  → \(assignee)".dim))
        }
        if run.truncated {
            print("\n  (truncated at \(run.rows.count) rows)".yellow)
        }
        print("")
    }

    private func printRowsJson(_ run: StoredQueryRun) {
        struct Row: Encodable {
            let id: Int, depth: Int
            let type, state, title, assignee: String?
        }
        let rows = run.rows.map {
            Row(
                id: $0.item.id,
                depth: $0.depth,
                type: $0.item.fields?.workItemType,
                state: $0.item.fields?.state,
                title: $0.item.fields?.title,
                assignee: $0.item.fields?.assignedTo?.displayName
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(rows) {
            print(String(data: data, encoding: .utf8) ?? "[]")
        }
    }

    /// Silent SSO → bearer token → resolved project, the same chain the test
    /// subcommand walks.
    static func authenticatedService() async throws -> AzureDevOpsService {
        let config = try FleetMateConfig.load()
        let service = AzureDevOpsService(config: config)
        guard service.isConfigured else {
            print("Azure DevOps not configured.".red)
            throw ExitCode.failure
        }

        let tenantId = config.devopsTenantId ?? config.graphTenantId
        let sso = DevOpsSsoService(tenantId: tenantId)
        let result = try await sso.refreshAccessToken()
        guard result.success, let token = result.accessToken else {
            print("Token acquisition failed: \(result.error ?? "unknown"). Run 'az login'.".red)
            throw ExitCode.failure
        }
        service.setBearerToken(token, expiry: Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600)))

        if service.resolvedProject.isEmpty {
            _ = try await service.discoverProject()
        }
        return service
    }
}
