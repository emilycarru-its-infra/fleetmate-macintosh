import SwiftUI
import FleetMateCore

/// Kanban board view for tickets - drag cards between columns to change status
struct TicketBoardView: View {
    let tickets: [TdxTicket]
    let statuses: [Int: String]
    let onUpdateStatus: (Int, Int) -> Void  // (ticketId, newStatusId)
    let onSelectTicket: (TdxTicket) -> Void
    
    // Define status order for columns (most common workflows)
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
        
        // Order statuses: Closed/Cancelled first (far left), then New -> In Progress/On Hold -> Resolved
        let order = ["closed", "cancelled", "new", "open", "in progress", "on hold", "pending", "waiting", "resolved", "completed"]
        
        return statusMap.sorted { a, b in
            let aIndex = order.firstIndex { a.value.lowercased().contains($0) } ?? 50
            let bIndex = order.firstIndex { b.value.lowercased().contains($0) } ?? 50
            return aIndex < bIndex
        }.map { (id: $0.key, name: $0.value) }
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(orderedStatuses, id: \.id) { status in
                    StatusColumn(
                        statusId: status.id,
                        statusName: status.name,
                        tickets: tickets.filter { $0.statusId == status.id },
                        onMoveTicket: { ticketId in
                            onUpdateStatus(ticketId, status.id)
                        },
                        onSelectTicket: onSelectTicket
                    )
                }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.03))
    }
}

/// A single status column in the Kanban board
struct StatusColumn: View {
    let statusId: Int
    let statusName: String
    let tickets: [TdxTicket]
    let onMoveTicket: (Int) -> Void
    let onSelectTicket: (TdxTicket) -> Void
    
    @State private var isTargeted = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(statusName)
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
            .background(statusColor.opacity(0.2))
            
            // Cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(tickets, id: \.id) { ticket in
                        TicketCard(ticket: ticket)
                            .draggable(TicketDragData(ticketId: ticket.id ?? 0, fromStatusId: statusId))
                            .onTapGesture {
                                onSelectTicket(ticket)
                            }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 280)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .dropDestination(for: TicketDragData.self) { items, _ in
            for item in items {
                if item.fromStatusId != statusId {
                    onMoveTicket(item.ticketId)
                }
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
    
    private var statusColor: Color {
        let name = statusName.lowercased()
        if name.contains("new") || name.contains("open") {
            return .blue
        } else if name.contains("progress") {
            return .orange
        } else if name.contains("hold") || name.contains("pending") || name.contains("waiting") {
            return .yellow
        } else if name.contains("resolved") || name.contains("completed") {
            return .green
        } else if name.contains("closed") {
            return .gray
        } else if name.contains("cancel") {
            return .red
        }
        return .secondary
    }
}

/// Draggable ticket data
struct TicketDragData: Codable, Transferable {
    let ticketId: Int
    let fromStatusId: Int
    
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
        onUpdateStatus: { _, _ in },
        onSelectTicket: { _ in }
    )
}
