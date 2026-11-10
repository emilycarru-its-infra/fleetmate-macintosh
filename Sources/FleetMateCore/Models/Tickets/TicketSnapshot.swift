import Foundation

/// The last ticket list, saved so the next launch can show it while sign-in
/// and the fresh load run, instead of an empty window.
public enum TicketSnapshot {
    public static func fileURL(root: URL? = nil) -> URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(AppEdition.current.isTicketsOnly ? "TicketsMate" : "FleetMate", isDirectory: true)
            .appendingPathComponent("Tickets", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    public static func load(root: URL? = nil) -> [TdxTicket] {
        guard let data = try? Data(contentsOf: fileURL(root: root)),
              let tickets = try? JSONDecoder().decode([TdxTicket].self, from: data) else { return [] }
        return tickets
    }

    /// Written off the main thread; a failed write only costs the next
    /// launch its head start.
    public static func save(_ tickets: [TdxTicket], root: URL? = nil) {
        let url = fileURL(root: root)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(tickets) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    private struct ScopedSnapshot: Codable {
        let version: Int
        let scopeIdentifier: String
        let tickets: [TdxTicket]
    }

    public static func fileURL(scope: TicketInboxScope, root: URL? = nil) -> URL {
        fileURL(root: root).deletingLastPathComponent()
            .appendingPathComponent(scope.identifier, isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    public static func load(scope: TicketInboxScope, root: URL? = nil) -> [TdxTicket] {
        let url = fileURL(scope: scope, root: root)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ScopedSnapshot.self, from: data),
              snapshot.version == 1, snapshot.scopeIdentifier == scope.identifier else { return [] }
        return snapshot.tickets
    }

    public static func save(_ tickets: [TdxTicket], scope: TicketInboxScope, root: URL? = nil) {
        let url = fileURL(scope: scope, root: root)
        Task.detached(priority: .utility) {
            let snapshot = ScopedSnapshot(version: 1, scopeIdentifier: scope.identifier, tickets: tickets)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

}
