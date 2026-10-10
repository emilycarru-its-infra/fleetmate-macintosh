import Foundation

// The data side of the Repos workspace's git pane, ported from MunkiStudio
// (Apache-2.0): the status, commit, ref and
// branch models of Sources/Core/Services/GitService.swift, the parsing in
// Sources/Infra/Git/ShellGitService.swift, the lane builder of
// Sources/App/Features/Git/CommitGraph.swift and DiffFile.patch(forHunk:) of
// Sources/Core/Models/DiffPatch.swift. The git calls run through
// `GitWorkingCopy` and `ProcessRunner` instead of MunkiStudio's service, and
// keep FleetMate's guard: commit and push refuse protected branches.

/// One row of the git pane's change list. A file with both staged and
/// unstaged edits appears twice, once per side, as in MunkiStudio.
public struct GitStatusEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case modified, added, deleted, untracked, ignored, conflicted
        case renamed(from: String)
        case copied(from: String)
    }

    public var relativePath: String
    public var kind: Kind
    public var staged: Bool

    /// Unique across both sides of the same path.
    public var id: String { (staged ? "staged:" : "work:") + relativePath }

    public init(relativePath: String, kind: Kind, staged: Bool) {
        self.relativePath = relativePath
        self.kind = kind
        self.staged = staged
    }

    /// Entries for a status snapshot, staged side first for each path.
    public static func entries(from snapshot: GitStatusSnapshot) -> [GitStatusEntry] {
        var result: [GitStatusEntry] = []
        for change in snapshot.changes {
            switch change.kind {
            case .ignored:
                continue
            case .untracked:
                result.append(GitStatusEntry(relativePath: change.path, kind: .untracked, staged: false))
            case .unmerged:
                result.append(GitStatusEntry(relativePath: change.path, kind: .conflicted, staged: false))
            case .changed, .renamed:
                if change.indexStatus != ".", let kind = kind(change.indexStatus, original: change.originalPath) {
                    result.append(GitStatusEntry(relativePath: change.path, kind: kind, staged: true))
                }
                if change.worktreeStatus != ".", let kind = kind(change.worktreeStatus, original: nil) {
                    result.append(GitStatusEntry(relativePath: change.path, kind: kind, staged: false))
                }
            }
        }
        return result
    }

    private static func kind(_ letter: Character, original: String?) -> Kind? {
        switch letter {
        case "M", "T": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed(from: original ?? "")
        case "C": .copied(from: original ?? "")
        case "U": .conflicted
        default: nil
        }
    }
}

/// A branch, tag or HEAD decoration on a commit.
public struct RepoGitRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case head, localBranch, remoteBranch, tag }
    public var name: String
    public var kind: Kind
    public var isHead: Bool

    public init(name: String, kind: Kind, isHead: Bool = false) {
        self.name = name
        self.kind = kind
        self.isHead = isHead
    }

    /// Parses a `%D` decoration written with `--decorate=full`.
    public static func parse(_ raw: String) -> [RepoGitRef] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var refs: [RepoGitRef] = []
        for token in trimmed.components(separatedBy: ", ") {
            var value = token.trimmingCharacters(in: .whitespaces)
            var isHead = false
            if value == "HEAD" {
                refs.append(RepoGitRef(name: "HEAD", kind: .head, isHead: true))
                continue
            }
            if value.hasPrefix("HEAD -> ") {
                isHead = true
                value = String(value.dropFirst("HEAD -> ".count))
            }
            if value.hasPrefix("tag: ") {
                var name = String(value.dropFirst("tag: ".count))
                if name.hasPrefix("refs/tags/") { name = String(name.dropFirst("refs/tags/".count)) }
                refs.append(RepoGitRef(name: name, kind: .tag))
            } else if value.hasPrefix("refs/heads/") {
                refs.append(RepoGitRef(name: String(value.dropFirst("refs/heads/".count)), kind: .localBranch, isHead: isHead))
            } else if value.hasPrefix("refs/remotes/") {
                refs.append(RepoGitRef(name: String(value.dropFirst("refs/remotes/".count)), kind: .remoteBranch, isHead: isHead))
            } else if value.hasPrefix("refs/tags/") {
                refs.append(RepoGitRef(name: String(value.dropFirst("refs/tags/".count)), kind: .tag))
            } else if !value.isEmpty {
                refs.append(RepoGitRef(name: value, kind: value.contains("/") ? .remoteBranch : .localBranch, isHead: isHead))
            }
        }
        return refs
    }
}

/// A commit in the History panel, with the parents the lane graph needs.
public struct GitCommit: Sendable, Hashable, Identifiable {
    public var sha: String
    public var subject: String
    public var author: String
    public var date: Date
    public var parents: [String]
    public var refs: [RepoGitRef]
    public var id: String { sha }

    public init(sha: String, subject: String, author: String, date: Date, parents: [String] = [], refs: [RepoGitRef] = []) {
        self.sha = sha
        self.subject = subject
        self.author = author
        self.date = date
        self.parents = parents
        self.refs = refs
    }

