import ArgumentParser
import FleetMateCore
import Foundation

struct DevOpsReposCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repos", abstract: "Manage Azure Repos and pull requests",
        discussion: DevOpsResourceArguments.help(for: "repos")
    )
    @OptionGroup var arguments: DevOpsResourceArguments

    func run() async throws {
        try await arguments.run(group: "repos")
    }
}

struct DevOpsPipelinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pipelines", abstract: "Manage Azure Pipelines, builds and releases",
        discussion: DevOpsResourceArguments.help(for: "pipelines")
    )
    @OptionGroup var arguments: DevOpsResourceArguments

    func run() async throws {
        try await arguments.run(group: "pipelines")
    }
}

struct DevOpsResourceArguments: ParsableArguments {
    @Argument(help: "Operation, for example 'pr create', 'runs list' or 'api' (see help)")
    var operation: [String] = []

    @Option(help: "Azure DevOps project name or ID (defaults to the configured project)")
    var project: String?

    @Option(help: "Repository name or ID")
    var repository: String?

    @Option(help: "Primary resource ID")
    var id: Int?

    @Option(help: "Nested resource ID or name, such as a reviewer ID, run ID or tag")
    var resource: String?

    @Option(help: "Source branch name or refs/heads reference (PR creation)")
    var sourceBranch: String?

    @Option(help: "Target branch name or refs/heads reference (PR creation)")
    var targetBranch: String?

    @Option(help: "Title of the pull request")
    var title: String?

    @Option(help: "Description of the pull request")
    var description: String?

    @Flag(help: "Create a draft pull request")
    var draft = false

    @Option(help: "approve, approve-with-suggestions, wait-for-author, reject or reset")
    var vote: String?

    @Option(help: "Pull request comment text")
    var text: String?

    @Option(help: "JSON request body")
    var body: String?

    @Option(help: "Path to a file containing the JSON request body")
    var bodyFile: String?

    @Option(help: "Add a query parameter as NAME=VALUE (repeatable)")
    var query: [String] = []

    @Option(help: "Relative path under _apis (for the api operation)")
    var apiPath: String?

    @Option(help: "HTTP method for the api operation")
    var method: String = "GET"

    @Option(help: "API version (overrides the operation default)")
    var apiVersion: String?

    @Flag(help: "Use organization scope for the api operation")
    var organizationScope = false

    @Flag(help: "Use the Classic Release service for the api operation")
    var releases = false

    @Flag(help: "Send an application/json-patch+json body")
    var jsonPatch = false

    @Flag(help: "Output JSON (the operation response is JSON when provided by Azure DevOps)")
    var json = false

    @Option(help: "Write the response to a file, for example a downloaded log")
    var outputFile: String?

    private struct Route {
        let name: String
        let method: String
        let path: String
        let version: String
        let scope: String
    }

