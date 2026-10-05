import Foundation
import CryptoKit

/// FleetMate's local copy of what it has fetched from GitHub, kept on disk so
/// it survives relaunches and shared by every client and tab. Polls ask only
/// for what changed:
///
/// - **REST GETs** keep their body with its ETag / Last-Modified, so the next
///   poll is a conditional request, and a 304 (free) answers from here.
///   Paths that send `X-Poll-Interval` are not asked again inside it.
/// - **Searches** keep their result rows; later polls ask only for rows
///   updated since the last sync and merge them in (`GitHubSearchDelta`).
///   A full resync runs once a day or on a manual refresh, to catch what a
///   delta can't see, like a row that silently stops matching.
public final class GitHubLocalCache: @unchecked Sendable {
    public static let shared = GitHubLocalCache()

    /// How long a delta-synced search is trusted before a full resync.
    public static let fullResyncInterval: TimeInterval = 24 * 60 * 60

    struct RESTEntry: Codable {
        var etag: String?
        var lastModified: String?
        var body: Data
        var fetchedAt: Date
        var pollInterval: TimeInterval?

        var isWithinPollInterval: Bool {
            guard let pollInterval else { return false }
            return Date().timeIntervalSince(fetchedAt) < pollInterval
        }
    }

    /// A search's rows as GitHub returned them, plus when they were synced.
    public struct SearchSnapshot: Codable {
        public var nodes: [Data]
        public var syncedAt: Date
        public var fullSyncAt: Date
    }

    private let lock = NSLock()
    private var rest: [String: RESTEntry] = [:]
    private var searches: [String: SearchSnapshot] = [:]
    private let restDir: URL
    private let searchDir: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FleetMate/github-cache", isDirectory: true)
        restDir = base.appendingPathComponent("rest", isDirectory: true)
        searchDir = base.appendingPathComponent("search", isDirectory: true)
        for dir in [restDir, searchDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        prune()
    }

    // MARK: REST

    func restEntry(for path: String) -> RESTEntry? {
        lock.lock(); defer { lock.unlock() }
        if let entry = rest[path] { return entry }
        guard let data = try? Data(contentsOf: file(in: restDir, for: path)),
              let entry = try? JSONDecoder().decode(RESTEntry.self, from: data) else { return nil }
        rest[path] = entry
        return entry
    }

    func storeREST(path: String, body: Data, etag: String?, lastModified: String?, pollInterval: TimeInterval?) {
        // Nothing to revalidate with: keeping it would only cost disk.
        guard etag != nil || lastModified != nil || pollInterval != nil else { return }
        let entry = RESTEntry(etag: etag, lastModified: lastModified, body: body,
                              fetchedAt: Date(), pollInterval: pollInterval)
        lock.lock()
        rest[path] = entry
        lock.unlock()
        write(entry, to: file(in: restDir, for: path))
    }

    /// A 304: the stored body is current as of now.
    func touch(path: String, pollInterval: TimeInterval?) {
        lock.lock()
        guard var entry = rest[path] else { lock.unlock(); return }
        entry.fetchedAt = Date()
        if let pollInterval { entry.pollInterval = pollInterval }
        rest[path] = entry
        lock.unlock()
        write(entry, to: file(in: restDir, for: path))
    }

    // MARK: Searches

    public func searchSnapshot(for key: String) -> SearchSnapshot? {
        lock.lock(); defer { lock.unlock() }
        if let snapshot = searches[key] { return snapshot }
        guard let data = try? Data(contentsOf: file(in: searchDir, for: key)),
              let snapshot = try? JSONDecoder().decode(SearchSnapshot.self, from: data) else { return nil }
        searches[key] = snapshot
        return snapshot
    }

    public func storeSearch(_ snapshot: SearchSnapshot, for key: String) {
        lock.lock()
        searches[key] = snapshot
        lock.unlock()
        write(snapshot, to: file(in: searchDir, for: key))
    }

    /// Forget every search, so the next poll of each is a full sync.
    public func invalidateSearches() {
        lock.lock()
        searches.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: searchDir)
        try? FileManager.default.createDirectory(at: searchDir, withIntermediateDirectories: true)
    }

    // MARK: Files

    private func file(in dir: URL, for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(digest).json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drop anything untouched for a week, so the folder does not grow forever.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for dir in [restDir, searchDir] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
            }
        }
    }
}

/// Turns a pull-request search into "what changed since the last sync" and
/// merges the answer into the stored rows.
enum GitHubSearchDelta {
    /// Small overlap so an update landing during the previous sync is not missed.
    static let overlap: TimeInterval = 120

    /// The same search without `is:open`, limited to rows updated since the
    /// last sync — so PRs that closed or merged come back too, and can be
    /// dropped.
    static func deltaQuery(for query: String, since: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: since.addingTimeInterval(-overlap))
        let terms = query.split(separator: " ").filter { $0 != "is:open" }
        return (terms + ["updated:>=\(stamp)"]).joined(separator: " ")
    }

    /// Fold changed rows into the stored ones: open rows replace or join,
    /// closed or merged rows leave. Rows are matched by URL.
    static func merge(stored: [[String: Any]], changes: [[String: Any]]) -> [[String: Any]] {
        var byURL: [String: [String: Any]] = [:]
        var order: [String] = []
        for node in stored {
            guard let url = node["url"] as? String else { continue }
            if byURL[url] == nil { order.append(url) }
            byURL[url] = node
        }
        for node in changes {
            guard let url = node["url"] as? String else { continue }
            if (node["state"] as? String) == "OPEN" {
                if byURL[url] == nil { order.append(url) }
                byURL[url] = node
            } else {
                byURL[url] = nil
            }
        }
        let merged = order.compactMap { byURL[$0] }
        return merged.sorted {
            ($0["updatedAt"] as? String ?? "") > ($1["updatedAt"] as? String ?? "")
        }
    }

    static func encode(_ nodes: [[String: Any]]) -> [Data] {
        nodes.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    static func decode(_ data: [Data]) -> [[String: Any]] {
        data.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}
