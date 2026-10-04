import Foundation
import FleetMateCore

/// What the person has selected in FleetMate, for an agent to read. Views set
/// `AppState.agentSelection`; the file at `FLEETMATE_CONTEXT` is rewritten on
/// every change, so `cat "$FLEETMATE_CONTEXT"` always answers "what am I
/// looking at?".
struct AgentSelection: Equatable, Codable {
    /// device, asset, ticket, workItem, pullRequest, …
    var kind: String
    var id: String
    var title: String
    /// A few identifying fields — serial, asset tag, user — for lookups with
    /// the `fleetmate` CLI.
    var fields: [String: String] = [:]
}

enum AgentContextWriter {
    struct Payload: Codable {
        var app = "FleetMate"
        var tab: String
        var selection: AgentSelection?
        var updatedAt: Date
    }

    static func write(tab: String, selection: AgentSelection?, to path: String) {
        let payload = Payload(tab: tab, selection: selection, updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

extension AgentSelection {
    init(asset: SnipeAsset) {
        var fields: [String: String] = [:]
        fields["assetTag"] = asset.assetTag
        fields["serial"] = asset.serial
        fields["model"] = asset.model?.name
        fields["assignedTo"] = asset.assignedTo?.name
        fields["status"] = asset.statusLabel?.name
        self.init(kind: "asset", id: String(asset.id),
                  title: asset.displayName ?? asset.assetTag ?? "Asset",
                  fields: fields.compactMapValues { $0 })
    }

    init(ticket: TdxTicket) {
        var fields: [String: String] = [:]
        fields["status"] = ticket.statusName
        fields["requestor"] = ticket.requestorName
        self.init(kind: "ticket", id: ticket.id.map(String.init) ?? "",
                  title: ticket.title ?? "Ticket",
                  fields: fields.compactMapValues { $0 })
    }
}
