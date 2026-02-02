import SwiftUI
import FleetMateCore

/// View mode for Tasks
enum TaskViewMode: String, CaseIterable {
    case list = "List"
    case board = "Board"
}

/// Kanban board view for tasks - drag cards between columns to change state
struct TaskBoardView: View {
    let tasks: [UnifiedTaskItem]
    let onSelectTask: (UnifiedTaskItem) -> Void
    
    // Define state columns
    private var stateColumns: [(state: String, color: Color)] {
        [
            ("Not Started", .blue),
            ("In Progress", .orange),
            ("Completed", .green),
            ("Active", .blue),
            ("Resolved", .green),
            ("Closed", .gray)
        ]
    }
    
    // Get unique states from tasks
    private var uniqueStates: [String] {
        let allStates = Set(tasks.map { $0.state })
        // Order by known states first, then any others
        let knownOrder = ["Not Started", "New", "Active", "Open", "In Progress", "Pending", "Waiting", "Resolved", "Completed", "Done", "Closed"]
        return knownOrder.filter { allStates.contains($0) } + allStates.filter { !knownOrder.contains($0) }.sorted()
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(uniqueStates, id: \.self) { state in
                    TaskStateColumn(
                        state: state,
                        tasks: tasks.filter { $0.state == state },
                        onSelectTask: onSelectTask
                    )
                }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.03))
    }
}

/// A single state column in the Tasks Kanban board
struct TaskStateColumn: View {
    let state: String
    let tasks: [UnifiedTaskItem]
    let onSelectTask: (UnifiedTaskItem) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(state)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(tasks.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(stateColor.opacity(0.2))
            
            // Cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(tasks, id: \.id) { task in
                        TaskBoardCard(task: task)
                            .onTapGesture {
                                onSelectTask(task)
                            }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 260)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var stateColor: Color {
        let s = state.lowercased()
        if s.contains("new") || s.contains("not started") || s.contains("open") {
            return .blue
        } else if s.contains("progress") || s.contains("active") {
            return .orange
        } else if s.contains("pending") || s.contains("waiting") {
            return .yellow
        } else if s.contains("resolved") || s.contains("completed") || s.contains("done") {
            return .green
        } else if s.contains("closed") {
            return .gray
        }
        return .secondary
    }
}

/// Individual task card in the Kanban board
struct TaskBoardCard: View {
    let task: UnifiedTaskItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Source badge and priority
            HStack {
                TaskSourceBadge(source: task.source)
                Spacer()
                if let priority = task.priority {
                    TaskPriorityBadge(priority: priority)
                }
            }
            
            // Title
            Text(task.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundColor(.primary)
            
            // Metadata
            HStack(spacing: 8) {
                Text(task.type)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                
                Spacer()
                
                if let assignee = task.assignedTo {
                    Label {
                        Text(assignee)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "person.fill")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            // Due date if present
            if let due = task.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(due, style: .date)
                        .font(.caption)
                }
                .foregroundColor(due < Date() ? .red : .secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct TaskPriorityBadge: View {
    let priority: Int
    
    var body: some View {
        let (color, label): (Color, String) = {
            switch priority {
            case 1: return (.red, "P1")
            case 2: return (.orange, "P2")
            case 3: return (.yellow, "P3")
            default: return (.gray, "P\(priority)")
            }
        }()
        
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

#Preview {
    TaskBoardView(
        tasks: [],
        onSelectTask: { _ in }
    )
}