    /// `--pretty=format:` string `parseLog` reads.
    public static let logFormat = "--pretty=format:%H%x1f%an%x1f%aI%x1f%P%x1f%D%x1f%s%x1e"

    public static func parseLog(_ output: String) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        return output.components(separatedBy: "\u{1e}").compactMap { raw in
            let record = raw.drop { $0 == "\n" || $0 == "\r" }
            guard !record.isEmpty else { return nil }
            let parts = record.components(separatedBy: "\u{1f}")
            guard parts.count == 6, let date = formatter.date(from: parts[2]) else { return nil }
            return GitCommit(
                sha: parts[0], subject: parts[5], author: parts[1], date: date,
                parents: parts[3].split(separator: " ").map(String.init),
                refs: RepoGitRef.parse(parts[4])
            )
        }
    }
}

public struct GitBranch: Sendable, Hashable, Identifiable {
    public var name: String
    public var isCurrent: Bool
    public var upstreamName: String?
    public var id: String { name }

    public init(name: String, isCurrent: Bool, upstreamName: String? = nil) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstreamName = upstreamName
    }

    /// `git branch --format=%(refname:short)|%(upstream:short)|%(HEAD)`.
    public static let listFormat = "--format=%(refname:short)|%(upstream:short)|%(HEAD)"

    public static func parse(_ output: String) -> [GitBranch] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let upstream = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            return GitBranch(name: name, isCurrent: parts.count > 2 && parts[2] == "*", upstreamName: upstream)
        }
    }
}

// MARK: - Commit graph

/// One drawn segment of a commit-graph row. `upperHalf` segments span the
/// row's top edge to its middle; the rest span middle to bottom.
public struct GraphSegment: Hashable, Sendable {
    public var fromColumn: Int
    public var toColumn: Int
    public var upperHalf: Bool
    public var colorIndex: Int
}

/// Per-commit graph geometry, parallel to the commit list.
public struct GraphRow: Hashable, Sendable {
    public var dotColumn: Int
    public var dotColorIndex: Int
    public var segments: [GraphSegment]
}

public enum CommitGraphBuilder {
    /// Lane geometry for `commits` (newest first). Lanes keep their column
    /// for life, so passing lines stay vertical.
    public static func build(_ commits: [GitCommit]) -> (rows: [GraphRow], laneCount: Int) {
        var lanes: [String?] = []
        var laneColor: [Int] = []
        var rows: [GraphRow] = []
        var nextColor = 0
        var laneCount = 1

        func takeColor() -> Int { defer { nextColor += 1 }; return nextColor }
        func freeColumn() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            laneColor.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            let entry = lanes
            let occupied = entry.indices.filter { entry[$0] == commit.sha }
            let col: Int
            if let first = occupied.first {
                col = first
            } else {
                col = freeColumn()
                lanes[col] = commit.sha
                laneColor[col] = takeColor()
            }
            let dotColor = laneColor[col]

            var segments: [GraphSegment] = []
            for i in entry.indices {
                guard let sha = entry[i] else { continue }
                segments.append(GraphSegment(fromColumn: i, toColumn: sha == commit.sha ? col : i, upperHalf: true, colorIndex: laneColor[i]))
            }

            for i in occupied { lanes[i] = nil }
            let parents = commit.parents
            lanes[col] = parents.first
            var fromDot: Set<Int> = [col]
            for parent in parents.dropFirst() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    fromDot.insert(existing)
                } else {
                    let nc = freeColumn()
                    lanes[nc] = parent
                    laneColor[nc] = takeColor()
                    fromDot.insert(nc)
                }
            }

            for i in lanes.indices {
                guard lanes[i] != nil else { continue }
                if i == col {
                    if parents.first != nil {
                        segments.append(GraphSegment(fromColumn: col, toColumn: col, upperHalf: false, colorIndex: dotColor))
                    }
                } else if fromDot.contains(i) {
                    segments.append(GraphSegment(fromColumn: col, toColumn: i, upperHalf: false, colorIndex: laneColor[i]))
                } else {
                    segments.append(GraphSegment(fromColumn: i, toColumn: i, upperHalf: false, colorIndex: laneColor[i]))
                }
            }

            rows.append(GraphRow(dotColumn: col, dotColorIndex: dotColor, segments: segments))
            laneCount = max(laneCount, lanes.count)
        }
        return (rows, laneCount)
    }
}

// MARK: - Hunk patches

extension DiffFile {
    /// A patch holding only `hunk`, for `git apply` (optionally `--cached`
    /// and/or `--reverse`) to stage, unstage or discard one chunk.
    public func patch(forHunk hunk: DiffHunk) -> String {
        var out = headerLines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        out += hunk.header + "\n"
        for line in hunk.lines {
            switch line.kind {
            case .addition: out += "+" + line.content + "\n"
            case .deletion: out += "-" + line.content + "\n"
            case .context: out += " " + line.content + "\n"
            case .noNewline: out += "\\" + line.content + "\n"
            }
        }
        return out
    }
}

