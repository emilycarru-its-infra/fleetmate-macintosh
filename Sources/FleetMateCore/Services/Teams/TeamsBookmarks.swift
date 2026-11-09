import CryptoKit
import Foundation

/// Local organization only. Full message bodies are fetched from the API when opened.
public struct TeamsBookmark: Codable, Sendable, Equatable, Identifiable {
    public let threadId: String
    public let channelId: String
    public let teamId: String
    public var title: String
    public let teamName: String
    public let channelName: String
    public let webUrl: String?
    public var collection: String
    public let savedAt: Date
    public var id: String { "\(channelId)/\(threadId)" }

    public init(hit: TeamsSearchHit, title: String, collection: String, now: Date = Date()) {
        threadId = hit.threadId
        channelId = hit.channelId
        teamId = hit.teamId
        self.title = String(TeamsText.line(title).prefix(240))
        teamName = hit.teamName
        channelName = hit.channelName
        webUrl = hit.webUrl
        self.collection = String(TeamsText.line(collection).prefix(80))
        savedAt = now
    }

    public var reference: TeamsSearchHit {
        TeamsSearchHit(threadId: threadId, teamId: teamId, teamName: teamName,
                       channelId: channelId, channelName: channelName, subject: title,
                       snippet: "", authorDisplayName: nil, createdAt: "", lastActivityAt: "",
                       replyCount: 0, participants: [], score: 0, webUrl: webUrl)
    }
}

public enum TeamsBookmarkScope {
    /// This is storage partitioning, never token validation or an authorization decision.
    public static func key(endpoint: String, token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tenant = claims["tid"] as? String, !tenant.isEmpty,
              let person = claims["oid"] as? String, !person.isEmpty else { return nil }
        var endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        let value = endpoint + "\n" + tenant.lowercased() + "\n" + person.lowercased()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TeamsBookmarkStore {
    public enum StoreError: Error, LocalizedError {
        case invalidAccount, unsupportedFile
        public var errorDescription: String? {
            switch self {
            case .invalidAccount: "Saved threads need an identifiable signed-in account."
            case .unsupportedFile: "Saved threads could not be read. The existing file has been preserved."
            }
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let bookmarks: [TeamsBookmark]
        var followedChannels: [String]? = nil
    }
    private let directory: URL
    public let fileURL: URL

    public init(directory: URL, accountKey: String) throws {
        guard accountKey.count == 64, accountKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw StoreError.invalidAccount
        }
        self.directory = directory
        fileURL = directory.appendingPathComponent(accountKey + ".json")
    }

    public func load() throws -> [TeamsBookmark] { try read().bookmarks }

    public func loadFollowing() throws -> [String] { try read().followedChannels ?? [] }

    private func read() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Envelope(version: 1, bookmarks: []) }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) < 8_388_608 else {
            throw StoreError.unsupportedFile
        }
        do {
            let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
            guard value.version == 1 else { throw StoreError.unsupportedFile }
            return value
        } catch { throw StoreError.unsupportedFile }
    }

    public func save(_ bookmarks: [TeamsBookmark]) throws {
        let existing = try read()
        try write(Envelope(version: 1, bookmarks: bookmarks, followedChannels: existing.followedChannels))
    }

    public func saveFollowing(_ channelIDs: [String]) throws {
        let channels = Array(Set(channelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard channels.count <= 500, channels.allSatisfy({ !$0.isEmpty && $0.count <= 500 }) else {
            throw StoreError.unsupportedFile
        }
        let existing = try read()
        try write(Envelope(version: 1, bookmarks: existing.bookmarks, followedChannels: channels))
    }

    private func write(_ envelope: Envelope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
