import SwiftUI
import FleetMateCore

enum BoardsViewMode: String, CaseIterable {
    case board = "Board"
    case list = "List"
}

struct BoardsView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewMode: BoardsViewMode = .board
    @State private var allTasks: [UnifiedTask] = []
    @State private var buckets: [String] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var filterProvider: String?
    @State private var filterBucket: String?
    @State private var showClosed = false
    @State private var selectedTask: UnifiedTask?
    @State private var isSyncing = false
    @State private var showSyncAlert = false
    @State private var syncMessage = ""

    // List mode state (AzDO work items)
    @State private var listSearchText = ""
    @State private var listFilterState: String?
    @State private var isLoadingList = false

    var workItems: [WorkItem] { appState.cachedWorkItems }

    var filteredWorkItems: [WorkItem] {
        var result = workItems
        if let state = listFilterState {
            result = result.filter { $0.fields?.state?.lowercased() == state.lowercased() }
        }
        if !listSearchText.isEmpty {
            result = result.filter {
                ($0.fields?.title?.localizedCaseInsensitiveContains(listSearchText) ?? false) ||
                "\($0.id)".contains(listSearchText)
            }
        }
        return result
    }

    private var filteredTasks: [UnifiedTask] {
        var result = allTasks
        
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        
        if let bucket = filterBucket, bucket != "All Buckets" {
            result = result.filter { $0.bucket == bucket }
        }
        
        return result
    }
    
    private var openTasks: [UnifiedTask] {
        filteredTasks.filter { $0.state == .open }
    }
    
    private var inProgressTasks: [UnifiedTask] {
        filteredTasks.filter { $0.state == .inProgress }
    }
    
    private var closedTasks: [UnifiedTask] {
        let closed = filteredTasks.filter { $0.state == .closed }
        return showClosed ? closed : Array(closed.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Projects")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Unified task management across all providers")
                        .foregroundColor(.secondary)
                }

                Spacer()

                // AzDO SSO status/button
                if appState.devOpsSsoAuthenticated, let user = appState.devOpsAuthenticatedUserName {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundColor(.green)
                        Text(user)
                            .font(.caption)
                        Button(action: { appState.signOutDevOpsSso() }) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Sign out of Azure DevOps")
                    }
                } else if appState.isDevOpsSsoConfigured {
                    Button(action: { appState.triggerDevOpsSsoLogin() }) {
                        Label("Sign In", systemImage: "person.crop.circle.badge.questionmark")
                    }
                    .help("Sign in to Azure DevOps via SSO")
                }
            }
            .padding()

            // View mode toggle row — toggle on the left
            HStack(spacing: 12) {
                Picker("", selection: $viewMode) {
                    Text("Board").tag(BoardsViewMode.board)
                    Text("List").tag(BoardsViewMode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Content based on view mode
            switch viewMode {
            case .board:
                boardContent
            case .list:
                listContent
            }
        }
        .task {
            if allTasks.isEmpty {
                loadTasks()
            }
        }
        .alert("Sync Complete", isPresented: $showSyncAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(syncMessage)
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailSheet(task: task)
        }
    }

    // MARK: - Board Content (Kanban)

    private var boardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Board toolbar
            HStack {
                // Provider filter
                Picker("Provider", selection: $filterProvider) {
                    Text("All Providers").tag(nil as String?)
                    Text("Azure DevOps").tag("azdo" as String?)
                    Text("GitHub").tag("github" as String?)
                    Text("Gitea").tag("gitea" as String?)
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .onChange(of: filterProvider) {
                    loadTasks()
                }

                Button(action: syncTasks) {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)

                Button(action: loadTasks) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Search and filters
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search tasks...", text: $searchText)
                    .textFieldStyle(.plain)

                Picker("Bucket", selection: $filterBucket) {
                    Text("All Buckets").tag(nil as String?)
                    ForEach(buckets, id: \.self) { bucket in
                        Text(bucket).tag(bucket as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                Toggle("Show Closed", isOn: $showClosed)

                Text("\(filteredTasks.count) tasks")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Kanban Board
            if isLoading {
                VStack {
                    ProgressView("Loading tasks...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    KanbanColumn(title: "Open", color: .green, tasks: openTasks, onSelect: selectTask)
                    KanbanColumn(title: "In Progress", color: .blue, tasks: inProgressTasks, onSelect: selectTask)
                    KanbanColumn(title: "Closed", color: .gray, tasks: closedTasks, onSelect: selectTask)
                }
                .padding()
            }
        }
    }

    // MARK: - List Content (AzDO Work Items)

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // List toolbar
            HStack {
                Picker("State", selection: $listFilterState) {
                    Text("All").tag(nil as String?)
                    Text("Active").tag("Active" as String?)
                    Text("Resolved").tag("Resolved" as String?)
                    Text("Closed").tag("Closed" as String?)
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Button(action: loadWorkItems) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingList)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search work items...", text: $listSearchText)
                    .textFieldStyle(.plain)
                if !filteredWorkItems.isEmpty {
                    Text("\(filteredWorkItems.count) items")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if !appState.config.isDevOpsConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Azure DevOps is not configured. Set DEVOPS_ORGANIZATION and DEVOPS_PROJECT in your config.")
                    )
                    Spacer()
                }
            } else if isLoadingList {
                VStack {
                    ProgressView("Loading work items...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if filteredWorkItems.isEmpty {
                VStack {
                    ContentUnavailableView.search(text: listSearchText)
                        .padding(.top, 30)
                    Spacer()
                }
            } else {
                Table(filteredWorkItems) {
                    TableColumn("ID") { item in
                        Text(verbatim: "#\(item.id)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Type") { item in
                        WorkItemTypeBadge(type: item.fields?.workItemType)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Title") { item in
                        Text(item.fields?.title ?? "-")
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("State") { item in
                        WorkItemStateBadge(state: item.fields?.state)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Priority") { item in
                        PriorityIndicator(priority: item.fields?.priority)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Assigned To") { item in
                        Text(item.fields?.assignedTo?.displayName ?? "-")
                    }
                    .width(min: 120, ideal: 150)
                }
            }
        }
        .task {
            if !appState.isWorkItemsCacheValid {
                loadWorkItems()
            }
        }
    }
    
    private func loadTasks() {
        Task {
            isLoading = true
            defer { isLoading = false }
            
            do {
                let config = try FleetMateConfig.load()
                let registry = try await createRegistry(config: config)
                
                // Load buckets
                var allBuckets: [String] = []
                for provider in await registry.allProviders {
                    if await provider.isEnabled {
                        let providerBuckets = try await provider.listBuckets()
                        allBuckets.append(contentsOf: providerBuckets.map { $0.name })
                    }
                }
                buckets = Array(Set(allBuckets)).sorted()
                
                // Load tasks
                var filter = TaskFilter()
                filter.includeClosed = true
                filter.limit = 100
                
                if let provider = filterProvider {
                    allTasks = await registry.listTasks(filter: filter, providerIds: [provider])
                } else {
                    allTasks = await registry.listTasks(filter: filter)
                }
            } catch {
                appState.errorMessage = "Failed to load tasks: \(error.localizedDescription)"
            }
        }
    }
    
    private func syncTasks() {
        Task {
            isSyncing = true
            defer { isSyncing = false }
            
            do {
                let config = try FleetMateConfig.load()
                let openTasks = allTasks.filter { $0.state != .closed }
                var messages: [String] = []
                
                // Try Planner sync
                let plannerService = PlannerSyncService(config: config)
                if await plannerService.isEnabled {
                    if try await plannerService.authenticate() {
                        let result = try await plannerService.syncTasks(openTasks)
                        messages.append(result.message)
                    }
                }
                
                // Try Markdown sync
                let mdService = MarkdownSyncService(config: config)
                if await mdService.isEnabled {
                    let result = try await mdService.syncBidirectional(providerTasks: openTasks)
                    messages.append(result.message)
                }
                
                if messages.isEmpty {
                    syncMessage = "No sync destinations configured. Enable Planner or Markdown sync in your config."
                } else {
                    syncMessage = messages.joined(separator: "\n")
                }
                showSyncAlert = true
            } catch {
                syncMessage = "Sync failed: \(error.localizedDescription)"
                showSyncAlert = true
            }
        }
    }
    
    private func selectTask(_ task: UnifiedTask) {
        selectedTask = task
    }

    private func loadWorkItems() {
        guard appState.config.isDevOpsConfigured else { return }
        Task {
            isLoadingList = true
            defer { isLoadingList = false }
            do {
                let items = try await appState.devOpsService.getWorkItems(limit: 100)
                appState.updateWorkItemsCache(items)
            } catch {
                appState.errorMessage = "Failed to load work items: \(error.localizedDescription)"
            }
        }
    }
    
    private func createRegistry(config: FleetMateConfig) async throws -> TaskProviderRegistry {
        let registry = TaskProviderRegistry()
        
        let azdo = AzureDevOpsTaskProvider(config: config)
        let github = GitHubTaskProvider(config: config)
        let gitea = GiteaTaskProvider(config: config)
        
        await registry.registerProvider(azdo)
        await registry.registerProvider(github)
        await registry.registerProvider(gitea)
        
        for provider in await registry.allProviders {
            if await provider.isEnabled {
                _ = try await provider.authenticate()
            }
        }
        
        return registry
    }
}

// MARK: - Kanban Column

struct KanbanColumn: View {
    let title: String
    let color: Color
    let tasks: [UnifiedTask]
    let onSelect: (UnifiedTask) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(title)
                    .fontWeight(.semibold)
                Text("(\(tasks.count))")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            // Tasks
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks, id: \.compositeKey) { task in
                        TaskCard(task: task)
                            .onTapGesture {
                                onSelect(task)
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .frame(minWidth: 250)
    }
}

// MARK: - Task Card

struct TaskCard: View {
    let task: UnifiedTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.title)
                    .fontWeight(.medium)
                    .lineLimit(3)
                
                Spacer()
                
                Text(task.provider)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if let bucket = task.bucket {
                Text(bucket)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !task.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(task.labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }
            
            if !task.assignees.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(task.assignees.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
        .opacity(task.state == .closed ? 0.7 : 1.0)
    }
}

// MARK: - Task Detail Sheet

struct TaskDetailSheet: View {
    let task: UnifiedTask
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(task.provider)#\(task.id)")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
            }
            
            Text(task.title)
                .font(.title2)
                .fontWeight(.bold)
            
            HStack(spacing: 16) {
                Label(task.state.rawValue, systemImage: stateIcon)
                    .foregroundColor(stateColor)
                
                if let bucket = task.bucket {
                    Label(bucket, systemImage: "folder")
                }
                
                if let priority = task.priority {
                    Label("P\(priority)", systemImage: "flag")
                }
            }
            .font(.subheadline)
            
            Divider()
            
            if !task.labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Labels")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        ForEach(task.labels, id: \.self) { label in
                            Text(label)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            
            if !task.assignees.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assignees")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(task.assignees.joined(separator: ", "))
                }
            }
            
            if let description = task.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
            
            if let url = task.externalUrl, let urlObj = URL(string: url) {
                Link(destination: urlObj) {
                    Label("Open in Browser", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
    
    private var stateIcon: String {
        switch task.state {
        case .open: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .closed: return "checkmark.circle.fill"
        }
    }
    
    private var stateColor: Color {
        switch task.state {
        case .open: return .green
        case .inProgress: return .blue
        case .closed: return .gray
        }
    }
}

// MARK: - Extensions

// Note: UnifiedTask already conforms to Identifiable in FleetMateCore

#Preview {
    BoardsView()
        .environmentObject(AppState())
}
