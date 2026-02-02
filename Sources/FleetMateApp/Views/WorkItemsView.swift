import SwiftUI
import FleetMateCore

/// Unified task item that can represent DevOps WorkItems or Planner Tasks
struct UnifiedTaskItem: Identifiable, Hashable {
    let id: String
    let source: TaskSource
    let title: String
    let state: String
    let type: String
    let priority: Int?
    let assignedTo: String?
    let dueDate: Date?
    let url: String?
    
    enum TaskSource: String, CaseIterable {
        case devops = "DevOps"
        case planner = "Planner"
    }
    
    init(workItem: WorkItem) {
        self.id = "devops-\(workItem.id)"
        self.source = .devops
        self.title = workItem.fields?.title ?? "Untitled"
        self.state = workItem.fields?.state ?? "Unknown"
        self.type = workItem.fields?.workItemType ?? "Task"
        self.priority = workItem.fields?.priority
        self.assignedTo = workItem.fields?.assignedTo?.displayName
        self.dueDate = nil
        self.url = workItem.url
    }
    
    init(plannerTask: PlannerTask) {
        self.id = "planner-\(plannerTask.id)"
        self.source = .planner
        self.title = plannerTask.title
        // Map percentComplete to state
        self.state = plannerTask.percentComplete >= 100 ? "Completed" :
                     plannerTask.percentComplete > 0 ? "In Progress" : "Not Started"
        self.type = "Task"
        // Map Planner priority (1=Urgent, 3=High, 5=Medium, 7=Low, 9=Lowest) to 1-4 scale
        self.priority = switch plannerTask.priority {
            case 1: 1
            case 3: 2
            case 5, 6, 7: 3
            default: 4
        }
        self.assignedTo = nil // Planner assignments handled separately
        self.dueDate = plannerTask.dueDateTime
        self.url = nil
    }
}

struct WorkItemsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var filterState: String?
    @State private var filterSource: UnifiedTaskItem.TaskSource?
    @State private var plannerTasks: [PlannerTask] = []
    @State private var plannerError: String?
    @State private var selectedTaskId: String?
    @State private var viewMode: TaskViewMode = .list  // List or Board view
    @State private var showDetailPanel = true
    
    var selectedTask: UnifiedTaskItem? {
        guard let id = selectedTaskId else { return nil }
        return unifiedTasks.first { $0.id == id }
    }

    // Combine DevOps work items and Planner tasks
    var unifiedTasks: [UnifiedTaskItem] {
        var items: [UnifiedTaskItem] = []
        
        // Add DevOps items
        items.append(contentsOf: appState.cachedWorkItems.map { UnifiedTaskItem(workItem: $0) })
        
        // Add Planner items
        items.append(contentsOf: plannerTasks.map { UnifiedTaskItem(plannerTask: $0) })
        
        return items
    }

    var filteredItems: [UnifiedTaskItem] {
        var result = unifiedTasks
        
        // Filter by source
        if let source = filterSource {
            result = result.filter { $0.source == source }
        }

        // Filter by state
        if let state = filterState {
            result = result.filter { $0.state.lowercased().contains(state.lowercased()) }
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.id.contains(searchText)
            }
        }

        return result
    }

    var body: some View {
        HSplitView {
            // Main content (list or board)
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("Tasks")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("\(filteredItems.count) of \(unifiedTasks.count) tasks")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    // View mode picker
                    Picker("View", selection: $viewMode) {
                        ForEach(TaskViewMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode == .list ? "list.bullet" : "square.grid.3x3")
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)

                    // Source filter
                    Picker("Source", selection: $filterSource) {
                        Text("All Sources").tag(nil as UnifiedTaskItem.TaskSource?)
                        ForEach(UnifiedTaskItem.TaskSource.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source as UnifiedTaskItem.TaskSource?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .labelsHidden()

                    Picker("State", selection: $filterState) {
                        Text("All States").tag(nil as String?)
                        Text("Active").tag("Active" as String?)
                        Text("In Progress").tag("In Progress" as String?)
                        Text("Completed").tag("Completed" as String?)
                        Text("Closed").tag("Closed" as String?)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .labelsHidden()
                    
                    Button(action: { showDetailPanel.toggle() }) {
                        Label("Details", systemImage: showDetailPanel ? "sidebar.trailing" : "sidebar.trailing")
                    }
                    .help("Toggle detail panel")

                    Button(action: loadAllTasks) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                .padding()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search tasks...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.bottom, 8)
                
                // Error message
                if let error = plannerError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                // Content - List or Board
                if isLoading {
                    VStack {
                        ProgressView("Loading tasks...")
                            .padding(.top, 50)
                        Spacer()
                    }
                } else if filteredItems.isEmpty {
                    VStack {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 30)
                        Spacer()
                    }
                } else if viewMode == .list {
                    Table(filteredItems, selection: $selectedTaskId) {
                        TableColumn("Source") { item in
                            TaskSourceBadge(source: item.source)
                        }
                        .width(min: 60, ideal: 80)

                        TableColumn("Type") { item in
                            WorkItemTypeBadge(type: item.type)
                        }
                        .width(min: 60, ideal: 80)

                        TableColumn("Title") { item in
                            Text(item.title)
                        }
                        .width(min: 200, ideal: 300)

                        TableColumn("State") { item in
                            WorkItemStateBadge(state: item.state)
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("Priority") { item in
                            PriorityIndicator(priority: item.priority)
                        }
                        .width(min: 60, ideal: 80)

                        TableColumn("Assigned") { item in
                            Text(item.assignedTo ?? "-")
                        }
                        .width(min: 100, ideal: 120)
                        
                        TableColumn("Due") { item in
                            if let due = item.dueDate {
                                Text(due, style: .date)
                                    .font(.caption)
                            } else {
                                Text("-")
                            }
                        }
                        .width(min: 80, ideal: 100)
                    }
                } else {
                    // Board view
                    TaskBoardView(
                        tasks: filteredItems,
                        onSelectTask: { task in
                            selectedTaskId = task.id
                            showDetailPanel = true
                        }
                    )
                }
            }
            .frame(minWidth: 400)
            
            // Detail panel
            if showDetailPanel {
                if let task = selectedTask {
                    TaskDetailPanel(task: task)
                        .frame(minWidth: 300)
                } else {
                    VStack {
                        ContentUnavailableView(
                            "No Task Selected",
                            systemImage: "checkmark.square",
                            description: Text("Select a task to view details")
                        )
                    }
                    .frame(minWidth: 300)
                }
            }
        }
        .task {
            if !appState.isWorkItemsCacheValid || plannerTasks.isEmpty {
                loadAllTasks()
            }
        }
    }

    private func loadAllTasks() {
        Task {
            isLoading = true
            plannerError = nil
            defer { isLoading = false }

            // Load DevOps work items
            if appState.config.isDevOpsConfigured {
                do {
                    let items = try await appState.devOpsService.getWorkItems(limit: 100)
                    appState.updateWorkItemsCache(items)
                } catch {
                    appState.errorMessage = "Failed to load DevOps work items: \(error.localizedDescription)"
                }
            }
            
            // Load Planner tasks
            await loadPlannerTasks()
        }
    }
    
    private func loadPlannerTasks() async {
        let plannerService = PlannerSyncService(config: appState.config)
        
        guard await plannerService.isEnabled else {
            plannerError = "Planner not configured (set tasks.planner.planId in config)"
            return
        }
        
        do {
            guard try await plannerService.authenticate() else {
                plannerError = "Planner auth failed - run 'az login' first"
                return
            }
            
            let tasks = try await plannerService.getPlannerTasks()
            await MainActor.run {
                self.plannerTasks = tasks
            }
        } catch {
            plannerError = "Planner: \(error.localizedDescription)"
        }
    }
}

