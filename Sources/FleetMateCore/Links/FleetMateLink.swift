import Foundation

/// Something a `fleetmate://` link opens. One parser for the app's URL
/// handler and the CLI, which prints links.
///
/// Routes:
///
///     fleetmate://pull/<project>/<repo>/<id>                Azure DevOps PR
///     fleetmate://pull/github/<owner>/<repo>/<number>       GitHub PR
///     fleetmate://commit/<project>/<repo>/<sha>
///     fleetmate://commit/github/<owner>/<repo>/<sha>
///     fleetmate://pipeline/<project>/<runId>                Azure DevOps run
///     fleetmate://pipeline/<project>/definition/<id>        Azure DevOps pipeline
///     fleetmate://pipeline/github/<owner>/<repo>/<runId>    Actions run
///     fleetmate://workitem/<id>
///     fleetmate://issue/github/<owner>/<repo>/<number>
///     fleetmate://device/<id>   asset/<id>   ticket/<id>
///     fleetmate://user/<id or UPN>   group/<id>
///     fleetmate://open?url=<web URL of any of the above>
public enum FleetMateLink: Hashable, Sendable {
    public enum Host: Hashable, Sendable {
        /// Azure DevOps project and repository.
        case azureDevOps(project: String, repo: String)
        /// GitHub owner and repository.
        case gitHub(owner: String, repo: String)
    }

    case pullRequest(Host, number: Int)
    case commit(Host, sha: String)
    case azureDevOpsRun(project: String, runId: Int)
    case azureDevOpsPipeline(project: String, definitionId: Int)
    case gitHubRun(owner: String, repo: String, runId: Int)
    case workItem(id: Int)
    case gitHubIssue(owner: String, repo: String, number: Int)
    /// An Intune managed device, by its id.
    case device(id: String)
    /// A Snipe-IT asset, by its numeric id.
    case asset(id: Int)
    /// A TeamDynamix ticket, by its number.
    case ticket(id: Int)
    /// An Entra user or group, by object id or user principal name.
    case user(id: String)
    case group(id: String)
    /// A page of the Reporting tab, carried as the equivalent `reportmate://`
    /// link: `fleetmate://reporting/device/<serial>?tab=installs` opens what
    /// `reportmate://device/<serial>?tab=installs` opens in ReportMate.
    case reporting(URL)

    public static let scheme = "fleetmate"

    // MARK: Parse

    /// A link arrives from anywhere — a web page, a chat message — and its
    /// names end up in API paths, so each must be a plain name: no slashes,
    /// no `.`/`..`, no query or fragment characters.
    public static func parse(_ url: URL) throws -> FleetMateLink {
        let link = try parseUnchecked(url)
        guard link.names.allSatisfy(isSafeName) else {
            throw FleetMateLinkError.malformed(url.absoluteString, expected: "plain project, owner and repository names")
        }
        return link
    }

    public static func parseWeb(_ url: URL) throws -> FleetMateLink {
        let link = try parseWebUnchecked(url)
        guard link.names.allSatisfy(isSafeName) else { throw FleetMateLinkError.unsupportedWebURL(url.absoluteString) }
        return link
    }

