import Foundation

/// Git operations on one local checkout, through `ProcessRunner` (which
/// closes every pipe it opens). Authentication is left entirely to the user's
/// git setup — credential helpers, `gh auth setup-git`, ssh keys — and no
/// token ever appears in a URL or argument.
///
/// This is the surface both `fleetmate repos` and the app's Repos view use:
/// status and per-file changes, staging, diffs, the file tree, file contents,
/// search, and the network operations.
public struct GitWorkingCopy: Sendable {
    /// Absolute path of the checkout's top level.
    public let path: String

    public init(path: String) {
        self.path = RepoSettings.expand(path)
    }

    /// Whether `path` is inside a git work tree.
    public var isRepository: Bool {
        get async { await git(["rev-parse", "--is-inside-work-tree"]).stdout.hasPrefix("true") }
    }

    /// `AGENTS.md` at the top level, when present. Agents read it before
    /// working in the repository.
    public var agentsFile: String? {
        let candidate = (path as NSString).appendingPathComponent("AGENTS.md")
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    // MARK: - Status

    public func statusSnapshot(includeIgnored: Bool = false) async throws -> GitStatusSnapshot {
        var args = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        if includeIgnored { args.append("--ignored") }
        // Optional locks off: a status poll must never take the index lock
        // from under a commit running in a terminal.
        let output = try await checked(args, extraEnvironment: ["GIT_OPTIONAL_LOCKS": "0"])
        return GitOutputParser.status(output)
    }

    public func worktrees() async -> [RepoWorktree] {
        let result = await git(["worktree", "list", "--porcelain"])
        return result.succeeded ? GitOutputParser.worktrees(result.stdout) : []
    }

    public func currentBranch() async -> String? {
        let result = await git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !branch.isEmpty ? branch : nil
    }

    public func originURL() async -> String? {
        let result = await git(["config", "--get", "remote.origin.url"])
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !url.isEmpty ? url : nil
    }

    // MARK: - Network

    public func fetch() async throws -> String {
        try await checked(["fetch", "--prune", "origin"])
    }

    /// Fast-forward only: a pull never creates a merge commit behind the
    /// user's back.
    public func pull() async throws -> String {
        try await checked(["pull", "--ff-only"])
    }

    /// Pushes the current branch, setting its upstream on first push.
    /// Refuses a protected branch unless `allowProtected`.
    public func push(protectedBranches: Set<String>, allowProtected: Bool = false) async throws -> String {
        guard let branch = await currentBranch() else {
            throw RepoError.invalidArgument("HEAD is detached; switch to a branch before pushing.")
        }
        try guardBranch(branch, protectedBranches: protectedBranches, allow: allowProtected)
        let snapshot = try await statusSnapshot()
        if snapshot.upstream == nil {
            return try await checked(["push", "--set-upstream", "origin", branch])
        }
        return try await checked(["push"])
    }

    // MARK: - Branches

    /// Switches to `name`, creating it from `startPoint` (default: HEAD) when
    /// it does not exist locally.
    public func switchBranch(_ name: String, create: Bool? = nil, startPoint: String? = nil) async throws -> String {
        try validateRefName(name)
        let exists = await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).succeeded
        let shouldCreate = create ?? !exists
        if shouldCreate {
            var args = ["switch", "-c", name]
            if let startPoint { args.append(startPoint) }
            return try await checked(args)
        }
        return try await checked(["switch", name])
    }

    public func localBranches() async throws -> [String] {
        try await checked(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
            .split(separator: "\n").map(String.init)
    }

    // MARK: - Staging and commits

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await checked(["add", "--"] + confined(paths))
    }

    public func stageAll() async throws {
        _ = try await checked(["add", "--all"])
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await checked(["restore", "--staged", "--"] + confined(paths))
    }

