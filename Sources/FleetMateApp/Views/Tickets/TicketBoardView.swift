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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(label)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(tickets.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background((accentColor ?? .secondary).opacity(0.2))
            
            // Cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(tickets, id: \.id) { ticket in
                        TicketCard(ticket: ticket)
                            .draggable(TicketDragData(ticketId: ticket.id ?? 0, fromColumnKey: columnKey))
                            .onTapGesture {
                                onSelectTicket(ticket)
                            }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .dropDestination(for: TicketDragData.self) { items, _ in
            for item in items {
                if item.fromColumnKey != columnKey {
                    onDropTicket(item.ticketId)
                }
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
                        .font(.caption)
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
                .font(.subheadline)
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
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            // Responsible (if assigned)
            if let responsible = ticket.responsibleFullName {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                    Text(responsible)
                        .font(.caption)
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
            .font(.caption2)
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
