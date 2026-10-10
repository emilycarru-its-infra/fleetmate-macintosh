import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

/// `fleetmate repos` — the team's core repositories across Azure DevOps and
/// GitHub: what exists, where it is checked out, and git on those checkouts.
/// Every listing takes `--json`; agents are the main users.
struct ReposCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repos",
        abstract: "Manage core repositories across Azure DevOps and GitHub",
        discussion: """
        Repository arguments accept a name, project/name (Azure DevOps), owner/name
        (GitHub), org/project/name, a registry id (github:owner/name), or a path to a
        registered checkout. Batch commands (status, fetch, pull) act on every tracked
        repository when none is named.

        The registry lives in repos.json in FleetMate's support folder, the catalog
        cache in repos-catalog.json beside it.
        """,
        subcommands: [
            ReposCatalogCommand.self,
            ReposListCommand.self,
            ReposDiscoverCommand.self,
            ReposLinkCommand.self,
            ReposCloneCommand.self,
            ReposUnlinkCommand.self,
            ReposTrackCommand.self,
            ReposUntrackCommand.self,
            ReposStatusCommand.self,
            ReposFetchCommand.self,
            ReposPullCommand.self,
            ReposPushCommand.self,
            ReposCommitCommand.self,
            ReposBranchCommand.self,
            ReposDiffCommand.self,
            ReposLogCommand.self,
            ReposStatsCommand.self,
            ReposFilesCommand.self,
            ReposGrepCommand.self,
            ReposSettingsCommand.self,
        ],
        defaultSubcommand: ReposListCommand.self
    )
}

// MARK: - Shared helpers

enum ReposCLI {
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// Fails the command with the error's message instead of a stack of
    /// ArgumentParser noise.
    static func fail(_ error: Error) -> ExitCode {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        return ExitCode.failure
    }

    /// The catalog service for this machine's configuration: Azure DevOps with
    /// a silent `az` token, GitHub with the gh/env token.
    static func catalogService(config: FleetMateConfig, settings: RepoSettings, provider: String?) async -> (RepoCatalogService, [String]) {
        var errors: [String] = []
        let wantsAzure = provider == nil || provider == "azdo"
        let wantsGitHub = provider == nil || provider == "github"

        var azure: AzureDevOpsService?
        let org = config.tasks?.providers.azdevops?.organization ?? config.devopsOrganization
        if wantsAzure, let org, !org.isEmpty {
            let sso = DevOpsSsoService(tenantId: config.devopsTenantId ?? config.graphTenantId)
            if let result = try? await sso.refreshAccessToken(), result.success, let token = result.accessToken {
                let service = AzureDevOpsService(config: config)
                service.setBearerToken(token, expiry: Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600)))
                azure = service
            } else {
                errors.append("Azure DevOps: could not get a token silently (run 'az login')")
            }
        }

        let gh = config.tasks?.providers.github
        let owners = settings.gitHubOwners + [gh?.owner, gh?.organization].compactMap { $0 }
        let service = RepoCatalogService(
            azureDevOps: azure,
            azureDevOpsOrganization: org,
            gitHubToken: wantsGitHub ? RepoCatalogService.gitHubTokenProvider(config: gh) : nil,
            gitHubOwners: owners
        )
        return (service, errors)
    }

    static func summary(_ status: RepoStatus) -> String {
        if let error = status.error { return error.red }
        var parts: [String] = []
        parts.append((status.branch ?? "(detached)").cyan)
        if let upstream = status.upstream {
            var sync = ""
            if status.ahead > 0 { sync += "↑\(status.ahead)" }
            if status.behind > 0 { sync += "↓\(status.behind)" }
            parts.append(sync.isEmpty ? "= \(upstream)".lightBlack : "\(sync) \(upstream)".yellow)
        } else {
            parts.append("no upstream".lightBlack)
        }
        if status.isClean {
            parts.append("clean".green)
        } else {
            var counts: [String] = []
            if status.staged > 0 { counts.append("\(status.staged) staged") }
            if status.unstaged > 0 { counts.append("\(status.unstaged) modified") }
            if status.untracked > 0 { counts.append("\(status.untracked) untracked") }
            if status.conflicted > 0 { counts.append("\(status.conflicted) conflicted") }
            parts.append(counts.joined(separator: ", ").yellow)
        }
        let extraWorktrees = max(0, status.worktrees.count - 1)
        if extraWorktrees > 0 { parts.append("\(extraWorktrees) worktree\(extraWorktrees == 1 ? "" : "s")".lightBlack) }
        return parts.joined(separator: "  ")
    }
}