    private static func routes(for group: String) -> [Route] {
        devOpsOperationCatalog.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "|").map(String.init)
            guard fields[0] == group else { return nil }
            return Route(name: fields[1], method: fields[2], path: fields[3], version: fields[4],
                         scope: fields.count > 5 ? fields[5] : "project")
        }
    }

    private static let pullRequestActions = ["pr complete", "pr approve", "pr set-vote", "pr comment"]

    static func help(for group: String) -> String {
        let names = routes(for: group).map(\.name) + (group == "repos" ? pullRequestActions : [])
        return "Operations:\n  " + (names.sorted() + ["api"]).joined(separator: "\n  ")
            + "\nUse --body or --body-file for a request payload and --query NAME=VALUE for filters."
    }

    func run(group: String) async throws {
        let name = operation.joined(separator: " ")
        if group == "repos", Self.pullRequestActions.contains(name) {
            try await runPullRequestAction(name)
            return
        }

        let route: Route
        if name == "api" {
            let path = try required(apiPath, "--api-path")
            let relative = path.hasPrefix("/_apis/") ? String(path.dropFirst("/_apis/".count)) : path
            let area = group == "repos" ? ["git", "policy", "wit"] : ["pipelines", "build", "distributedtask", "release", "task", "test", "testresults", "serviceendpoint", "securityroles"]
            let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard let first = segments.first, area.contains(String(first)),
                  segments.allSatisfy({ part in
                      guard let decoded = part.removingPercentEncoding else { return false }
                      return !decoded.isEmpty && decoded != "." && decoded != ".."
                          && decoded.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#%").union(.controlCharacters)) == nil
                  }),
                  ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method.uppercased()) else {
                throw ValidationError("Use a relative API resource in the \(group) area and a supported HTTP method.")
            }
            route = Route(name: name, method: method.uppercased(), path: relative, version: "7.1",
                          scope: releases || first == "release" ? "release" : (organizationScope ? "org" : "project"))
        } else {
            guard let known = Self.routes(for: group).first(where: { $0.name == name }) else {
                throw ValidationError("Unknown operation. See fleetmate devops \(group) --help.")
            }
            route = known
        }

        let path = try requestPath(route, name: name)
        var payload = try requestBody(name: name, group: group)
        let service = try await connect(orgLevel: route.scope == "org")
        if name == "pr auto-complete", payload == nil {
            let identity = await service.currentIdentity()
            guard let identityID = identity.id else {
                throw ValidationError("Could not resolve your Azure DevOps identity.")
            }
            payload = try JSONSerialization.data(withJSONObject: ["autoCompleteSetBy": ["id": identityID]])
        }
        let data = try await service.requestData(
            route.method, path: path, body: payload,
            contentType: jsonPatch ? "application/json-patch+json" : "application/json",
            orgLevel: route.scope == "org", forProject: project.map(Self.escape),
            releases: route.scope == "release"
        )
        try printResponse(data, service: service, name: name)
    }

    private func printResponse(_ data: Data, service: AzureDevOpsService, name: String) throws {
        if let outputFile {
            try data.write(to: URL(fileURLWithPath: outputFile), options: .atomic)
        } else if !json, name == "pr create", let result = try? JSONDecoder().decode(GitPullRequest.self, from: data),
                  let repo = result.repository?.name ?? repository {
            print(AzureDevOpsService.pullRequestWebUrl(
                orgUrl: service.baseUrl, project: result.repository?.project?.name ?? project ?? service.resolvedProject,
                repository: repo, pullRequestId: result.id
            ))
        } else {
            print(String(decoding: data.isEmpty ? Data("null".utf8) : data, as: UTF8.self))
        }
    }

    private func runPullRequestAction(_ name: String) async throws {
        guard body == nil, bodyFile == nil, outputFile == nil else {
            throw ValidationError("This action takes named options. See --help.")
        }
        let repo = try required(repository, "--repository")
        guard repo.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#%").union(.controlCharacters)) == nil,
              repo != ".", repo != ".." else {
            throw ValidationError("--repository must be a repository name or ID.")
        }
        let number = try requiredID()
        let selectedVote: PullRequestReviewVote?
        switch name {
        case "pr approve": selectedVote = .approved
        case "pr set-vote":
            let votes: [String: Int] = [
                "approve": 10, "approve-with-suggestions": 5, "wait-for-author": -5, "reject": -10, "reset": 0
            ]
            guard let raw = vote.flatMap({ votes[$0] }), let value = PullRequestReviewVote(rawValue: raw) else {
                throw ValidationError("Choose a supported --vote value. See --help.")
            }
            selectedVote = value
        default: selectedVote = nil
        }
        let message = name == "pr comment" ? try required(text, "--text") : nil
        let service = try await connect()
        let projectPath = project.map(Self.escape)
        if let selectedVote {
            try await service.votePullRequest(repository: repo, pullRequestId: number, project: projectPath, vote: selectedVote)
            print(json ? "null" : "Azure DevOps accepted the operation.")
        } else if let message {
            try await service.comment(repository: repo, pullRequestId: number, project: projectPath, text: message)
            print(json ? "null" : "Azure DevOps accepted the operation.")
        } else {
            let result = try await service.completePullRequest(repository: repo, pullRequestId: number, project: projectPath)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        }
    }

    private func connect(orgLevel: Bool = false) async throws -> AzureDevOpsService {
        let config = try FleetMateConfig.load()
        return try await DevOpsCliSignIn.authenticatedService(
            config: config, resolveProject: project == nil && !orgLevel
        )
    }

    private func requestPath(_ route: Route, name: String) throws -> String {
        var path = route.path
        if path.contains("{repository}") {
            path = path.replacingOccurrences(of: "{repository}", with: Self.escape(try required(repository, "--repository")))
        }
        if path.contains("{id}") {
            path = path.replacingOccurrences(of: "{id}", with: String(try requiredID()))
        }
        if path.contains("{resource}") {
            path = path.replacingOccurrences(of: "{resource}", with: Self.escape(try required(resource, "--resource")))
        }
        var items = [URLQueryItem(name: "api-version", value: apiVersion ?? route.version)]
        for item in query {
            guard let index = item.firstIndex(of: "="), index != item.startIndex else {
                throw ValidationError("Query parameters use NAME=VALUE.")
            }
            let key = String(item[..<index])
            guard key.lowercased() != "api-version" else { throw ValidationError("Use --api-version to select the API version.") }
            items.append(URLQueryItem(name: key, value: String(item[item.index(after: index)...])))
        }
        if name == "ref lock" || name == "ref unlock" {
            let ref = try branchRef(resource, "--resource")
            items.append(URLQueryItem(name: "filter", value: String(ref.dropFirst("refs/".count))))
        }
        if name == "build artifact show" {
            items.append(URLQueryItem(name: "artifactName", value: try required(resource, "--resource")))
        }
        var components = URLComponents()
        components.queryItems = items
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return "/_apis/\(path)?\(encoded)"
    }

    private func requestBody(name: String, group: String) throws -> Data? {
        if body != nil && bodyFile != nil {
            throw ValidationError("Use either --body or --body-file.")
        }
        if let source = body.map({ Data($0.utf8) }) {
            _ = try JSONSerialization.jsonObject(with: source, options: .fragmentsAllowed)
            return source
        }
        if let bodyFile {
            let source = try Data(contentsOf: URL(fileURLWithPath: bodyFile))
            _ = try JSONSerialization.jsonObject(with: source, options: .fragmentsAllowed)
            return source
        }

        if group == "pipelines", name == "approval approve" || name == "approval reject" {
            let approval = try required(resource, "--resource")
            guard UUID(uuidString: approval) != nil else {
                throw ValidationError("--resource must be an approval UUID.")
            }
            return try JSONSerialization.data(withJSONObject: [[
                "approvalId": approval, "status": name == "approval approve" ? "approved" : "rejected",
                "comment": text ?? ""
            ]])
        }
        let fields: [String: Any]
        switch (group, name) {
        case ("repos", "pr create"):
            let source = try branchRef(sourceBranch, "--source-branch")
            let target = try branchRef(targetBranch, "--target-branch")
            guard source != target else { throw ValidationError("Source and target branches must differ.") }
            fields = ["sourceRefName": source, "targetRefName": target, "title": try required(title, "--title"),
                      "description": description ?? "", "isDraft": draft]
        case ("repos", "pr abandon"): fields = ["status": "abandoned"]
        case ("repos", "pr reopen"): fields = ["status": "active"]
        case ("repos", "pr ready"): fields = ["isDraft": false]
        case ("repos", "pr draft"): fields = ["isDraft": true]
        case ("repos", "ref lock"): fields = ["isLocked": true]
        case ("repos", "ref unlock"): fields = ["isLocked": false]
        case ("pipelines", "build cancel"), ("pipelines", "runs cancel"): fields = ["status": "cancelling"]
        case ("pipelines", "run"): fields = [:]
        default: return nil
        }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    private func required(_ value: String?, _ option: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("\(option) is required.")
        }
        return value
    }

    private func requiredID() throws -> Int {
        guard let id, id > 0 else { throw ValidationError("--id must be a positive integer.") }
        return id
    }

    private func branchRef(_ value: String?, _ option: String) throws -> String {
        let branch = try required(value, option)
        let prefix = "refs/heads/"
        guard branch != prefix, !branch.hasPrefix("refs/") || branch.hasPrefix(prefix) else {
            throw ValidationError("\(option) must name a branch.")
        }
        return branch.hasPrefix(prefix) ? branch : prefix + branch
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }
}
