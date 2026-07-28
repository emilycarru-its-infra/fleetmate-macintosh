import SwiftUI
import FleetMateCore

/// View mode for Tasks
enum TaskViewMode: String, CaseIterable {
    case list = "List"
    case board = "Board"
}

/// Kanban board view for tasks - drag cards between columns to change state
struct TaskBoardView: View {
    let tasks: [UnifiedTask]
    let onSelectTask: (UnifiedTask) -> Void
    
    // Get unique states from tasks
    private var uniqueStates: [TaskState] {
        let allStates = Set(tasks.map { $0.state })
        // Order: open, inProgress, closed
        return TaskState.allCases.filter { allStates.contains($0) }
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
    let state: TaskState
    let tasks: [UnifiedTask]
    let onSelectTask: (UnifiedTask) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(state.displayName)
                    .appFont(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(tasks.count)")
                    .appFont(.subheadline)
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
        switch state {
        case .open:
            return .blue
        case .inProgress:
            return .orange
        case .closed:
            return .green
        }
    }
}

/// Individual task card in the Kanban board
struct TaskBoardCard: View {
    let task: UnifiedTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Provider badge and priority
            HStack {
                TaskProviderBadge(provider: task.provider)
                Spacer()
                if let priority = task.priority {
                    TaskPriorityBadge(priority: priority)
                }
            }
            
            // Title
            Text(task.title)
                .appFont(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundColor(.primary)
            
            // Metadata
            HStack(spacing: 8) {
                if let bucket = task.bucket {
                    Text(bucket)
                        .appFont(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                
                Spacer()
                
                if let assignee = task.assignees.first {
                    Label {
                        Text(assignee)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "person.fill")
                    }
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            // Due date if present
            if let due = task.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .appFont(.caption2)
                    Text(due, style: .date)
                        .appFont(.caption)
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

/// Badge showing the task provider (azdevops, github, gitea)
struct TaskProviderBadge: View {
    let provider: String
    
    var body: some View {
        let (color, icon): (Color, String) = {
            switch provider.lowercased() {
            case "azdevops", "azure", "devops":
                return (.blue, "cloud.fill")
            case "github":
                return (.purple, "chevron.left.forwardslash.chevron.right")
            case "gitea":
                return (.green, "leaf.fill")
            default:
                return (.gray, "square.grid.2x2")
            }
        }()
        
        HStack(spacing: 4) {
            Image(systemName: icon)
                .appFont(.caption2)
            Text(provider)
                .appFont(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.2))
        .foregroundColor(color)
        .cornerRadius(4)
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
            .appFont(.caption2)
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