// MARK: - catalog

struct ReposCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "List every repository you can see in Azure DevOps and GitHub"
    )

    @Option(name: .long, help: "Limit to one provider: azdo or github")
    var provider: String?

    @Option(name: .shortAndLong, help: "Only repositories whose name or scope contains this text")
    var filter: String?

    @Flag(name: .long, help: "Use the cached catalog instead of asking the providers")
    var cached = false

    @Flag(name: .long, help: "Include archived repositories")
    var archived = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            var errors: [String] = []
            var catalog: RepoCatalog
            if cached {
                catalog = manager.cachedCatalog() ?? RepoCatalog()
            } else {
                let config = try FleetMateConfig.load()
                let (service, setupErrors) = await ReposCLI.catalogService(config: config, settings: try manager.settings(), provider: provider?.lowercased())
                errors += setupErrors
                catalog = try await manager.refreshCatalog(using: service)
            }
            errors += catalog.errors

            let registry = try manager.registry()
            var records = RepoRecord.merge(catalog: catalog.repos, registry: [])
                .map { RepoRecord(key: $0.key, catalog: $0.catalog, local: registry.repos[$0.id]) }
            if let provider = provider?.lowercased() { records = records.filter { $0.key.provider.rawValue == provider } }
            if !archived { records = records.filter { !($0.catalog?.isArchived ?? false) } }
            if let filter = filter?.lowercased() {
                records = records.filter { $0.key.displayName.lowercased().contains(filter) }
            }

            if json {
                struct Output: Encodable {
                    let fetchedAt: Date
                    let errors: [String]
                    let repos: [Entry]
                }
                struct Entry: Encodable {
                    let id: String
                    let provider: String
                    let organization: String?
                    let owner: String
                    let project: String?
                    let name: String
                    let displayName: String
                    let cloneUrl: String?
                    let sshUrl: String?
                    let webUrl: String?
                    let defaultBranch: String?
                    let archived: Bool
                    let fork: Bool
                    let local: Bool
                    let tracked: Bool
                    let path: String?
                }
                try ReposCLI.printJSON(Output(fetchedAt: catalog.fetchedAt, errors: errors, repos: records.map { r in
                    Entry(
                        id: r.id,
                        provider: r.key.provider.rawValue,
                        organization: r.key.provider == .azureDevOps ? r.key.owner : nil,
                        owner: r.key.provider == .azureDevOps ? (r.key.project ?? r.key.owner) : r.key.owner,
                        project: r.key.project,
                        name: r.key.name,
                        displayName: r.key.displayName,
                        cloneUrl: r.catalog?.cloneUrl,
                        sshUrl: r.catalog?.sshUrl,
                        webUrl: r.catalog?.webUrl,
                        defaultBranch: r.defaultBranch,
                        archived: r.catalog?.isArchived ?? false,
                        fork: r.catalog?.isFork ?? false,
                        local: r.isLocal,
                        tracked: r.isTracked,
                        path: r.local?.path
                    )
                }))
            } else {
                print("\n" + "Repository catalog".bold + " (\(records.count))\n")
                let header: [String] = ["Provider".col(8), "Repository".col(48), "Default".col(10), "Local"]
                print("   " + header.joined(separator: " "))
                for r in records {
                    let marker = r.isTracked ? "●".green : (r.isLocal ? "○".cyan : " ")
                    let local = r.local?.path ?? ""
                    let columns: [String] = [r.key.provider.rawValue.col(8), r.key.displayName.col(48),
                                             (r.defaultBranch ?? "").col(10), local.lightBlack]
                    print(" \(marker) " + columns.joined(separator: " "))
                }
                print("\n ● tracked  ○ local, untracked".lightBlack)
                for error in errors { print("warning: \(error)".yellow) }
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - list

struct ReposListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List local repositories with a status summary"
    )

    @Flag(name: .shortAndLong, help: "Include local repositories that are not tracked")
    var all = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let records = try manager.records().filter { all ? $0.isLocal : $0.isTracked }
            let statuses = await manager.status(for: records)
            if json {
                try ReposCLI.printJSON(statuses)
                return
            }
            if records.isEmpty {
                print(all
                      ? "No local repositories registered. Run 'fleetmate repos discover'."
                      : "No tracked repositories. Track one with 'fleetmate repos track <repo>', or list all local ones with --all.")
                return
            }
            print("")
            for (record, status) in zip(records, statuses) {
                let marker = record.isTracked ? "●".green : "○".cyan
                print(" \(marker) " + record.key.displayName.col(44) + " " + ReposCLI.summary(status))
            }
            print("")
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - discover

