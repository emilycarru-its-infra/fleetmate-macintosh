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
}