    private var names: [String] {
        switch self {
        case .pullRequest(let host, _), .commit(let host, _):
            switch host {
            case .azureDevOps(let p, let r): return [p, r]
            case .gitHub(let o, let r): return [o, r]
            }
        case .azureDevOpsRun(let p, _), .azureDevOpsPipeline(let p, _): return [p]
        case .gitHubRun(let o, let r, _), .gitHubIssue(let o, let r, _): return [o, r]
        case .workItem, .device, .asset, .ticket, .user, .group, .reporting: return []
        }
    }

    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_. ".unicodeScalars.contains($0)
        }
    }

    private static func parseUnchecked(_ url: URL) throws -> FleetMateLink {
        guard url.scheme?.lowercased() == scheme else { throw FleetMateLinkError.notFleetMate(url.absoluteString) }
        let route = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }

        switch route {
        case "pull":
            if parts.first?.lowercased() == "github" {
                guard parts.count == 4, let n = Int(parts[3]) else { throw bad(url, "fleetmate://pull/github/<owner>/<repo>/<number>") }
                return .pullRequest(.gitHub(owner: parts[1], repo: parts[2]), number: n)
            }
            guard parts.count == 3, let n = Int(parts[2]) else { throw bad(url, "fleetmate://pull/<project>/<repo>/<id>") }
            return .pullRequest(.azureDevOps(project: parts[0], repo: parts[1]), number: n)

        case "commit":
            if parts.first?.lowercased() == "github" {
                guard parts.count == 4, isSHA(parts[3]) else { throw bad(url, "fleetmate://commit/github/<owner>/<repo>/<sha>") }
                return .commit(.gitHub(owner: parts[1], repo: parts[2]), sha: parts[3])
            }
            guard parts.count == 3, isSHA(parts[2]) else { throw bad(url, "fleetmate://commit/<project>/<repo>/<sha>") }
            return .commit(.azureDevOps(project: parts[0], repo: parts[1]), sha: parts[2])

        case "pipeline":
            if parts.first?.lowercased() == "github" {
                guard parts.count == 4, let id = Int(parts[3]) else { throw bad(url, "fleetmate://pipeline/github/<owner>/<repo>/<runId>") }
                return .gitHubRun(owner: parts[1], repo: parts[2], runId: id)
            }
            if parts.count == 3, parts[1].lowercased() == "definition", let id = Int(parts[2]) {
                return .azureDevOpsPipeline(project: parts[0], definitionId: id)
            }
            guard parts.count == 2, let id = Int(parts[1]) else { throw bad(url, "fleetmate://pipeline/<project>/<runId>") }
            return .azureDevOpsRun(project: parts[0], runId: id)

        case "workitem":
            guard parts.count == 1, let id = Int(parts[0]) else { throw bad(url, "fleetmate://workitem/<id>") }
            return .workItem(id: id)

        case "issue":
            guard parts.count == 4, parts[0].lowercased() == "github", let n = Int(parts[3]) else {
                throw bad(url, "fleetmate://issue/github/<owner>/<repo>/<number>")
            }
            return .gitHubIssue(owner: parts[1], repo: parts[2], number: n)

        case "device", "user", "group":
            guard parts.count == 1, isSafeIdentifier(parts[0]) else { throw bad(url, "fleetmate://\(route)/<id>") }
            switch route {
            case "device": return .device(id: parts[0])
            case "user": return .user(id: parts[0])
            default: return .group(id: parts[0])
            }

        case "asset", "ticket":
            guard parts.count == 1, let id = Int(parts[0]) else { throw bad(url, "fleetmate://\(route)/<number>") }
            return route == "asset" ? .asset(id: id) : .ticket(id: id)

        case "reporting":
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "reportmate"
            comps?.host = parts.first ?? "dashboard"
            comps?.percentEncodedPath = parts.dropFirst().map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) }.joined()
            guard let target = comps?.url else { throw bad(url, "fleetmate://reporting/<ReportMate page>") }
            return .reporting(target)

        case "open":
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            guard let target, let web = URL(string: target) else { throw bad(url, "fleetmate://open?url=<web URL>") }
            return try parseWeb(web)

        default:
            throw FleetMateLinkError.unknownRoute(route.isEmpty ? url.absoluteString : route)
        }
    }

    /// A web URL from Azure DevOps or GitHub. Azure DevOps is recognised by its
    /// path shape (`/_git/`, `/_build`, `/_workitems/`), not its host, so
    /// any server name works.
    private static func parseWebUnchecked(_ url: URL) throws -> FleetMateLink {
        let parts = url.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> Int? { query.first { $0.name.lowercased() == name.lowercased() }?.value.flatMap(Int.init) }

        if url.host?.lowercased() == "github.com" {
            guard parts.count >= 4 else { throw FleetMateLinkError.unsupportedWebURL(url.absoluteString) }
            let (owner, repo, kind, rest) = (parts[0], parts[1], parts[2], Array(parts.dropFirst(3)))
            switch kind {
            case "pull":
                if let n = Int(rest[0]) { return .pullRequest(.gitHub(owner: owner, repo: repo), number: n) }
            case "commit":
                if isSHA(rest[0]) { return .commit(.gitHub(owner: owner, repo: repo), sha: rest[0]) }
            case "issues":
                if let n = Int(rest[0]) { return .gitHubIssue(owner: owner, repo: repo, number: n) }
            case "actions":
                if rest.count >= 2, rest[0] == "runs", let id = Int(rest[1]) {
                    return .gitHubRun(owner: owner, repo: repo, runId: id)
                }
            default: break
            }
            throw FleetMateLinkError.unsupportedWebURL(url.absoluteString)
        }

        // Azure DevOps: …/<org>/<project>/_git/<repo>/pullrequest/<id>, and
        // the same with the org as a subdomain (no org segment).
        if let git = parts.firstIndex(of: "_git"), git >= 1, parts.count > git + 3 {
            let project = parts[git - 1], repo = parts[git + 1]
            switch parts[git + 2].lowercased() {
            case "pullrequest":
                if let n = Int(parts[git + 3]) { return .pullRequest(.azureDevOps(project: project, repo: repo), number: n) }
            case "commit":
                if isSHA(parts[git + 3]) { return .commit(.azureDevOps(project: project, repo: repo), sha: parts[git + 3]) }
            default: break
            }
        }
        if let build = parts.firstIndex(where: { $0.hasPrefix("_build") }), build >= 1 {
            let project = parts[build - 1]
            if let id = item("buildId") { return .azureDevOpsRun(project: project, runId: id) }
            if let id = item("definitionId") { return .azureDevOpsPipeline(project: project, definitionId: id) }
        }
        if let edit = parts.firstIndex(of: "edit"), edit >= 1, parts[edit - 1] == "_workitems",
           parts.count > edit + 1, let id = Int(parts[edit + 1]) {
            return .workItem(id: id)
        }
        throw FleetMateLinkError.unsupportedWebURL(url.absoluteString)
    }

    // MARK: Build

    /// The link's canonical `fleetmate://` form.
    public var url: URL {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
        let path: String
        switch self {
        case .pullRequest(.azureDevOps(let p, let r), let n): path = "pull/\(enc(p))/\(enc(r))/\(n)"
        case .pullRequest(.gitHub(let o, let r), let n): path = "pull/github/\(enc(o))/\(enc(r))/\(n)"
        case .commit(.azureDevOps(let p, let r), let sha): path = "commit/\(enc(p))/\(enc(r))/\(sha)"
        case .commit(.gitHub(let o, let r), let sha): path = "commit/github/\(enc(o))/\(enc(r))/\(sha)"
        case .azureDevOpsRun(let p, let id): path = "pipeline/\(enc(p))/\(id)"
        case .azureDevOpsPipeline(let p, let id): path = "pipeline/\(enc(p))/definition/\(id)"
        case .gitHubRun(let o, let r, let id): path = "pipeline/github/\(enc(o))/\(enc(r))/\(id)"
        case .workItem(let id): path = "workitem/\(id)"
        case .gitHubIssue(let o, let r, let n): path = "issue/github/\(enc(o))/\(enc(r))/\(n)"
        case .device(let id): path = "device/\(enc(id))"
        case .asset(let id): path = "asset/\(id)"
        case .ticket(let id): path = "ticket/\(id)"
        case .user(let id): path = "user/\(enc(id))"
        case .group(let id): path = "group/\(enc(id))"
        case .reporting(let target):
            var comps = URLComponents(url: target, resolvingAgainstBaseURL: false)
            comps?.scheme = Self.scheme
            comps?.path = "/" + (target.host ?? "dashboard") + target.path
            comps?.host = "reporting"
            if let url = comps?.url { return url }
            path = "reporting"
        }
        return URL(string: "\(Self.scheme)://\(path)")!
    }

    /// Device ids are GUIDs; users may be a UPN. No slashes or query marks.
    static func isSafeIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.@".unicodeScalars.contains($0)
        }
    }

    private static func isSHA(_ s: String) -> Bool {
        (7...40).contains(s.count) && s.allSatisfy(\.isHexDigit)
    }

    private static func bad(_ url: URL, _ expected: String) -> FleetMateLinkError {
        .malformed(url.absoluteString, expected: expected)
    }
}

public enum FleetMateLinkError: Error, LocalizedError, Equatable {
    case notFleetMate(String)
    case unknownRoute(String)
    case malformed(String, expected: String)
    case unsupportedWebURL(String)

    public var errorDescription: String? {
        switch self {
        case .notFleetMate(let s): return "Not a fleetmate:// link: \(s)"
        case .unknownRoute(let r): return "FleetMate doesn't know the link \"\(r)\". Links open pull, commit, pipeline, workitem, issue, device, asset, ticket, user, group or open?url=."
        case .malformed(let s, let expected): return "The link \(s) is incomplete. Expected \(expected)."
        case .unsupportedWebURL(let s): return "FleetMate can't open \(s). It takes Azure DevOps or GitHub pull request, commit, pipeline, work item and issue URLs."
        }
    }
}