struct ReposDiscoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Find existing clones under the scan roots and link them"
    )

    @Option(name: .long, help: "Folder to scan instead of the configured roots (repeatable)")
    var root: [String] = []

    @Option(name: .long, help: "Folder levels to descend below each root")
    var depth: Int?

    @Flag(name: .long, help: "Also mark every linked repository as tracked")
    var track = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            var settings = try manager.settings()
            if !root.isEmpty { settings.scanRoots = root }
            if let depth { settings.scanDepth = depth }
            let results = try await manager.discover(track: track, settings: settings)
            if json {
                try ReposCLI.printJSON(results)
                return
            }
            let linked = results.filter { $0.action == .linked }
            let known = results.filter { $0.action == .alreadyLinked }
            let duplicates = results.filter { $0.action == .duplicate }
            let noRemote = results.filter { $0.action == .noRemote }
            print("\nScanned " + settings.scanRoots.joined(separator: ", ") + " (depth \(settings.scanDepth)): \(results.count) checkouts\n")
            for r in linked {
                let note: String = r.inCatalog ? "" : "  (not in catalog)".yellow
                let name: String = (r.displayName ?? "").col(44)
                print("  + ".green + name + " " + r.path.lightBlack + note)
            }
            for r in duplicates {
                let name: String = (r.displayName ?? "").col(44)
                let note: String = "  (already at \(r.registeredPath ?? ""))"
                print("  = ".yellow + name + " " + r.path.lightBlack + note)
            }
            print("\n\(linked.count) linked, \(known.count) already linked, \(duplicates.count) duplicate copies, \(noRemote.count) without a usable origin")
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - link / clone / track