// MARK: - Git operations

extension GitWorkingCopy {
    public func statusEntries() async throws -> [GitStatusEntry] {
        GitStatusEntry.entries(from: try await statusSnapshot())
    }

    public func branchList() async throws -> [GitBranch] {
        GitBranch.parse(try await run(["branch", GitBranch.listFormat]))
    }

    /// Every branch's history, newest first, in topological order so the
    /// lane graph draws cleanly.
    public func history(limit: Int = 200) async throws -> [GitCommit] {
        let result = await git(["log", "--all", "--topo-order", "--decorate=full", "--max-count=\(max(1, limit))", GitCommit.logFormat])
        if !result.succeeded, result.stderr.contains("does not have any commits") { return [] }
        guard result.succeeded else { throw RepoError.gitFailed(command: "log", message: result.stderr.trimmed) }
        return GitCommit.parseLog(result.stdout)
    }

    /// `git show --stat --patch` for the History detail pane.
    public func show(_ sha: String) async throws -> String {
        try validateRevision(sha)
        return try await run(["show", "--stat", "--patch", "--no-color", "--no-ext-diff", sha])
    }

    /// Staged and unstaged changes to one path against HEAD; an untracked
    /// file is shown as wholly added.
    public func combinedDiff(_ relativePath: String) async throws -> String {
        let safe = try confinedPath(relativePath)
        let result = await git(["diff", "--no-color", "--no-ext-diff", "HEAD", "--", safe])
        if result.succeeded, !result.stdout.isEmpty { return result.stdout }
        return try await fileDiff(safe)
    }

    /// Applies a patch to the working tree, or the index when `cached`;
    /// `reverse` undoes it. The basis for staging, unstaging and discarding
    /// single chunks.
    public func applyPatch(_ patch: String, cached: Bool, reverse: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fleetmate-hunk-\(UUID().uuidString).patch")
        try Data(patch.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var args = ["apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        _ = try await run(args + [file.path])
    }

    /// Commits what is staged with a subject and optional body. `amend`
    /// rewrites HEAD; `runHooks` false passes `--no-verify`. Refuses a
    /// protected branch unless `allowProtected`. Returns the new HEAD.
    @discardableResult
    public func commit(subject: String, body: String?, amend: Bool, runHooks: Bool, protectedBranches: Set<String>, allowProtected: Bool = false) async throws -> RepoCommit {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepoError.invalidArgument("A commit subject is required.") }
        if let branch = await currentBranch(), !allowProtected, protectedBranches.contains(branch) {
            throw RepoError.protectedBranch(branch)
        }
        if !amend, try await statusSnapshot().stagedCount == 0 { throw RepoError.nothingToCommit }
        var args = ["commit", "-m", trimmed]
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty { args += ["-m", body] }
        if amend { args.append("--amend") }
        if !runHooks { args.append("--no-verify") }
        _ = try await run(args)
        guard let head = try await log(limit: 1).first else {
            throw RepoError.gitFailed(command: "log", message: "no commit after commit")
        }
        return head
    }

    public func tag(_ name: String, at sha: String, message: String?) async throws {
        try validateRevision(sha)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(" ") else {
            throw RepoError.invalidArgument("'\(name)' is not a valid tag name.")
        }
        if let message, !message.isEmpty {
            _ = try await run(["tag", "-a", name, "-m", message, sha])
        } else {
            _ = try await run(["tag", name, sha])
        }
    }

    /// Creates a branch at `sha` without switching to it.
    public func createBranch(_ name: String, at sha: String) async throws {
        try validateRevision(sha)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(" "), !name.contains("..") else {
            throw RepoError.invalidArgument("'\(name)' is not a valid branch name.")
        }
        _ = try await run(["branch", name, sha])
    }

    public func checkoutCommit(_ sha: String) async throws {
        try validateRevision(sha)
        _ = try await run(["switch", "--detach", sha])
    }

    public func cherryPick(_ sha: String) async throws {
        try validateRevision(sha)
        _ = try await run(["cherry-pick", sha])
    }

    public func revert(_ sha: String) async throws {
        try validateRevision(sha)
        _ = try await run(["revert", "--no-edit", sha])
    }

    /// Runs git and returns its output, or throws its error text.
    func run(_ arguments: [String]) async throws -> String {
        let result = await git(arguments)
        guard result.succeeded else {
            let message = result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed
            throw RepoError.gitFailed(command: arguments.first ?? "", message: message)
        }
        return result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func validateRevision(_ sha: String) throws {
        guard !sha.isEmpty, !sha.hasPrefix("-"), sha.allSatisfy({ $0.isHexDigit }) else {
            throw RepoError.invalidArgument("'\(sha)' is not a commit hash.")
        }
    }
}
