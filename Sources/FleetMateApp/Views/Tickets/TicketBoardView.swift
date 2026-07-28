import SwiftUI
import FleetMateCore

/// Grouping options for the Kanban board
enum BoardGroupBy: String, CaseIterable {
    case status = "Status"
    case responsible = "Responsible"
    case priority = "Priority"
    case group = "Group"
}

/// Kanban board view for tickets - drag cards between columns to update the grouped field
struct TicketBoardView: View {
    let tickets: [TdxTicket]
    let statuses: [Int: String]
    let groupBy: BoardGroupBy
    /// Called when a card is dropped on a column: (ticketId, targetColumnKey)
    let onDropTicket: (Int, String) -> Void
    let onSelectTicket: (TdxTicket) -> Void
    
    // MARK: - Grouped columns based on groupBy

    private var columns: [(key: String, label: String, tickets: [TdxTicket])] {
        switch groupBy {
        case .status:
            return statusColumns
        case .responsible:
            return stringFieldColumns(keyPath: \.responsibleFullName, fallback: "Unassigned", ordering: .alphabetical)
        case .priority:
            return stringFieldColumns(keyPath: \.priorityName, fallback: "No Priority", ordering: .priority)
        case .group:
            return stringFieldColumns(keyPath: \.responsibleGroupName, fallback: "No Group", ordering: .alphabetical)
        }
    }

    private var statusColumns: [(key: String, label: String, tickets: [TdxTicket])] {
        let ordered = orderedStatuses
        return ordered.map { status in
            (key: "\(status.id)", label: status.name, tickets: tickets.filter { $0.statusId == status.id })
        }
    }

    private enum ColumnOrdering {
        case alphabetical
        case priority
    }

    private func stringFieldColumns(keyPath: KeyPath<TdxTicket, String?>, fallback: String, ordering: ColumnOrdering = .alphabetical) -> [(key: String, label: String, tickets: [TdxTicket])] {
        var groups: [String: [TdxTicket]] = [:]
        for ticket in tickets {
            let val = ticket[keyPath: keyPath] ?? fallback
            groups[val, default: []].append(ticket)
        }
        let keys: [String]
        switch ordering {
        case .alphabetical:
            keys = groups.keys.sorted { a, b in
                // Put fallback last
                if a == fallback { return false }
                if b == fallback { return true }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .priority:
            let order = ["low", "medium", "high", "urgent", "critical"]
            keys = groups.keys.sorted { a, b in
                let aIdx = order.firstIndex(where: { a.lowercased().contains($0) }) ?? 50
                let bIdx = order.firstIndex(where: { b.lowercased().contains($0) }) ?? 50
                return aIdx < bIdx
            }
        }
        return keys.map { key in (key: key, label: key, tickets: groups[key] ?? []) }
    }

    // Define status order for columns
    private var orderedStatuses: [(id: Int, name: String)] {
        // If statuses dictionary is provided and not empty, use it
        // Otherwise, derive statuses from the tickets themselves
        var statusMap = statuses
        
        if statusMap.isEmpty {
            // Build status map from tickets
            for ticket in tickets {
                if let statusId = ticket.statusId, let statusName = ticket.statusName {
                    statusMap[statusId] = statusName
                }
            }
        }
        
        // Order statuses: New -> In Progress -> On Hold -> then others -> Closed/Cancelled last
        let order = ["new", "open", "in progress", "on hold", "pending", "waiting", "resolved", "completed", "closed", "cancelled"]
        
        return statusMap.sorted { a, b in
            let aIndex = order.firstIndex { a.value.lowercased().contains($0) } ?? 50
            let bIndex = order.firstIndex { b.value.lowercased().contains($0) } ?? 50
            return aIndex < bIndex
        }.map { (id: $0.key, name: $0.value) }
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns, id: \.key) { col in
                    BoardColumn(
                        columnKey: col.key,
                        label: col.label,
                        tickets: col.tickets,
                        accentColor: groupBy == .status ? statusColor(for: col.label) : nil,
                        onDropTicket: { ticketId in
                            onDropTicket(ticketId, col.key)
                        },
                        onSelectTicket: onSelectTicket
                    )
                }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.03))
    }

    private func statusColor(for name: String) -> Color {
        let n = name.lowercased()
        if n.contains("new") || n.contains("open") { return .blue }
        if n.contains("progress") { return .orange }
        if n.contains("hold") || n.contains("pending") || n.contains("waiting") { return .yellow }
        if n.contains("resolved") || n.contains("completed") { return .green }
        if n.contains("closed") { return .gray }
        if n.contains("cancel") { return .red }
        return .secondary
    }
}