struct ReposLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link a repository to an existing checkout",
        discussion: "With only a path, the repository is taken from the checkout's origin remote."
    )

    @Argument(help: "Repository (name, project/name or owner/name), or the path when it is the only argument")
    var repo: String

    @Argument(help: "Path of the checkout")
    var path: String?

    @Flag(name: .long, help: "Link without tracking")
    var untracked = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        do {
            let entry = try await RepoManager().link(path: path ?? repo, to: path == nil ? nil : repo, tracked: !untracked)
            if json { try ReposCLI.printJSON(entry) } else { print("Linked \(entry.key.displayName) → \(entry.path)".green) }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposCloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a catalog repository into the standard layout and track it",
        discussion: "Clones to <root>/AzDevOps/<Project>/<Repo> or <root>/GitHub/<owner>/<repo>, using your own git credentials."
    )

    @Argument(help: "Repository (name, project/name or owner/name)")
    var repo: String

    @Option(name: .long, help: "Clone root (default: the configured clone root)")
    var root: String?

    @Option(name: .long, help: "Exact destination folder, overriding the layout")
    var into: String?

    @Flag(name: .long, help: "Clone over ssh instead of https")
    var ssh = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        do {
            let entry = try await RepoManager().clone(repo, root: root, destination: into, useSSH: ssh)
            if json { try ReposCLI.printJSON(entry) } else { print("Cloned \(entry.key.displayName) → \(entry.path)".green) }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposUnlinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unlink", abstract: "Forget a local checkout (the folder is left untouched)")

    @Argument(help: "Repositories")
    var repos: [String]

    func run() async throws {
        do {
            for repo in repos {
                let record = try RepoManager().resolve(repo)
                try RepoManager().unlink(record.key.id)
                print("Unlinked \(record.key.displayName)")
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposTrackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "track", abstract: "Mark local repositories as tracked")

    @Argument(help: "Repositories")
    var repos: [String]

    func run() async throws {
        do {
            for repo in repos {
                let record = try RepoManager().setTracked(repo, true)
                print("Tracking \(record.key.displayName)".green)
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposUntrackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "untrack", abstract: "Stop tracking repositories (the checkout stays linked)")

    @Argument(help: "Repositories")
    var repos: [String]

    func run() async throws {
        do {
            for repo in repos {
                let record = try RepoManager().setTracked(repo, false)
                print("Stopped tracking \(record.key.displayName)")
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - status / fetch / pull

struct ReposStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Branch, sync and change counts, worktrees and AGENTS.md for repositories"
    )

    @Argument(help: "Repositories (default: all tracked)")
    var repos: [String] = []

    @Flag(name: .long, help: "List each changed file")
    var files = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let records = try manager.resolveLocal(repos)
            let statuses = await manager.status(for: records)
            if json {
                try ReposCLI.printJSON(statuses)
                return
            }
            if records.isEmpty { print("No tracked repositories. Name one, or track some with 'fleetmate repos track'."); return }
            for status in statuses {
                print("\n" + status.displayName.bold + "  " + status.path.lightBlack)
                print("  " + ReposCLI.summary(status))
                if let agents = status.agentsFile { print("  read first: ".lightBlack + agents) }
                for worktree in status.worktrees.dropFirst() {
                    print("  worktree ".lightBlack + (worktree.branch ?? "(detached)").cyan + " " + worktree.path.lightBlack)
                }
                if files {
                    for change in status.changes {
                        let code = change.kind == .untracked ? "??" : "\(change.indexStatus)\(change.worktreeStatus)"
                        print("    \(code) \(change.path)" + (change.originalPath.map { " ← \($0)" } ?? ""))
                    }
                }
            }
            print("")
            if statuses.contains(where: { $0.error != nil }) { throw ExitCode.failure }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposFetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fetch", abstract: "git fetch --prune for repositories (default: all tracked)")

    @Argument(help: "Repositories (default: all tracked)")
    var repos: [String] = []

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        try await ReposBatch.run(.fetch, repos: repos, json: json)
    }
}

struct ReposPullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "git pull --ff-only for repositories (default: all tracked)")

    @Argument(help: "Repositories (default: all tracked)")
    var repos: [String] = []

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        try await ReposBatch.run(.pull, repos: repos, json: json)
    }
}

enum ReposBatch {
    static func run(_ operation: RepoManager.BatchOperation, repos: [String], json: Bool) async throws {
        let manager = RepoManager()
        let results: [RepoOperationResult]
        do {
            let records = try manager.resolveLocal(repos)
            results = await manager.run(operation, on: records)
        } catch {
            throw ReposCLI.fail(error)
        }
        if json {
            try ReposCLI.printJSON(results)
        } else {
            for result in results {
                let mark = result.succeeded ? "✓".green : "✗".red
                let detail = result.error ?? result.output.split(separator: "\n").last.map(String.init) ?? ""
                print(" \(mark) " + result.displayName.col(44) + " " + detail.lightBlack)
            }
        }
        if results.contains(where: { !$0.succeeded }) { throw ExitCode.failure }
    }
}

// MARK: - push / commit / branch

struct ReposPushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push the current branch, setting its upstream on first push",
        discussion: "Refuses main, master and the repository's default branch unless --allow-main."
    )

    @Argument(help: "Repository")
    var repo: String

    @Flag(name: .long, help: "Allow pushing a protected branch")
    var allowMain = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let record = try manager.resolve(repo)
            let output = try await manager.workingCopy(for: record).push(protectedBranches: manager.protectedBranches(for: record), allowProtected: allowMain)
            print(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposCommitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commit",
        abstract: "Commit all changes, or only the given paths",
        discussion: "Refuses main, master and the repository's default branch unless --allow-main."
    )

    @Argument(help: "Repository")
    var repo: String

    @Option(name: .shortAndLong, help: "Commit message")
    var message: String

    @Argument(help: "Paths to commit (default: every change)")
    var paths: [String] = []

    @Flag(name: .long, help: "Allow committing on a protected branch")
    var allowMain = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let record = try manager.resolve(repo)
            let commit = try await manager.workingCopy(for: record).commit(
                message: message,
                paths: paths,
                protectedBranches: manager.protectedBranches(for: record),
                allowProtected: allowMain
            )
            if json { try ReposCLI.printJSON(commit) } else { print("\(commit.shortSha) \(commit.subject)".green) }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposBranchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "Switch to a branch, creating it when it does not exist"
    )

    @Argument(help: "Repository")
    var repo: String

    @Argument(help: "Branch name")
    var name: String

    @Option(name: .long, help: "Start point for a new branch, e.g. origin/main")
    var from: String?

    func run() async throws {
        let manager = RepoManager()
        do {
            let copy = try manager.workingCopy(for: manager.resolve(repo))
            let output = try await copy.switchBranch(name, startPoint: from)
            print(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - diff / log

struct ReposDiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "Show unstaged (or staged) changes")

    @Argument(help: "Repository")
    var repo: String

    @Argument(help: "Limit to these paths")
    var paths: [String] = []

    @Flag(name: .long, help: "Diff the index against HEAD instead of the worktree against the index")
    var staged = false

    @Flag(name: .long, help: "Summary only (--stat)")
    var stat = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let copy = try manager.workingCopy(for: manager.resolve(repo))
            print(try await copy.diff(staged: staged, stat: stat, paths: paths), terminator: "")
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposLogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "Recent commits")

    @Argument(help: "Repository")
    var repo: String

    @Option(name: .shortAndLong, help: "Number of commits")
    var number: Int = 20

    @Option(name: .long, help: "Branch or ref (default: HEAD)")
    var ref: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let commits = try await manager.workingCopy(for: manager.resolve(repo)).log(limit: number, ref: ref)
            if json { try ReposCLI.printJSON(commits); return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            for commit in commits {
                let date = commit.date.map { formatter.string(from: $0) } ?? ""
                let columns: [String] = [commit.shortSha.yellow, date.lightBlack, commit.author.col(18).cyan, commit.subject]
                print(columns.joined(separator: " "))
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - stats

struct ReposStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Commit, author and churn statistics from git history",
        discussion: """
        With one repository: commits and lines added/removed over time, top authors,
        most-changed files and top-level folders, and commits by weekday and hour.
        With none (or several): one row per repository with commits, churn, ahead,
        behind and open changes, plus the combined statistics. Merge commits are
        left out; renames count as a delete plus an add.
        """
    )

    @Argument(help: "Repositories (default: all tracked)")
    var repos: [String] = []

    @Option(name: .long, help: "Start of the period: 30d, 12w, 6m, 1y, or YYYY-MM-DD (default: 90d; 'all' for full history)")
    var since: String = "90d"

    @Option(name: .long, help: "Timeline bucket: day, week or month (default: chosen from the period)")
    var by: RepoStatsBucket?

    @Option(name: .long, help: "How many files, folders and authors to list")
    var top: Int = 10

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let start: Date?
            if since.lowercased() == "all" {
                start = nil
            } else if let parsed = RepoStatsRange.parseSince(since) {
                start = parsed
            } else {
                throw RepoError.invalidArgument("'\(since)' is not a period. Use 30d, 12w, 6m, 1y, YYYY-MM-DD or all.")
            }
            let records = try manager.resolveLocal(repos)
            if records.count == 1 {
                let report = try await manager.stats(for: records[0], since: start, bucket: by, top: top)
                if json { try ReposCLI.printJSON(report); return }
                print("\n" + records[0].key.displayName.bold + "  " + ReposStatsCommand.period(start).lightBlack)
                ReposStatsCommand.printReport(report, top: top)
                return
            }
            if records.isEmpty { print("No tracked repositories. Name one, or track some with 'fleetmate repos track'."); return }
            let summary = await manager.statsSummary(for: records, since: start, bucket: by, top: top)
            if json { try ReposCLI.printJSON(summary); return }
            print("\n" + "Tracked repositories".bold + "  " + ReposStatsCommand.period(start).lightBlack + "\n")
            print(["Repository".col(44), "Commits".col(8), "+lines".col(9), "-lines".col(9), "Ahead".col(6), "Behind".col(7), "Open"].joined(separator: " ").lightBlack)
            for row in summary.rows {
                if let error = row.error, row.commits == 0 {
                    print(row.displayName.col(44) + " " + error.yellow)
                    continue
                }
                print([row.displayName.col(44), "\(row.commits)".col(8), "+\(row.added)".col(9), "-\(row.removed)".col(9), "\(row.ahead)".col(6), "\(row.behind)".col(7), "\(row.openChanges)"].joined(separator: " "))
            }
            print("\n" + "All repositories".bold)
            ReposStatsCommand.printReport(summary.combined, top: top)
        } catch {
            throw ReposCLI.fail(error)
        }
    }

    static func period(_ start: Date?) -> String {
        guard let start else { return "all history" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "since \(formatter.string(from: start))"
    }

    static func printReport(_ report: RepoStatsReport, top: Int) {
        let t = report.totals
        print("  \(t.commits) commits by \(t.authors) author\(t.authors == 1 ? "" : "s"), " + "+\(t.added)".green + " / " + "-\(t.removed)".yellow + " lines, \(t.filesTouched) files")
        let formatter = DateFormatter()
        formatter.dateFormat = report.bucket == .month ? "yyyy-MM" : "yyyy-MM-dd"
        let peak = max(1, report.timeline.map(\.commits).max() ?? 1)
        print("\n  Commits per \(report.bucket.rawValue)".bold)
        for point in report.timeline.suffix(26) {
            let bar = String(repeating: "▇", count: Int((Double(point.commits) / Double(peak) * 30).rounded(.up)))
            print("  " + formatter.string(from: point.start).lightBlack + " " + "\(point.commits)".col(4) + " " + bar.cyan)
        }
        if !report.contributors.isEmpty {
            print("\n  Authors".bold)
            for person in report.contributors.prefix(top) {
                print("  " + "\(person.commits)".col(6) + person.name.col(28) + "+\(person.added) -\(person.removed)".lightBlack)
            }
        }
        if !report.areas.isEmpty {
            print("\n  Folders".bold)
            for area in report.areas.prefix(top) {
                print("  " + "\(area.commits)".col(6) + area.path.col(40) + "+\(area.added) -\(area.removed)".lightBlack)
            }
        }
        if !report.files.isEmpty {
            print("\n  Files".bold)
            for file in report.files.prefix(top) {
                print("  " + "\(file.commits)".col(6) + file.path + "  " + "+\(file.added) -\(file.removed)".lightBlack)
            }
        }
        print("")
    }
}