    /// Throws away local changes to `paths`: tracked files return to the
    /// index's content, untracked files are deleted. Destructive by design, so
    /// it only ever takes explicit paths.
    public func discard(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let safe = try confined(paths)
        let snapshot = try await statusSnapshot()
        let untracked = Set(snapshot.changes.filter { $0.kind == .untracked }.map(\.path))
        let tracked = safe.filter { !untracked.contains($0) }
        let new = safe.filter { untracked.contains($0) }
        if !tracked.isEmpty { _ = try await checked(["restore", "--worktree", "--"] + tracked) }
        if !new.isEmpty { _ = try await checked(["clean", "-f", "--"] + new) }
    }

    /// Commits all changes (`paths` empty) or only `paths`, refusing a
    /// protected branch unless `allowProtected`. Returns the new commit.
    @discardableResult
    public func commit(message: String, paths: [String] = [], protectedBranches: Set<String>, allowProtected: Bool = false) async throws -> RepoCommit {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepoError.invalidArgument("A commit message is required.") }
        if let branch = await currentBranch() {
            try guardBranch(branch, protectedBranches: protectedBranches, allow: allowProtected)
        }
        if paths.isEmpty {
            try await stageAll()
        } else {
            try await stage(paths)
        }
        let staged = try await statusSnapshot()
        guard staged.stagedCount > 0 else { throw RepoError.nothingToCommit }