struct TaskSourceBadge: View {
    let source: UnifiedTaskItem.TaskSource
    
    var body: some View {
        let (color, icon): (Color, String) = {
            switch source {
            case .devops: return (.blue, "cloud")
            case .planner: return (.purple, "checklist")
            }
        }()
        
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(source.rawValue)
                .font(.caption)
        }
    }
}

struct TaskDetailPanel: View {
    let task: UnifiedTaskItem
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TaskSourceBadge(source: task.source)
                        Spacer()
                        WorkItemStateBadge(state: task.state)
                    }
                    
                    Text(task.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
                
                // Details
                VStack(alignment: .leading, spacing: 12) {
                    Text("Details")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    TaskDetailRow(label: "ID", value: task.id.replacingOccurrences(of: "devops-", with: "").replacingOccurrences(of: "planner-", with: ""))
                    TaskDetailRow(label: "Type", value: task.type)
                    TaskDetailRow(label: "State", value: task.state)
                    TaskDetailRow(label: "Priority", value: task.priority.map { "P\($0)" } ?? "-")
                    TaskDetailRow(label: "Assigned To", value: task.assignedTo ?? "-")
                    
                    if let due = task.dueDate {
                        TaskDetailRow(label: "Due Date", value: due.formatted(date: .abbreviated, time: .omitted))
                    }
                    
                    if let url = task.url, !url.isEmpty {
                        HStack {
                            Text("Link")
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Link("Open in Browser", destination: URL(string: url)!)
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
                
                Spacer()
            }
            .padding()
        }
    }
}

struct TaskDetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}

struct WorkItemTypeBadge: View {
    let type: String?

    var body: some View {
        let (color, icon): (Color, String) = {
            switch type?.lowercased() {
            case "bug": return (.red, "ladybug")
            case "task": return (.blue, "checkmark.square")
            case "user story": return (.purple, "person")
            case "feature": return (.green, "star")
            case "epic": return (.orange, "flag")
            default: return (.gray, "doc")
            }
        }()

        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(type ?? "Unknown")
                .font(.caption)
        }
    }
}

struct WorkItemStateBadge: View {
    let state: String?

    var body: some View {
        let color: Color = {
            switch state?.lowercased() {
            case "new", "active": return .blue
            case "resolved", "done": return .green
            case "closed": return .gray
            default: return .secondary
            }
        }()

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state ?? "Unknown")
                .font(.caption)
        }
    }
}

struct PriorityIndicator: View {
    let priority: Int?

    var body: some View {
        let color: Color = {
            switch priority {
            case 1: return .red
            case 2: return .orange
            case 3: return .yellow
            case 4: return .green
            default: return .gray
            }
        }()

        HStack(spacing: 2) {
            ForEach(0..<(priority ?? 4), id: \.self) { _ in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

#Preview {
    WorkItemsView()
        .environmentObject(AppState())
}