/// Unified draggable column for all group-by modes
struct BoardColumn: View {
    let columnKey: String
    let label: String
    let tickets: [TdxTicket]
    let accentColor: Color?
    let onDropTicket: (Int) -> Void
    let onSelectTicket: (TdxTicket) -> Void
    
    @State private var isTargeted = false

    private var columnColor: Color { accentColor ?? .secondary }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Circle().fill(columnColor).frame(width: 10, height: 10)
                Text(label)
                    .fontWeight(.semibold)
                Text("(\(tickets.count))")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tickets, id: \.id) { ticket in
                        TicketCard(ticket: ticket)
                            .draggable("\(ticket.id ?? 0)_\(columnKey)")
                            .onTapGesture {
                                onSelectTicket(ticket)
                            }
                    }
                    // Empty column drop zone
                    if tickets.isEmpty {
                        Text("Drop items here")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 280)
        .background(isTargeted ? columnColor.opacity(0.15) : Color.secondary.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? columnColor : Color.clear, lineWidth: 2)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            let parts = payload.split(separator: "_", maxSplits: 1)
            guard let ticketId = Int(parts.first ?? "") else { return false }
            let fromColumn = parts.count > 1 ? String(parts[1]) : ""
            if fromColumn != columnKey {
                onDropTicket(ticketId)
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

/// Draggable ticket data — generic across all group-by modes
struct TicketDragData: Codable, Transferable {
    let ticketId: Int
    let fromColumnKey: String
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: TicketDragData.self, contentType: .json)
    }
}

/// Individual ticket card in the Kanban board
struct TicketCard: View {
    let ticket: TdxTicket
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Ticket ID and priority
            HStack {
                if let id = ticket.id {
                    Text(verbatim: "#\(id)")
                        .appFont(.caption)
                        .foregroundColor(.accentColor)
                        .fontWeight(.medium)
                }
                Spacer()
                if let priority = ticket.priorityName {
                    PriorityBadge(priority: priority)
                }
            }
            
            // Title
            Text(ticket.title ?? "Untitled")
                .appFont(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundColor(.primary)
            
            // Requestor and Group
            HStack(spacing: 8) {
                if let requestor = ticket.requestorName {
                    Label {
                        Text(requestor)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "person")
                    }
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            // Responsible (if assigned)
            if let responsible = ticket.responsibleFullName {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .appFont(.caption2)
                    Text(responsible)
                        .appFont(.caption)
                }
                .foregroundColor(.accentColor)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct PriorityBadge: View {
    let priority: String
    
    var body: some View {
        let color: Color = {
            let p = priority.lowercased()
            if p.contains("urgent") || p.contains("critical") || p.contains("high") {
                return .red
            } else if p.contains("medium") {
                return .orange
            } else if p.contains("low") {
                return .green
            }
            return .gray
        }()
        
        Text(priority)
            .appFont(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

#Preview {
    TicketBoardView(
        tickets: [],
        statuses: [1: "New", 2: "In Progress", 3: "Resolved", 4: "Closed"],
        groupBy: .status,
        onDropTicket: { _, _ in },
        onSelectTicket: { _ in }
    )
}
