import CryptoKit
import Foundation

/// The ticket collection and authenticated person, independent of app edition.
public struct TicketInboxScope: Equatable, Sendable {
    public let serviceKey: String
    public let personUid: String

    public init?(ticketEndpoint: String, personUid: String) {
        guard let serviceKey = Self.serviceKey(ticketEndpoint: ticketEndpoint) else { return nil }
        let person = personUid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !person.isEmpty, !person.contains("/"), !person.contains("\\"),
              person != ".", person != ".." else { return nil }
        self.serviceKey = serviceKey
        self.personUid = person.lowercased()
    }

    public static func serviceKey(ticketEndpoint: String) -> String? {
        guard var parts = URLComponents(string: ticketEndpoint),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        let path = parts.percentEncodedPath.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = path.isEmpty ? "" : "/" + path
        guard let normalized = parts.string else { return nil }
        return digest(normalized)
    }

    public var identifier: String { Self.digest(serviceKey + "\n" + personUid) }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only read markers are shared. Private ticket bodies remain in each edition's cache.
public struct TicketInboxReadStore: Sendable {
    public static let legacyServiceSettingKey = "tickets.legacyServiceKey"
    public static let changedNotification = Notification.Name("FleetMate.ticketInboxReadStateChanged")

    public enum Change: Sendable {
        case read(Set<Int>)
        case unread(Set<Int>)
    }

    public enum StoreError: Error {
        case cannotLock
        case unsupportedVersion
        case oversizedState
    }

    public let scope: TicketInboxScope
    private let root: URL?
    private let edition: AppEdition
    private let legacyServiceKey: String?

    public init(scope: TicketInboxScope, root: URL? = nil, edition: AppEdition = .current,
                legacyServiceKey: String? = nil) {
        self.scope = scope
        self.root = root
        self.edition = edition
        self.legacyServiceKey = legacyServiceKey
    }

    public var directory: URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FleetMateShared/TicketInbox", isDirectory: true)
            .appendingPathComponent(scope.identifier, isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent("read-state.json") }

    /// Call off the main actor: the lock serializes tiny read/modify/write transactions.
    public func update(_ change: Change? = nil, now: Date = Date()) throws -> TicketInboxReadState {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("read-state.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreError.cannotLock }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN,
                  ProcessInfo.processInfo.systemUptime < deadline else { throw StoreError.cannotLock }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(descriptor, LOCK_UN) }

        var document = try loadDocument()
        let original = document
        // A declaration is required because the old UID-only files contain no service provenance.
        if legacyServiceKey == scope.serviceKey, !document.importedEditions.contains(edition.rawValue) {
            let legacy = legacyReadURL
            if !manager.fileExists(atPath: legacy.path) {
                document.importedEditions.insert(edition.rawValue)
            } else if let data = try? Data(contentsOf: legacy), data.count <= Self.maximumBytes,
                      let state = try? JSONDecoder().decode(TicketInboxReadState.self, from: data) {
                for id in state.readIds where document.marks[id] == nil {
                    document.marks[id] = Mark(isRead: true, changedAt: now)
                }
                document.importedEditions.insert(edition.rawValue)
            }
        }
        switch change {
        case .read(let ids):
            for id in ids { document.marks[id] = Mark(isRead: true, changedAt: now) }
        case .unread(let ids):
            for id in ids { document.marks[id] = Mark(isRead: false, changedAt: now) }
        case nil: break
        }
        // Read/unread tombstones outlive the message window, including late legacy imports.
        let cutoff = now.addingTimeInterval(-Double(TicketInbox.windowDays + 7) * 86_400)
        document.marks = document.marks.filter { $0.value.changedAt >= cutoff }
        if document != original {
            let data = try JSONEncoder().encode(document)
            guard data.count <= Self.maximumBytes else { throw StoreError.oversizedState }
            try data.write(to: fileURL, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            DistributedNotificationCenter.default().postNotificationName(
                Self.changedNotification, object: scope.identifier, userInfo: nil, deliverImmediately: true)
        }
        return TicketInboxReadState(readIds: Set(document.marks.compactMap { $0.value.isRead ? $0.key : nil }))
    }

    private static let maximumBytes = 16 * 1024 * 1024

    private var legacyReadURL: URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(edition.rawValue, isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent(scope.personUid + ".read.json")
    }

    private func loadDocument() throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document(scopeIdentifier: scope.identifier) }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes else { throw StoreError.oversizedState }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.scopeIdentifier == scope.identifier else { throw StoreError.unsupportedVersion }
        return document
    }

    private struct Mark: Codable, Equatable {
        let isRead: Bool
        let changedAt: Date
    }

    private struct Document: Codable, Equatable {
        let scopeIdentifier: String
        var version = 1
        var marks: [Int: Mark] = [:]
        var importedEditions: Set<String> = []
    }
}