extension RepoStatsBucket: ExpressibleByArgument {}

// MARK: - files / grep

struct ReposFilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files",
        abstract: "List files git sees (tracked plus untracked, honouring .gitignore)"
    )

    @Argument(help: "Repository")
    var repo: String

    @Option(name: .long, help: "Only paths under this folder")
    var under: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            var files = try await manager.workingCopy(for: manager.resolve(repo)).listFiles()
            if let under {
                let prefix = under.hasSuffix("/") ? under : under + "/"
                files = files.filter { $0.hasPrefix(prefix) }
            }
            if json { try ReposCLI.printJSON(files) } else { files.forEach { print($0) } }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

struct ReposGrepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "grep", abstract: "Search a repository with git grep")

    @Argument(help: "Repository")
    var repo: String

    @Argument(help: "Pattern (a basic regular expression unless --fixed)")
    var pattern: String

    @Flag(name: .shortAndLong, help: "Ignore case")
    var ignoreCase = false

    @Flag(name: [.customShort("F"), .long], help: "Treat the pattern as a literal string")
    var fixed = false

    @Option(name: .long, help: "Maximum matches")
    var limit: Int = 1000

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let matches = try await manager.workingCopy(for: manager.resolve(repo)).grep(pattern, ignoreCase: ignoreCase, fixedStrings: fixed, limit: limit)
            if json { try ReposCLI.printJSON(matches); return }
            for match in matches {
                print("\(match.path):\(match.line):".cyan + " " + match.text)
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}

