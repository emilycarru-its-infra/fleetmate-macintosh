import Foundation

/// Unsent comment and reply text, kept on disk as it is typed so a crash or
/// a quit never loses it. Cleared once the text is posted or deleted.
enum UnsentDraftStore {
    private static let key = "tickets.unsentDrafts"

    private static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func comment(ticketId: Int) -> String? { all["comment.\(ticketId)"] }

    static func setComment(_ text: String, ticketId: Int) {
        set(text, for: "comment.\(ticketId)")
    }

    static func reply(entryId: Int) -> String? { all["reply.\(entryId)"] }

    /// Mirror the open reply drafts: every entry listed is saved, and saved
    /// replies for this ticket's other entries are dropped.
    static func setReplies(_ texts: [Int: String], entryIds: Set<Int>) {
        var stored = all
        for id in entryIds where texts[id] == nil { stored["reply.\(id)"] = nil }
        for (id, text) in texts {
            stored["reply.\(id)"] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        all = stored
    }

    private static func set(_ text: String, for name: String) {
        var stored = all
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard stored[name] != value else { return }
        stored[name] = value
        all = stored
    }
}
