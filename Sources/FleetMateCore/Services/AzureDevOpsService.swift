import Foundation

/// Azure DevOps service — all operations via `az devops` / `az boards` CLI.
/// Auth is handled by the Azure CLI itself (`az login` user session).
/// **NO PAT, NO service principal, NO REST-with-Bearer** — CLI only.
public class AzureDevOpsService {
    private let config: FleetMateConfig
    private let azPath: String
    private let orgUrl: String
    private let project: String

    // Caches
    private var sprintCache: [Sprint]?
    private var sprintCacheExpiry: Date = .distantPast
    private let cacheDuration: TimeInterval

    public var isConfigured: Bool {
        config.isDevOpsConfigured
    }

    public var baseUrl: String {
        orgUrl
    }

    public init(config: FleetMateConfig) {
        self.config = config
        self.cacheDuration = TimeInterval(config.cacheMinutes * 60)
        self.orgUrl = "https://dev.azure.com/\(config.devopsOrganization ?? "")"
        self.project = config.devopsProject ?? ""

        // Resolve az CLI path
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/az") {
            self.azPath = "/opt/homebrew/bin/az"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/az") {
            self.azPath = "/usr/local/bin/az"
        } else {
            self.azPath = "az" // hope PATH resolves it
        }
    }

    // MARK: - CLI Runner

    /// Run an `az` command and return stdout as Data. Throws on non-zero exit.
    private func runAz(_ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: azPath)
        process.arguments = arguments
        // Inject org + project so every call is scoped
        process.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        dbg.debug("az \(arguments.joined(separator: " "))", category: "azdo")

        try process.run()
        process.waitUntilExit()

        let outData = out.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            dbg.error("az exit \(process.terminationStatus): \(errStr.prefix(500))", category: "azdo")
            throw AzDevOpsError.cliError(code: process.terminationStatus, message: errStr)
        }
        return outData
    }

    /// Run az command and decode JSON output.
    private func runAzJson<T: Decodable>(_ arguments: [String], as type: T.Type) async throws -> T {
        let data = try await runAz(arguments)
        // az output may have BOM
        let clean = data.dropBOM()
        return try JSONDecoder().decode(T.self, from: clean)
    }

    // MARK: - Auth Check

    /// Verify the CLI can talk to Azure DevOps (user must be `az login`-ed).
    public func verifyAuth() async throws -> Bool {
        do {
            let data = try await runAz([
                "devops", "project", "list",
                "--org", orgUrl,
                "--query", "[0].name",
                "-o", "tsv"
            ])
            let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            dbg.info("AzDO auth verified — first project: \(name)", category: "azdo-auth")
            return !name.isEmpty
        } catch {
            dbg.error("AzDO auth verification failed: \(error)", category: "azdo-auth")
            return false
        }
    }

    // MARK: - Work Items

    /// Query work items via WIQL using `az boards query`.
    func queryWorkItems(_ wiql: String) async throws -> [WorkItem] {
        dbg.debug("AzDO queryWorkItems: \(wiql.prefix(120))...", category: "azdo")

        let data = try await runAz([
            "boards", "query",
            "--wiql", wiql,
            "--org", orgUrl,
            "--project", project,
            "-o", "json"
        ])

        // `az boards query` returns array of work items directly (with fields populated)
        let clean = data.dropBOM()
        let items = try JSONDecoder().decode([AzCliWorkItem].self, from: clean)
        dbg.info("AzDO query returned \(items.count) work items", category: "azdo")
        return items.map { $0.toWorkItem() }
    }

    public func getWorkItem(id: Int) async throws -> WorkItem? {
        dbg.debug("AzDO getWorkItem(\(id))", category: "azdo")
        let data = try await runAz([
            "boards", "work-item", "show",
            "--id", String(id),
            "--org", orgUrl,
            "-o", "json"
        ])
        let clean = data.dropBOM()
        let item = try JSONDecoder().decode(AzCliWorkItem.self, from: clean)
        return item.toWorkItem()
    }

    public func getWorkItemsByIds(_ ids: [Int]) async throws -> [WorkItem] {
        guard !ids.isEmpty else { return [] }
        // az boards work-item show only takes one ID — use WIQL instead
        let idList = ids.map { String($0) }.joined(separator: ",")
        let wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.Id] IN (\(idList))"
        return try await queryWorkItems(wiql)
    }

    public func getWorkItems(state: String? = nil, type: String? = nil, assignedTo: String? = nil, limit: Int = 50) async throws -> [WorkItem] {
        var conditions = ["[System.TeamProject] = @project"]
        if let state = state { conditions.append("[System.State] = '\(state)'") }
        if let type = type { conditions.append("[System.WorkItemType] = '\(type)'") }
        if let assignedTo = assignedTo { conditions.append("[System.AssignedTo] = '\(assignedTo)'") }
        let wiql = "SELECT [System.Id] FROM WorkItems WHERE \(conditions.joined(separator: " AND ")) ORDER BY [System.ChangedDate] DESC"
        let items = try await queryWorkItems(wiql)
        return Array(items.prefix(limit))
    }

    public func createWorkItem(_ request: CreateWorkItemRequest) async throws -> WorkItem? {
        dbg.info("AzDO createWorkItem: \(request.title)", category: "azdo")
        var args: [String] = [
            "boards", "work-item", "create",
            "--title", request.title,
            "--type", request.type,
            "--org", orgUrl,
            "--project", project,
            "-o", "json"
        ]
        if let desc = request.description { args += ["--description", desc] }
        if let assignee = request.assignedTo { args += ["--assigned-to", assignee] }
        if let iter = request.iterationPath { args += ["--iteration-path", iter] }
        if let area = request.areaPath { args += ["--area-path", area] }

        // Fields that aren't direct flags go via --fields
        var fields: [String] = []
        if let priority = request.priority { fields.append("Microsoft.VSTS.Common.Priority=\(priority)") }
        if let tags = request.tags, !tags.isEmpty { fields.append("System.Tags=\(tags.joined(separator: "; "))") }
        if !fields.isEmpty { args += ["--fields"] + fields }

        let data = try await runAz(args)
        let clean = data.dropBOM()
        let item = try JSONDecoder().decode(AzCliWorkItem.self, from: clean)
        return item.toWorkItem()
    }

    public func updateWorkItem(id: Int, request: UpdateWorkItemRequest) async throws -> WorkItem? {
        dbg.info("AzDO updateWorkItem(\(id))", category: "azdo")
        var args: [String] = [
            "boards", "work-item", "update",
            "--id", String(id),
            "--org", orgUrl,
            "-o", "json"
        ]
        if let title = request.title { args += ["--title", title] }
        if let state = request.state { args += ["--state", state] }
        if let assignee = request.assignedTo { args += ["--assigned-to", assignee] }
        if let iter = request.iterationPath { args += ["--iteration-path", iter] }
        if let comment = request.comment { args += ["--discussion", comment] }

        var fields: [String] = []
        if let priority = request.priority { fields.append("Microsoft.VSTS.Common.Priority=\(priority)") }
        if !fields.isEmpty { args += ["--fields"] + fields }

        let data = try await runAz(args)
        let clean = data.dropBOM()
        let item = try JSONDecoder().decode(AzCliWorkItem.self, from: clean)
        return item.toWorkItem()
    }

    // MARK: - Sprints / Iterations

    public func getSprints(forceRefresh: Bool = false) async throws -> [Sprint] {
        if !forceRefresh, let cached = sprintCache, Date() < sprintCacheExpiry {
            dbg.debug("AzDO getSprints: using cache (\(cached.count) sprints)", category: "azdo")
            return cached
        }

        dbg.info("AzDO getSprints via az boards iteration", category: "azdo")

        // First get the default team
        let team = try await getDefaultTeam()

        let data = try await runAz([
            "boards", "iteration", "team", "list",
            "--team", team,
            "--org", orgUrl,
            "--project", project,
            "-o", "json"
        ])
        let clean = data.dropBOM()
        let cliIterations = try JSONDecoder().decode([AzCliIteration].self, from: clean)
        let sprints = cliIterations.map { $0.toSprint() }

        sprintCache = sprints
        sprintCacheExpiry = Date().addingTimeInterval(cacheDuration)
        dbg.info("AzDO getSprints: \(sprints.count) sprints loaded", category: "azdo")
        return sprints
    }

    public func getCurrentSprint() async throws -> Sprint? {
        let sprints = try await getSprints()
        return sprints.first { $0.isCurrent }
    }

    /// Get the default team name for the project.
    private func getDefaultTeam() async throws -> String {
        let data = try await runAz([
            "devops", "team", "list",
            "--org", orgUrl,
            "--project", project,
            "-o", "json"
        ])
        let clean = data.dropBOM()
        struct AzTeam: Decodable { let name: String; let id: String }
        let teams = try JSONDecoder().decode([AzTeam].self, from: clean)
        // Convention: default team is usually "{project} Team" or the first one
        let defaultTeam = teams.first { $0.name == "\(project) Team" } ?? teams.first
        let name = defaultTeam?.name ?? project
        dbg.debug("AzDO default team: \(name)", category: "azdo")
        return name
    }

    // MARK: - Boards

    public func getBoards() async throws -> [Board] {
        // az boards doesn't have a direct list command — use invoke
        let data = try await runAz([
            "devops", "invoke",
            "--area", "work",
            "--resource", "boards",
            "--org", orgUrl,
            "--route-parameters", "project=\(project)", "team=\(project) Team",
            "--api-version", "7.0",
            "-o", "json"
        ])
        let clean = data.dropBOM()
        let response = try JSONDecoder().decode(BoardsResponse.self, from: clean)
        return response.value ?? []
    }

    // MARK: - Projects (list from org)

    public func listProjects() async throws -> [AzCliProject] {
        dbg.info("AzDO listProjects via az devops project list", category: "azdo")
        let data = try await runAz([
            "devops", "project", "list",
            "--org", orgUrl,
            "-o", "json"
        ])
        let clean = data.dropBOM()
        let response = try JSONDecoder().decode(AzCliProjectList.self, from: clean)
        return response.value ?? []
    }

    // MARK: - Error Creation

    public func createFromError(deviceName: String, itemName: String, errorMessage: String, assignedTo: String? = nil, priority: Int = 2) async throws -> WorkItem? {
        let title = "[FleetMate] \(itemName) failed on \(deviceName)"
        let description = """
        <h3>Installation Failure</h3>
        <p><strong>Device:</strong> \(deviceName)</p>
        <p><strong>Package:</strong> \(itemName)</p>
        <p><strong>Error:</strong></p>
        <pre>\(errorMessage)</pre>
        <hr/>
        <p><em>Created automatically by FleetMate</em></p>
        """
        let request = CreateWorkItemRequest(
            title: title,
            type: config.devopsDefaultWorkItemType,
            description: description,
            assignedTo: assignedTo,
            priority: priority,
            tags: ["FleetMate", "AutoGenerated", itemName]
        )
        return try await createWorkItem(request)
    }

    // Keep SSO-related API surface for backward compat (no-ops now)
    public var requiresSsoLogin: Bool { false }
    public var hasSsoToken: Bool { false }
    public func setSsoToken(_ token: String, expiry: Date, userId: String?, userName: String?) {}
    public func clearSsoToken() {}
}

