import Foundation

// Adapted from MunkiStudio's IndexLockRecovery (Apache-2.0,
// Sources/App/Features/Git/IndexLockRecovery.swift).

/// A `.git/index.lock` left behind by a crashed or interrupted git process
/// is the most common reason staging or committing fails out of nowhere.
/// This finds the lock, says whether any process still holds it, and removes
/// it only when none does.
public enum GitIndexLock {
    /// Whether a git error is an index-lock conflict.
    public static func matches(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("index.lock") || lower.contains("another git process")
    }

    /// The lock file of the checkout at `path`, resolving a linked worktree's
    /// `.git` file to its real git directory.
    public static func lockPath(checkout path: String) -> String {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
           let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if !gitDir.hasPrefix("/") { gitDir = (path as NSString).appendingPathComponent(gitDir) }
            return (gitDir as NSString).appendingPathComponent("index.lock")
        }
        return (dotGit as NSString).appendingPathComponent("index.lock")
    }

    /// Processes that have the lock open, as `lsof` reports them; empty when
    /// none does and the lock is stale.
    public static func holders(of lockPath: String) async -> String {
        let result = await ProcessRunner.run("/usr/sbin/lsof", [lockPath])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a stale lock. Refuses while a process still holds it.
    public static func removeStale(at lockPath: String) async throws {
        let holders = await holders(of: lockPath)
        guard holders.isEmpty else {
            throw RepoError.invalidArgument("A git process still holds \(lockPath):\n\(holders)")
        }
        do {
            try FileManager.default.removeItem(atPath: lockPath)
        } catch CocoaError.fileNoSuchFile {
            // Already gone: the retry can run.
        }
    }
}