        var args = ["commit", "-m", trimmed]
        if !paths.isEmpty { args += ["--"] + (try confined(paths)) }
        _ = try await checked(args)
        guard let head = try await log(limit: 1).first else {
            throw RepoError.gitFailed(command: "log", message: "no commit after commit")
        }
        return head
    }

    // MARK: - Diff and history

    /// `git diff` of the worktree against the index, or of the index against
    /// HEAD when `staged`. Limited to `paths` when given.
    public func diff(staged: Bool = false, stat: Bool = false, paths: [String] = []) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        if stat { args.append("--stat") }
        if !paths.isEmpty { args += ["--"] + (try confined(paths)) }
        return try await checked(args)
    }

    /// Diff for one file as the Repos view shows it. An untracked file has no
    /// index entry, so it is diffed against an empty file.
    public func fileDiff(_ path: String, staged: Bool = false) async throws -> String {
        let safe = try confined([path])
        let snapshot = try await statusSnapshot()
        if !staged, snapshot.changes.contains(where: { $0.kind == .untracked && $0.path == path }) {
            // --no-index exits 1 when the files differ, which is the expected case.
            let result = await git(["diff", "--no-color", "--no-index", "--", "/dev/null"] + safe)
            return result.stdout
        }
        return try await diff(staged: staged, paths: safe)
    }

    public func log(limit: Int = 20, ref: String? = nil) async throws -> [RepoCommit] {
        var args = ["log", "-n", String(max(1, limit)), "--format=\(GitOutputParser.logFormat)"]
        if let ref { args.append(ref) }
        let result = await git(args)
        // A repository with no commits yet has no log; that is not an error.
        if !result.succeeded, result.stderr.contains("does not have any commits") { return [] }
        guard result.succeeded else { throw RepoError.gitFailed(command: "log", message: result.stderr.trimmed) }
        return GitOutputParser.log(result.stdout)
    }

    // MARK: - Files and search

    /// Every file in the checkout that git would consider: tracked files plus
    /// untracked ones not excluded by `.gitignore`. Paths are relative.
    public func listFiles() async throws -> [String] {
        let output = try await checked(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        // Deleted-but-tracked files still appear in --cached; keep only what exists.
        var seen = Set<String>()
        return GitOutputParser.paths(output).filter { relative in
            guard seen.insert(relative).inserted else { return false }
            return FileManager.default.fileExists(atPath: absolute(relative))
        }
    }

    /// `git grep` across tracked files (and untracked, non-ignored ones when
    /// `includeUntracked`). Binary files are skipped.
    public func grep(_ pattern: String, ignoreCase: Bool = false, fixedStrings: Bool = false, includeUntracked: Bool = true, limit: Int = 1000) async throws -> [RepoGrepMatch] {
        guard !pattern.isEmpty else { throw RepoError.invalidArgument("A search pattern is required.") }
        var args = ["grep", "-n", "-z", "--column", "-I", "--no-color"]
        if ignoreCase { args.append("-i") }
        if fixedStrings { args.append("-F") }
        if includeUntracked { args.append("--untracked") }
        args += ["-e", pattern]
        let result = await git(args)
        // Exit 1 means no match.
        if result.exitCode == 1 { return [] }
        guard result.succeeded else { throw RepoError.gitFailed(command: "grep", message: result.stderr.trimmed) }
        return Array(GitOutputParser.grep(result.stdout).prefix(limit))
    }

    public func readFile(_ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: absolute(confinedPath(relative))))
    }

    public func writeFile(_ relative: String, contents: Data) throws {
        let url = URL(fileURLWithPath: absolute(try confinedPath(relative)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, options: .atomic)
    }

    // MARK: - Path safety

    /// Resolves a repository-relative path, rejecting anything that would
    /// land outside the checkout (`..`, absolute paths elsewhere, symlinks out)
    /// or inside `.git` in any letter case. A path that does not exist yet is
    /// checked through its deepest existing ancestor, so a new file under a
    /// symlinked folder cannot escape either.
    public func confinedPath(_ relative: String) throws -> String {
        let root = Self.realPath(URL(fileURLWithPath: path).standardizedFileURL.path)
        let candidate = relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(relative)
        let resolved = Self.realPath(URL(fileURLWithPath: candidate).standardizedFileURL.path)
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw RepoError.pathOutsideRepository(relative)
        }
        let inside = String(resolved.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !inside.isEmpty else { throw RepoError.invalidArgument("Expected a file path inside the repository.") }
        // APFS is case-insensitive by default, so `.GIT/hooks` is `.git/hooks`.
        guard !inside.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else {
            throw RepoError.pathOutsideRepository(relative)
        }
        return inside
    }

    /// The path with every symlink resolved. Components that do not exist yet
    /// are appended to the resolved form of the deepest ancestor that does.
    static func realPath(_ standardized: String) -> String {
        var existing = standardized
        var missing: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = realpath(existing, &buffer) != nil ? String(cString: buffer) : existing
        return missing.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    func confined(_ paths: [String]) throws -> [String] {
        try paths.map(confinedPath)
    }

    func absolute(_ relative: String) -> String {
        (path as NSString).appendingPathComponent(relative)
    }

    // MARK: - Running git

    /// Runs git in this checkout. Prompts are disabled: with no terminal to
    /// answer them, a credential prompt would otherwise hang the call.
    public func git(_ arguments: [String], extraEnvironment: [String: String] = [:]) async -> ProcessOutput {
        await GitWorkingCopy.runGit(["-C", path] + arguments, extraEnvironment: extraEnvironment)
    }

    static func runGit(_ arguments: [String], extraEnvironment: [String: String] = [:]) async -> ProcessOutput {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in extraEnvironment { env[key] = value }
        return await ProcessRunner.run("git", arguments, environment: env)
    }

    private func checked(_ arguments: [String], extraEnvironment: [String: String] = [:]) async throws -> String {
        let result = await git(arguments, extraEnvironment: extraEnvironment)
        guard result.succeeded else {
            let message = result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed
            if message.contains("not a git repository") { throw RepoError.notAGitRepository(path) }
            throw RepoError.gitFailed(command: arguments.first ?? "", message: message)
        }
        // Network commands report progress on stderr; keep it for the caller.
        return result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func guardBranch(_ branch: String, protectedBranches: Set<String>, allow: Bool) throws {
        guard !allow else { return }
        if protectedBranches.contains(branch) { throw RepoError.protectedBranch(branch) }
    }

    private func validateRefName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(" "), !name.contains(".."), !name.hasSuffix("/") else {
            throw RepoError.invalidArgument("'\(name)' is not a valid branch name.")
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
