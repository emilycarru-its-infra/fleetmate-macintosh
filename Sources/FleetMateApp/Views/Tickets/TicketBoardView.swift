import SwiftUI
import FleetMateCore

/// Grouping options for the Kanban board. Responsible leads: it is the default
/// view and the one the queue is actually worked from.
enum BoardGroupBy: String, CaseIterable {
    case responsible = "Responsible"
    case status = "Status"
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
    let selectedTicketId: Int?
    /// Shared with the list view so folding a parent in one view folds it in both.
    @Binding var collapsedTicketIds: Set<Int>

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

    /// Responsible mode arranges people inside the Group they belong to —
    /// group blocks ordered alphabetically, responsibles alphabetical inside,
    /// Unassigned last within each block, groupless tickets in a trailing
    /// "No Group" block.
    private var responsibleGroupBlocks: [(group: String, columns: [(key: String, label: String, tickets: [TdxTicket])])] {
        var byGroup: [String: [TdxTicket]] = [:]
        for ticket in tickets {
            let group = ticket.responsibleGroupName?.isEmpty == false ? ticket.responsibleGroupName! : "No Group"
            byGroup[group, default: []].append(ticket)
        }
        let groupNames = byGroup.keys.sorted { a, b in
            if a == "No Group" { return false }
            if b == "No Group" { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return groupNames.map { name in
            (group: name,
             columns: stringFieldColumns(in: byGroup[name] ?? [],
                                         keyPath: \.responsibleFullName,
                                         fallback: "Unassigned",
                                         ordering: .alphabetical))
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
        stringFieldColumns(in: tickets, keyPath: keyPath, fallback: fallback, ordering: ordering)
    }

    private func stringFieldColumns(in tickets: [TdxTicket], keyPath: KeyPath<TdxTicket, String?>, fallback: String, ordering: ColumnOrdering = .alphabetical) -> [(key: String, label: String, tickets: [TdxTicket])] {
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
                if groupBy == .responsible {
                    // Group blocks envelop their people, the way the Inventory
                    // chip capsule envelops CPU/GPU/Memory/NPU.
                    ForEach(responsibleGroupBlocks, id: \.group) { block in
                        groupBlock(block.group, columns: block.columns)
                    }
                } else {
                    ForEach(columns, id: \.key) { col in
                        boardColumn(col)
                    }
                }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.03))
    }

    private func boardColumn(_ col: (key: String, label: String, tickets: [TdxTicket])) -> some View {
        BoardColumn(
            columnKey: col.key,
            label: col.label,
            tickets: col.tickets,
            accentColor: groupBy == .status ? statusColor(for: col.label) : nil,
            selectedTicketId: selectedTicketId,
            collapsedTicketIds: $collapsedTicketIds,
            onDropTicket: { ticketId in
                onDropTicket(ticketId, col.key)
            },
            onSelectTicket: onSelectTicket
        )
    }

    private func groupBlock(_ name: String, columns: [(key: String, label: String, tickets: [TdxTicket])]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .appFont(.subheadline, weight: .bold)
                Text(verbatim: "\(columns.reduce(0) { $0 + $1.tickets.count })")
                    .appFont(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.key) { col in
                    boardColumn(col)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundColor(Color.secondary.opacity(0.35))
        )
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
    let selectedTicketId: Int?
    @Binding var collapsedTicketIds: Set<Int>
    let onDropTicket: (Int) -> Void
    let onSelectTicket: (TdxTicket) -> Void

    @State private var isTargeted = false

    private var columnColor: Color { accentColor ?? .secondary }

    /// The column's cards as an outline. A parent only nests children that
    /// landed in this same column, so grouping by status still shows a parent's
    /// New and In Process children in their own columns.
    private var rows: [TicketOutlineRow] {
        TicketHierarchy.flatten(
            TicketHierarchy.build(from: tickets),
            collapsed: collapsedTicketIds
        )
    }

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
                    ForEach(rows) { row in
                        TicketCard(
                            ticket: row.ticket,
                            childCount: row.childCount,
                            isExpanded: row.isExpanded,
                            isSelected: selectedTicketId == row.ticket.id,
                            onToggleExpand: { toggleExpansion(row.id) }
                        )
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .draggable("\(row.ticket.id ?? 0)_\(columnKey)")
                        .onTapGesture {
                            onSelectTicket(row.ticket)
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

    private func toggleExpansion(_ ticketId: Int) {
        if collapsedTicketIds.contains(ticketId) {
            collapsedTicketIds.remove(ticketId)
        } else {
            collapsedTicketIds.insert(ticketId)
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
    var childCount: Int = 0
    var isExpanded: Bool = true
    var isSelected: Bool = false
    var onToggleExpand: (() -> Void)? = nil

    private var hasChildren: Bool { childCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Ticket ID and priority
            HStack {
                if hasChildren, let onToggleExpand {
                    Button(action: onToggleExpand) {
                        Image(systemName: "chevron.right")
                            .appFont(.caption2)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide child tickets" : "Show child tickets")
                }
                if let id = ticket.id {
                    Text(verbatim: "#\(id)")
                        .appFont(.caption)
                        .foregroundColor(.accentColor)
                        .fontWeight(.medium)
                }
                if hasChildren {
                    Text(verbatim: "\(childCount)")
                        .appFont(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                }
                Spacer()
                // Days since the last update, not days since it opened — this
                // is the card's only date, so it should be the one that shows
                // a ticket going quiet.
                AgeBadge(days: ticket.daysSinceLastActivity)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

/// Days since a ticket was last touched, always in days.
///
/// Deliberately never rolls up to months or years: on a queue card, "47d"
/// carries information that "2 months" throws away.
struct AgeBadge: View {
    let days: Int?

    var body: some View {
        if let days {
            let color: Color = days >= 30 ? .red : (days >= 14 ? .orange : .secondary)
            Text(verbatim: "\(days)d")
                .appFont(.caption2, design: .monospaced)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(4)
                .help(days == 0 ? "Updated today" : "No activity for \(days) day\(days == 1 ? "" : "s")")
        }
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
        onSelectTicket: { _ in },
        selectedTicketId: nil,
        collapsedTicketIds: .constant([])
    )
}