// MARK: - Error

public enum AzDevOpsError: Error, LocalizedError {
    case cliError(code: Int32, message: String)
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .cliError(let code, let message):
            return "az CLI error (\(code)): \(message)"
        case .notLoggedIn:
            return "Not logged in. Run 'az login' first."
        }
    }
}

// MARK: - az CLI JSON models

/// Work item as returned by `az boards query` / `az boards work-item show`.
struct AzCliWorkItem: Decodable {
    let id: Int
    let rev: Int?
    let url: String?
    let fields: [String: AnyCodable]?

    func toWorkItem() -> WorkItem {
        let f = fields ?? [:]
        let assignedToDict = f["System.AssignedTo"]?.dictValue
        let assignedTo = assignedToDict.map { d in
            IdentityRef(
                displayName: d["displayName"] as? String,
                uniqueName: d["uniqueName"] as? String,
                id: d["id"] as? String
            )
        }
        return WorkItem(
            id: id,
            rev: rev,
            fields: WorkItemFields(
                title: f["System.Title"]?.stringValue,
                state: f["System.State"]?.stringValue,
                workItemType: f["System.WorkItemType"]?.stringValue,
                assignedTo: assignedTo,
                createdDate: f["System.CreatedDate"]?.stringValue,
                changedDate: f["System.ChangedDate"]?.stringValue,
                description: f["System.Description"]?.stringValue,
                priority: f["Microsoft.VSTS.Common.Priority"]?.intValue,
                iterationPath: f["System.IterationPath"]?.stringValue,
                areaPath: f["System.AreaPath"]?.stringValue,
                tags: f["System.Tags"]?.stringValue
            ),
            url: url
        )
    }
}

