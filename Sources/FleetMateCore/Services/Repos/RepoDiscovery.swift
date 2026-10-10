import Foundation

/// A git checkout found on disk.
public struct DiscoveredCheckout: Codable, Sendable, Hashable {
    public let path: String
    public let remoteUrl: String?
    public let key: RepoKey?
}

/// Walks scan roots for git checkouts.
///
/// A folder is a checkout when it holds `.git` (a directory, or a file for a
/// submodule). The walk stops descending at a checkout, skips hidden folders
/// and the configured skip list (`.worktrees`, `node_modules`, `.build`, …),
/// and never goes deeper than `maxDepth` levels below a root. Linked worktrees
/// are not reported: they belong to the checkout they were added from.
public enum RepoDiscovery {

    /// Paths of checkouts under `roots`, found without spawning a process.
    public static func findCheckouts(roots: [String], maxDepth: Int, skip: [String]) -> [String] {
        let fm = FileManager.default
        let skipSet = Set(skip.map { $0.lowercased() })
        var found: [String] = []

        func walk(_ directory: String, depth: Int) {
            if isCheckout(directory) {
                found.append(directory)
                return
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(atPath: directory) else { return }
            for child in children.sorted() {
                if child.hasPrefix(".") || skipSet.contains(child.lowercased()) { continue }
                let full = (directory as NSString).appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                // Do not follow symlinked folders: they lead to loops and duplicates.
                if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil { continue }
                walk(full, depth: depth + 1)
            }
        }

        for root in roots {
            let expanded = RepoSettings.expand(root)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            walk(expanded, depth: 0)
        }
        return found
    }

    /// True for a main checkout or submodule; false for a linked worktree,
    /// whose `.git` file points into another repository's `worktrees/` folder.
    static func isCheckout(_ directory: String) -> Bool {
        let dotGit = (directory as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return true }
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return false }
        return !pointer.contains("/worktrees/")
    }

    /// Finds checkouts and reads each one's origin, `concurrency` at a time.
    public static func discover(settings: RepoSettings) async -> [DiscoveredCheckout] {
        let paths = findCheckouts(roots: settings.scanRoots, maxDepth: settings.scanDepth, skip: settings.skipDirectories)
        return await boundedMap(paths, limit: settings.concurrency) { path in
            let origin = await GitWorkingCopy(path: path).originURL()
            return DiscoveredCheckout(path: path, remoteUrl: origin, key: origin.flatMap(RepoRemoteURL.parse))
        }
    }
}

/// Maps `items` through `transform` with at most `limit` running at once,
/// preserving order.
public func boundedMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async -> R
) async -> [R] {
    guard !items.isEmpty else { return [] }
    let width = max(1, limit)
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(width, items.count) {
            let index = next, item = items[index]
            group.addTask { (index, await transform(item)) }
            next += 1
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let i = next, item = items[i]
                group.addTask { (i, await transform(item)) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}