// MARK: - settings

struct ReposSettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Show or change scan roots, clone root and extra GitHub owners"
    )

    @Option(name: .long, help: "Replace the scan roots (repeatable)")
    var scanRoot: [String] = []

    @Option(name: .long, help: "Scan depth below each root")
    var depth: Int?

    @Option(name: .long, help: "Clone root for the standard layout")
    var cloneRoot: String?

    @Option(name: .customLong("github-owner"), help: "Replace the extra GitHub owners listed in the catalog (repeatable)")
    var gitHubOwner: [String] = []

    @Option(name: .long, help: "Concurrent git processes for batch commands")
    var concurrency: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func run() async throws {
        let manager = RepoManager()
        do {
            let changing = !scanRoot.isEmpty || depth != nil || cloneRoot != nil || !gitHubOwner.isEmpty || concurrency != nil
            if changing {
                try manager.updateSettings { s in
                    if !scanRoot.isEmpty { s.scanRoots = scanRoot }
                    if let depth { s.scanDepth = max(1, depth) }
                    if let cloneRoot { s.cloneRoot = cloneRoot }
                    if !gitHubOwner.isEmpty { s.gitHubOwners = gitHubOwner }
                    if let concurrency { s.concurrency = max(1, concurrency) }
                }
            }
            let settings = try manager.settings()
            if json {
                try ReposCLI.printJSON(settings)
            } else {
                print("registry:      \(manager.store.registryPath)")
                print("scan roots:    \(settings.scanRoots.joined(separator: ", ")) (depth \(settings.scanDepth))")
                print("skip:          \(settings.skipDirectories.joined(separator: ", "))")
                print("clone root:    \(settings.cloneRoot)")
                print("GitHub owners: \(settings.gitHubOwners.isEmpty ? "(your own and your organizations')" : settings.gitHubOwners.joined(separator: ", "))")
                print("protected:     \(settings.protectedBranches.joined(separator: ", ")) + each repository's default branch")
                print("concurrency:   \(settings.concurrency)")
            }
        } catch {
            throw ReposCLI.fail(error)
        }
    }
}