/// Iteration as returned by `az boards iteration team list`.
struct AzCliIteration: Decodable {
    let id: String?
    let name: String?
    let path: String?
    let attributes: AzCliIterationAttributes?
    let url: String?

    func toSprint() -> Sprint {
        Sprint(
            id: id,
            name: name,
            path: path,
            attributes: attributes.map {
                SprintAttributes(startDate: $0.startDate, finishDate: $0.finishDate, timeFrame: $0.timeFrame)
            },
            url: url
        )
    }
}

struct AzCliIterationAttributes: Decodable {
    let startDate: String?
    let finishDate: String?
    let timeFrame: String?
}

/// Project list wrapper from `az devops project list`.
public struct AzCliProjectList: Decodable {
    public let value: [AzCliProject]?
}

public struct AzCliProject: Decodable {
    public let id: String
    public let name: String
    public let state: String?
}

// MARK: - AnyCodable convenience (uses public AnyCodable from ReportMateModels)

extension AnyCodable {
    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var dictValue: [String: Any]? { value as? [String: Any] }
}

// MARK: - Data BOM helper

extension Data {
    /// Drop UTF-8 BOM if present (az CLI sometimes adds it).
    func dropBOM() -> Data {
        if count >= 3, self[0] == 0xEF, self[1] == 0xBB, self[2] == 0xBF {
            return self.dropFirst(3).asData
        }
        return self
    }
}

private extension Data.SubSequence {
    var asData: Data { Data(self) }
}

// MARK: - Helpers

extension Array where Element == Int {
    func chunked(into size: Int) -> [[Int]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
