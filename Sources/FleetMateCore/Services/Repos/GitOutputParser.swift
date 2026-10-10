import Foundation

/// Pure parsers for git's machine-readable output. Kept free of process
/// spawning so they are tested against hand-written fixtures.
public enum GitOutputParser {

    /// Parses `git status --porcelain=v2 --branch -z`.
    ///
    /// Records are NUL-separated. A rename or copy (`2 …`) is followed by one
    /// more NUL-terminated field holding the original path.
    public static func status(_ output: String) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]

        while let record = fields.popFirst() {
            if record.hasPrefix("# ") {
                header(record, into: &snapshot)
                continue
            }
            guard let type = record.first else { continue }
            switch type {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                let xy = Array(parts[1])
                snapshot.changes.append(RepoFileChange(path: String(parts[8]), kind: .changed, indexStatus: xy.first ?? ".", worktreeStatus: xy.last ?? "."))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path  \0 origPath
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                let xy = Array(parts[1])
                let original = fields.popFirst()
                snapshot.changes.append(RepoFileChange(path: String(parts[9]), originalPath: original, kind: .renamed, indexStatus: xy.first ?? ".", worktreeStatus: xy.last ?? "."))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                let xy = Array(parts[1])
                snapshot.changes.append(RepoFileChange(path: String(parts[10]), kind: .unmerged, indexStatus: xy.first ?? "U", worktreeStatus: xy.last ?? "U"))
            case "?":
                snapshot.changes.append(RepoFileChange(path: String(record.dropFirst(2)), kind: .untracked, indexStatus: "?", worktreeStatus: "?"))
            case "!":
                snapshot.changes.append(RepoFileChange(path: String(record.dropFirst(2)), kind: .ignored, indexStatus: "!", worktreeStatus: "!"))
            default:
                continue
            }
        }
        return snapshot
    }

    private static func header(_ record: String, into snapshot: inout GitStatusSnapshot) {
        let body = record.dropFirst(2)
        guard let space = body.firstIndex(of: " ") else { return }
        let key = body[..<space]
        let value = String(body[body.index(after: space)...])
        switch key {
        case "branch.oid":
            snapshot.headOid = value == "(initial)" ? nil : value
        case "branch.head":
            snapshot.branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            snapshot.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { snapshot.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { snapshot.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    /// Parses `git worktree list --porcelain`.
    public static func worktrees(_ output: String) -> [RepoWorktree] {
        var result: [RepoWorktree] = []
        for block in output.components(separatedBy: "\n\n") {
            var path: String?
            var head: String?
            var branch: String?
            var detached = false, bare = false, locked = false, prunable = false
            for line in block.split(separator: "\n") {
                let (key, value) = splitOnce(String(line))
                switch key {
                case "worktree": path = value
                case "HEAD": head = value
                case "branch": branch = value.map(RepoKey.shortBranch)
                case "detached": detached = true
                case "bare": bare = true
                case "locked": locked = true
                case "prunable": prunable = true
                default: break
                }
            }
            if let path {
                result.append(RepoWorktree(path: path, head: head, branch: branch, isDetached: detached, isBare: bare, isLocked: locked, isPrunable: prunable))
            }
        }
        return result
    }

    /// The `--format` `log(_:)` expects: fields split by US (0x1f), records by RS (0x1e).
    public static let logFormat = "%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"

    public static func log(_ output: String) -> [RepoCommit] {
        let iso = ISO8601DateFormatter()
        return output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count == 6 else { return nil }
            return RepoCommit(sha: fields[0], shortSha: fields[1], author: fields[2], email: fields[3], date: iso.date(from: fields[4]), subject: fields[5])
        }
    }

    /// Parses `git grep -n -z --column`: `path\0line\0column\0text` per line.
    public static func grep(_ output: String) -> [RepoGrepMatch] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let number = Int(parts[1]), let column = Int(parts[2]) else { return nil }
            return RepoGrepMatch(path: String(parts[0]), line: number, column: column, text: String(parts[3]))
        }
    }

    /// NUL-separated path list (`git ls-files -z`).
    public static func paths(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    private static func splitOnce(_ line: String) -> (String, String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
