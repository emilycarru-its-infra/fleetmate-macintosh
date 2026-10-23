import Foundation

/// What deleting a local clone would lose that its remotes do not hold:
/// uncommitted and untracked files, commits on no remote, stashes, and
/// worktrees added from it. The Repos sidebar and `fleetmate repos
/// remove-clone` both read it before anything moves to the Trash.
public struct CloneRemovalCheck: Codable, Sendable, Equatable {
    public var path: String
    /// Paths with staged, unstaged or untracked changes.
    public var uncommitted: [String]
    /// Commits reachable from a local branch but from no remote-tracking ref.
    public var unpushedCount: Int
    /// The newest of those, `<short sha> <subject>`, at most `sampleLimit`.
    public var unpushedSample: [String]
    /// Local branches holding commits no remote has.
    public var unpushedBranches: [String]
    /// `git stash list` lines.
    public var stashes: [String]
    /// Linked worktrees, other than the clone itself. Removing the clone
    /// leaves them broken; any inside it go to the Trash with it.
    public var worktrees: [String]
    /// A check git could not run, reported rather than read as "nothing".
    public var problems: [String]

    public static let sampleLimit = 10

    public init(path: String, uncommitted: [String] = [], unpushedCount: Int = 0, unpushedSample: [String] = [],
                unpushedBranches: [String] = [], stashes: [String] = [], worktrees: [String] = [], problems: [String] = []) {
        self.path = path
        self.uncommitted = uncommitted
        self.unpushedCount = unpushedCount
        self.unpushedSample = unpushedSample
        self.unpushedBranches = unpushedBranches
        self.stashes = stashes
        self.worktrees = worktrees
        self.problems = problems
    }

    /// Nothing would be lost: the folder can go to the Trash with a plain
    /// confirmation.
    public var isSafe: Bool {
        uncommitted.isEmpty && unpushedCount == 0 && stashes.isEmpty && worktrees.isEmpty && problems.isEmpty
    }

    /// One line per kind of loss, in plain words, for a dialog or the CLI.
    public var lossDescription: [String] {
        var lines: [String] = []
        if !uncommitted.isEmpty {
            let shown = uncommitted.prefix(5).joined(separator: ", ")
            let more = uncommitted.count > 5 ? " and \(uncommitted.count - 5) more" : ""
            lines.append("\(Self.count(uncommitted.count, "uncommitted file")): \(shown)\(more)")
        }
        if unpushedCount > 0 {
            let branches = unpushedBranches.isEmpty ? "" : " on \(unpushedBranches.joined(separator: ", "))"
            lines.append("\(Self.count(unpushedCount, "commit")) not pushed to any remote\(branches)")
        }
        if !stashes.isEmpty {
            lines.append(Self.count(stashes.count, "stash") + ": " + stashes.prefix(3).joined(separator: "; "))
        }
        if !worktrees.isEmpty {
            let shown = worktrees.prefix(5).map(RepoSettings.abbreviate).joined(separator: ", ")
            let more = worktrees.count > 5 ? " and \(worktrees.count - 5) more" : ""
            lines.append("\(Self.count(worktrees.count, "other worktree")) that would stop working: \(shown)\(more)")
        }
        lines += problems.map { "Could not check: \($0)" }
        return lines
    }

    static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)\(noun.hasSuffix("sh") ? "es" : "s")"
    }

    /// Runs the checks with git. Each one that fails is a problem, so a
    /// broken repository never looks safe to delete.
    public static func inspect(path: String) async -> CloneRemovalCheck {
        let copy = GitWorkingCopy(path: path)
        var check = CloneRemovalCheck(path: path)

        do {
            let snapshot = try await copy.statusSnapshot()
            check.uncommitted = snapshot.changes.filter { $0.kind != .ignored }.map(\.path)
        } catch {
            check.problems.append("uncommitted changes (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))")
        }

        // An empty repository has no commits to lose; rev-list fails on it.
        let hasCommits = await copy.git(["rev-parse", "--verify", "--quiet", "HEAD"]).succeeded
        let hasBranches = !(await copy.git(["for-each-ref", "--count=1", "refs/heads"]).stdout.trimmed.isEmpty)
        if hasCommits || hasBranches {
            let count = await copy.git(["rev-list", "--count", "--branches", "--not", "--remotes"])
            if count.succeeded {
                check.unpushedCount = Int(count.stdout.trimmed) ?? 0
            } else {
                check.problems.append("unpushed commits (\(count.stderr.trimmed))")
            }
            if check.unpushedCount > 0 {
                let log = await copy.git(["log", "--branches", "--not", "--remotes", "--format=%h %s", "-n", "\(sampleLimit)"])
                check.unpushedSample = log.stdout.split(separator: "\n").map(String.init)
                let refs = await copy.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
                for branch in refs.stdout.split(separator: "\n").map(String.init) where !branch.isEmpty {
                    let ahead = await copy.git(["rev-list", "--count", "refs/heads/\(branch)", "--not", "--remotes"])
                    if (Int(ahead.stdout.trimmed) ?? 0) > 0 { check.unpushedBranches.append(branch) }
                }
            }
        }

        let stash = await copy.git(["stash", "list"])
        if stash.succeeded {
            check.stashes = stash.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        } else {
            check.problems.append("stashes (\(stash.stderr.trimmed))")
        }

        let main = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        check.worktrees = await copy.worktrees()
            .filter { !$0.isBare && !$0.isPrunable }
            .map(\.path)
            .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path != main }
        return check
    }
}
