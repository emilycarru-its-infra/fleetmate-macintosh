import SwiftUI
import FleetMateCore

// MARK: - View Mode

enum BoardsViewMode: String, CaseIterable {
    case board = "Board"
    case list = "List"
}

enum GroupByOption: String, CaseIterable {
    case state = "State"
    case column = "Board"
    case areaPath = "Area Path"
    case iteration = "Iteration"
    case type = "Type"
    case priority = "Priority"
    case assignee = "Assigned To"
}

// MARK: - Main View

struct BoardsView: View {
    @EnvironmentObject var appState: AppState

    // View state
    @State private var viewMode: BoardsViewMode = .board
    @State private var allTasks: [UnifiedTask] = []
    @State private var buckets: [String] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var filterProvider: String? = nil
    @State private var filterBucket: String? = nil
    @State private var filterAreaPath: String? = nil
    @State private var filterIteration: String? = nil
    @State private var filterType: String? = nil
    @State private var filterPriority: Int? = nil
    @State private var filterAssignee: String? = nil
    @State private var groupBy: GroupByOption = .column
    @State private var showClosed = false
    @State private var selectedTask: UnifiedTask? = nil
    @State private var isSyncing = false
    @State private var showSyncAlert = false
    @State private var syncMessage = ""
    @State private var syncEnabled = false

    // Detail sidebar toggle
    @State private var showDetailSidebar = true

    // Azure DevOps board selection
    @State private var availableBoards: [Board] = []
    @State private var selectedBoardName: String? = nil
    @State private var boardColumnDefs: [BoardColumnDefinition] = []
    @State private var isLoadingBoards = false
    @State private var boardAllowedTypes: Set<String> = []
    @State private var boardProjectMap: [String: String] = [:]  // board name → project name

    // GitHub Projects info (for New Issue / New Project)
    @State private var currentProjectId: String? = nil
    @State private var currentGhConfig: GitHubProviderConfig? = nil
    @State private var projectStatusField: GitHubProjectField? = nil
    @State private var isLoadingGhInfo = false

    // Create sheets
    @State private var showCreateIssue = false
    @State private var showCreateProject = false
    @State private var showCreateWorkItem = false

    // Computed: can we create GitHub issues? (need owner + repo)
    private var canCreateIssue: Bool {
        guard let c = currentGhConfig else { return false }
        let owner = c.owner ?? c.organization ?? ""
        return !owner.isEmpty
    }

    // Computed: can we create DevOps work items?
    private var canCreateWorkItem: Bool {
        guard let azdo = (try? FleetMateConfig.load())?.tasks?.providers.azdevops else { return false }
        return azdo.enabled
    }

    // Computed: can we create projects? (need at least an owner)
    private var canCreateProject: Bool {
        guard let c = currentGhConfig else { return false }
        let owner = c.organization ?? c.owner ?? ""
        return !owner.isEmpty
    }

    // MARK: - Filtering

    private var filteredTasks: [UnifiedTask] {
        var result = allTasks
        if let provider = filterProvider {
            result = result.filter { $0.provider == provider }
        }
        if let bucket = filterBucket {
            result = result.filter { $0.bucket == bucket }
        }
        if let area = filterAreaPath {
            result = result.filter { $0.metadata["areaPath"] == area }
        }
        if let iter = filterIteration {
            result = result.filter { $0.metadata["iterationPath"] == iter }
        }
        if let type = filterType {
            result = result.filter { $0.metadata["workItemType"] == type }
        }
        if let p = filterPriority {
            result = result.filter { $0.priority == p }
        }
        if let assignee = filterAssignee {
            result = result.filter { $0.assignees.contains(assignee) }
        }
        if !showClosed {
            result = result.filter { $0.state != .closed }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false)
            }
        }
        // When grouping by board column, only show tasks whose type belongs to the selected board
        if groupBy == .column && !boardAllowedTypes.isEmpty {
            result = result.filter { task in
                guard let wiType = task.metadata["workItemType"] else { return true }
                return boardAllowedTypes.contains(wiType)
            }
        }
        return result
    }

    /// Distinct values from loaded tasks for filter pickers
    private var availableAreaPaths: [String] {
        Array(Set(allTasks.compactMap { $0.metadata["areaPath"] })).sorted()
    }
    private var availableIterations: [String] {
        Array(Set(allTasks.compactMap { $0.metadata["iterationPath"] })).sorted()
    }
    private var availableTypes: [String] {
        Array(Set(allTasks.compactMap { $0.metadata["workItemType"] })).sorted()
    }
    private var availableAssignees: [String] {
        Array(Set(allTasks.flatMap { $0.assignees })).sorted()
    }

    private var openTasks: [UnifiedTask]       { filteredTasks.filter { $0.state == .open } }
    private var inProgressTasks: [UnifiedTask] { filteredTasks.filter { $0.state == .inProgress } }
    private var closedTasks: [UnifiedTask]     { filteredTasks.filter { $0.state == .closed } }

    private var hasActiveFilters: Bool {
        filterBucket != nil || filterAreaPath != nil || filterIteration != nil ||
        filterType != nil || filterPriority != nil || filterAssignee != nil
    }

    private func clearAllFilters() {
        filterBucket = nil
        filterAreaPath = nil
        filterIteration = nil
        filterType = nil
        filterPriority = nil
        filterAssignee = nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            unifiedToolbar
            Divider()
            contentArea
        }
        .task {
            if allTasks.isEmpty {
                loadTasks()
                loadGhProjectInfo()
                loadBoards()
            }
        }
        .alert("Sync Complete", isPresented: $showSyncAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(syncMessage)
        }
        .sheet(isPresented: $showCreateIssue) {
            if let ghConfig = currentGhConfig {
                CreateIssueView(
                    config: ghConfig,
                    projectId: currentProjectId,
                    statusField: projectStatusField,
                    onCreated: { loadTasks() }
                )
            }
        }
        .sheet(isPresented: $showCreateWorkItem) {
            CreateWorkItemView(
                service: appState.devOpsService,
                boards: availableBoards,
                boardColumnDefs: boardColumnDefs,
                preselectedBoard: selectedBoardName,
                onCreated: { loadTasks() }
            )
        }
        .sheet(isPresented: $showCreateProject) {
            if let ghConfig = currentGhConfig {
                CreateProjectView(
                    config: ghConfig,
                    onCreated: { loadGhProjectInfo() }
                )
            }
        }
    }

    // MARK: - Unified Single-Row Toolbar

    private var unifiedToolbar: some View {
        HStack(spacing: 8) {
            // Board / List toggle
            Picker("", selection: $viewMode) {
                Text("Board").tag(BoardsViewMode.board)
                Text("List").tag(BoardsViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            Divider().frame(height: 20)

            // Provider filter
            Picker("Provider", selection: $filterProvider) {
                Text("Backend").tag(nil as String?)
                Text("DevOps").tag("azdevops" as String?)
                Text("GitHub").tag("github" as String?)
                Text("Gitea").tag("gitea" as String?)
                Text("TDX").tag("tdx" as String?)
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .labelsHidden()
            .onChange(of: filterProvider) { loadTasks() }
            .onChange(of: appState.devOpsProjectReady) { _, ready in
                if ready { loadTasks(); loadBoards() }
            }

            // Group by
            Picker("Group", selection: $groupBy) {
                ForEach(GroupByOption.allCases, id: \.self) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .onChange(of: groupBy) { _, newValue in
                if newValue == .column && availableBoards.isEmpty {
                    loadBoards()
                }
            }

            // Board selection (shown when grouping by Board Column)
            if groupBy == .column {
                if isLoadingBoards {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20)
                } else if !availableBoards.isEmpty {
                    Picker("Board", selection: $selectedBoardName) {
                        Text("Select board…").tag(nil as String?)
                        ForEach(availableBoards) { board in
                            Text(board.name ?? "Unknown").tag(board.name as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .labelsHidden()
                    .onChange(of: selectedBoardName) { loadBoardColumns() }
                }
            }

            // Show Closed toggle
            Toggle("Closed", isOn: $showClosed)
                .toggleStyle(.checkbox)
                .font(.subheadline)

            // Filters
            if !allTasks.isEmpty {
                Divider().frame(height: 20)

                if !buckets.isEmpty {
                    Picker("Bucket", selection: $filterBucket) {
                        Text("Statuses").tag(nil as String?)
                        ForEach(buckets, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .labelsHidden()
                }

                if !availableAreaPaths.isEmpty {
                    Picker("Area", selection: $filterAreaPath) {
                        Text("Areas").tag(nil as String?)
                        ForEach(availableAreaPaths, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .labelsHidden()
                }

                if !availableIterations.isEmpty {
                    Picker("Iteration", selection: $filterIteration) {
                        Text("Iterations").tag(nil as String?)
                        ForEach(availableIterations, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .labelsHidden()
                }

                if !availableTypes.isEmpty {
                    Picker("Type", selection: $filterType) {
                        Text("Types").tag(nil as String?)
                        ForEach(availableTypes, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .labelsHidden()
                }

                Picker("Priority", selection: $filterPriority) {
                    Text("Priorities").tag(nil as Int?)
                    Text("1 – Critical").tag(1 as Int?)
                    Text("2 – High").tag(2 as Int?)
                    Text("3 – Medium").tag(3 as Int?)
                    Text("4 – Low").tag(4 as Int?)
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .labelsHidden()

                if !availableAssignees.isEmpty {
                    Picker("Assignee", selection: $filterAssignee) {
                        Text("Assignees").tag(nil as String?)
                        ForEach(availableAssignees, id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .labelsHidden()
                }

                if hasActiveFilters {
                    Button(action: clearAllFilters) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                    .controlSize(.small)
                    .help("Clear filters")
                }
            }

            Divider().frame(height: 20)

            // Sync
            if syncEnabled {
                Button(action: syncTasks) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
                .help("Sync tasks to Planner / Markdown")
            }

            // New GitHub Project
            Button(action: { showCreateProject = true }) {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(!canCreateProject)
            .help(canCreateProject ? "New GitHub Project" : "Set organization in GitHub config")

            Spacer()

            devOpsSsoSection

            // Refresh
            Button(action: { loadTasks(); loadGhProjectInfo(); loadBoards() }) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading || isLoadingGhInfo)
            .help("Refresh")
            .keyboardShortcut("r", modifiers: .command)

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Text("\(filteredTasks.count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .trailing)

            // New item (backend chooser) — last on the right
            Menu {
                if canCreateWorkItem {
                    Button(action: { showCreateWorkItem = true }) {
                        Label("DevOps Work Item", systemImage: "building.2")
                    }
                }
                if canCreateIssue {
                    Button(action: { showCreateIssue = true }) {
                        Label("GitHub Issue", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!canCreateIssue && !canCreateWorkItem)
            .help("New item")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - DevOps Auth Status

    @ViewBuilder
    private var devOpsSsoSection: some View {
        if appState.devOpsSsoAuthenticated, let userName = appState.devOpsSsoUserName {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.secondary)
                Text(userName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { appState.signOutDevOpsSso() }) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Sign out of DevOps SSO")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        } else if appState.isDevOpsSsoConfigured {
            Button(action: { appState.triggerDevOpsSsoLogin() }) {
                Label("Sign In", systemImage: "person.badge.key")
            }
            .controlSize(.small)
            .help("Sign in with DevOps SSO")
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch viewMode {
        case .board: boardWithSidebar
        case .list:  listWithSidebar
        }
    }

    // MARK: - Board (Kanban + Inline Sidebar 60/40)

    private var boardWithSidebar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                boardContent
                    .frame(width: (selectedTask != nil && showDetailSidebar) ? geometry.size.width * 0.6 : geometry.size.width)
                if selectedTask != nil {
                    // Sidebar toggle
                    Button(action: { showDetailSidebar.toggle() }) {
                        ZStack {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.08))
                                .frame(width: 12)
                            Image(systemName: showDetailSidebar ? "chevron.compact.right" : "chevron.compact.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(showDetailSidebar ? "Hide detail" : "Show detail")
                    .frame(width: 12)
                    if showDetailSidebar {
                        taskDetailSidebar
                            .frame(width: geometry.size.width * 0.4 - 12)
                    }
                }
            }
        }
    }

    private var boardContent: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView("Loading tasks...")
                        .padding(.top, 60)
                    Spacer()
                }
            } else if allTasks.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "plus.circle",
                        description: Text("Your project has no items yet. Create an issue to get started.")
                    )
                    Spacer()
                }
            } else {
                let columns = boardColumns
                GeometryReader { geo in
                    let columnCount = CGFloat(columns.count)
                    let spacing: CGFloat = 16
                    let totalSpacing = spacing * (columnCount - 1) + 32
                    let columnWidth = max(220, (geo.size.width - totalSpacing) / max(columnCount, 1))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(columns, id: \.title) { col in
                                KanbanColumn(
                                    title: col.title, color: col.color,
                                    tasks: col.tasks, selectedTask: selectedTask,
                                    onSelect: { selectedTask = $0 },
                                    onDrop: { taskKey in handleDrop(taskKey: taskKey, toColumn: col.title) }
                                )
                                .frame(width: columnWidth)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    /// Compute board columns based on group-by selection.
    /// When grouping by Board Column, uses API-provided column definitions for correct ordering and shows empty columns.
    private var boardColumns: [(title: String, color: Color, tasks: [UnifiedTask])] {
        switch groupBy {
        case .state:
            var cols: [(String, Color, [UnifiedTask])] = [
                ("Open", .green, openTasks),
                ("In Progress", .blue, inProgressTasks)
            ]
            if showClosed { cols.append(("Closed", .gray, closedTasks)) }
            return cols
        case .column:
            let grouped = Dictionary(grouping: filteredTasks, by: { $0.metadata["boardColumn"] ?? "No Column" })
            // Use API column definitions for ordering if available
            if !boardColumnDefs.isEmpty {
                return boardColumnDefs.map { colDef in
                    let tasks = grouped[colDef.name] ?? []
                    return (colDef.name, boardColumnColor(colDef), tasks)
                }
            }
            // Fallback: sorted alphabetically
            return grouped.keys.sorted().map { key in (key, .blue, grouped[key]!) }
        case .areaPath:
            let grouped = Dictionary(grouping: filteredTasks, by: { $0.metadata["areaPath"] ?? "No Area" })
            return grouped.keys.sorted().map { key in (key, .purple, grouped[key]!) }
        case .iteration:
            let grouped = Dictionary(grouping: filteredTasks, by: { $0.metadata["iterationPath"] ?? "No Iteration" })
            return grouped.keys.sorted().map { key in (key, .orange, grouped[key]!) }
        case .type:
            let grouped = Dictionary(grouping: filteredTasks, by: { $0.metadata["workItemType"] ?? "Unknown" })
            return grouped.keys.sorted().map { key in (key, .teal, grouped[key]!) }
        case .priority:
            let grouped = Dictionary(grouping: filteredTasks, by: { $0.priority ?? 0 })
            let order = [1, 2, 3, 4, 0]
            let labels = [1: ("Critical", Color.red), 2: ("High", Color.orange), 3: ("Medium", Color.yellow), 4: ("Low", Color.green), 0: ("None", Color.gray)]
            return order.map { key in
                let info = labels[key] ?? ("Priority \(key)", .blue)
                return (info.0, info.1, grouped[key] ?? [])
            }
        case .assignee:
            let grouped = Dictionary(grouping: filteredTasks, by: { $0.assignees.first ?? "Unassigned" })
            // Show "Unassigned" first, then sorted
            var keys = grouped.keys.sorted()
            if let idx = keys.firstIndex(of: "Unassigned") {
                keys.remove(at: idx)
                keys.insert("Unassigned", at: 0)
            }
            return keys.map { key in (key, .indigo, grouped[key]!) }
        }
    }

    private func boardColumnColor(_ col: BoardColumnDefinition) -> Color {
        switch col.columnType?.lowercased() {
        case "incoming": return .green
        case "inprogress", "in progress": return .blue
        case "outgoing": return .purple
        default: return .blue
        }
    }

    // MARK: - List (All Providers + Inline Sidebar 60/40)

    private var listWithSidebar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                listContent
                    .frame(width: (selectedTask != nil && showDetailSidebar) ? geometry.size.width * 0.6 : geometry.size.width)
                if selectedTask != nil {
                    // Sidebar toggle
                    Button(action: { showDetailSidebar.toggle() }) {
                        ZStack {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.08))
                                .frame(width: 12)
                            Image(systemName: showDetailSidebar ? "chevron.compact.right" : "chevron.compact.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(showDetailSidebar ? "Hide detail" : "Show detail")
                    .frame(width: 12)
                    if showDetailSidebar {
                        taskDetailSidebar
                            .frame(width: geometry.size.width * 0.4 - 12)
                    }
                }
            }
        }
    }

    private var listContent: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView("Loading tasks...")
                        .padding(.top, 60)
                    Spacer()
                }
            } else if filteredTasks.isEmpty {
                VStack {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView(
                            "No Tasks",
                            systemImage: "checkmark.circle",
                            description: Text("No tasks match the current filters.")
                        )
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTasks, id: \.compositeKey) { task in
                            TaskListRow(
                                task: task,
                                isSelected: selectedTask?.compositeKey == task.compositeKey
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTask = task }
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inline Task Detail Sidebar

    @ViewBuilder
    private var taskDetailSidebar: some View {
        if let task = selectedTask {
            TaskDetailSidebarView(
                task: task,
                ghConfig: currentGhConfig,
                devOpsService: appState.devOpsService,
                onClose: { selectedTask = nil },
                onSelectWorkItem: { workItemId in
                    // Navigate to the selected work item in-app
                    if let match = allTasks.first(where: { $0.id == String(workItemId) && $0.provider == "azdevops" }) {
                        selectedTask = match
                    } else {
                        // Create a temporary task for navigation
                        let tempTask = UnifiedTask(
                            id: String(workItemId),
                            provider: "azdevops",
                            title: "Loading #\(workItemId)…"
                        )
                        selectedTask = tempTask
                    }
                }
            )
        } else {
            VStack {
                Spacer()
                Image(systemName: "square.text.square")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("No Task Selected")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Load Tasks (all providers via registry)

    private func loadTasks() {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                dbg.info("BoardsView.loadTasks starting", category: "boards")
                let config = try FleetMateConfig.load()

                // Check if sync destinations are configured
                syncEnabled = (config.tasks?.planner != nil) || (config.tasks?.markdown != nil)

                let registry = await createRegistry(config: config)

                let bucketsByProvider = await registry.listAllBuckets()
                let allBuckets = bucketsByProvider.values.flatMap { $0.map { $0.name } }
                buckets = Array(Set(allBuckets)).sorted()
                dbg.info("BoardsView: \(buckets.count) buckets from \(bucketsByProvider.count) providers", category: "boards")

                var filter = TaskFilter()
                filter.includeClosed = true
                filter.limit = 100

                if let provider = filterProvider {
                    dbg.info("BoardsView: fetching tasks from provider '\(provider)'", category: "boards")
                    allTasks = await registry.listTasks(filter: filter, providerIds: [provider])
                } else {
                    dbg.info("BoardsView: fetching tasks from ALL providers", category: "boards")
                    allTasks = await registry.listTasks(filter: filter)
                }
                dbg.info("BoardsView: loaded \(allTasks.count) total tasks", category: "boards")
                for (provider, count) in Dictionary(grouping: allTasks, by: \.provider).mapValues(\.count) {
                    dbg.info("  provider '\(provider)': \(count) tasks", category: "boards")
                }
            } catch {
                dbg.error("BoardsView.loadTasks FAILED: \(error)", category: "boards")
                appState.errorMessage = "Failed to load tasks: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Drag & Drop Handler

    /// Handle dropping a task card onto a column. Updates the field that corresponds to the current groupBy.
    private func handleDrop(taskKey: String, toColumn: String) {
        guard let task = allTasks.first(where: { $0.compositeKey == taskKey }) else { return }

        // Only handle azdevops tasks for field updates
        guard task.provider == "azdevops", let id = Int(task.id) else { return }

        Task {
            do {
                var request: UpdateWorkItemRequest?

                switch groupBy {
                case .column:
                    // Look up the target state from the board column's stateMappings
                    guard let colDef = boardColumnDefs.first(where: { $0.name == toColumn }),
                          let wiType = task.metadata["workItemType"],
                          let targetState = colDef.stateMappings?[wiType] else {
                        dbg.error("Cannot find state mapping for column '\(toColumn)' and type '\(task.metadata["workItemType"] ?? "?")'", category: "boards")
                        return
                    }
                    _ = try await appState.devOpsService.moveWorkItemToBoardColumn(id: id, targetState: targetState)
                    // Update local state
                    if let idx = allTasks.firstIndex(where: { $0.compositeKey == taskKey }) {
                        allTasks[idx].metadata["boardColumn"] = toColumn
                    }
                    return
                case .state:
                    let newState: String
                    switch toColumn {
                    case "Open": newState = "New"
                    case "In Progress": newState = "Active"
                    case "Closed": newState = "Closed"
                    default: return
                    }
                    request = UpdateWorkItemRequest(state: newState)
                case .priority:
                    let priorityMap = ["Critical": 1, "High": 2, "Medium": 3, "Low": 4, "None": 0]
                    guard let p = priorityMap[toColumn], p > 0 else { return }
                    request = UpdateWorkItemRequest(priority: p)
                case .assignee:
                    let assignee = toColumn == "Unassigned" ? "" : toColumn
                    request = UpdateWorkItemRequest(assignedTo: assignee)
                case .areaPath:
                    request = UpdateWorkItemRequest(areaPath: toColumn)
                case .iteration:
                    request = UpdateWorkItemRequest(iterationPath: toColumn)
                case .type:
                    request = UpdateWorkItemRequest(workItemType: toColumn)
                }

                if let request = request {
                    _ = try await appState.devOpsService.updateWorkItem(id: id, request: request)
                }

                // Refresh local task data
                if let updated = try await appState.devOpsService.getWorkItem(id: id) {
                    if let idx = allTasks.firstIndex(where: { $0.compositeKey == taskKey }) {
                        let fields = updated.fields
                        allTasks[idx].metadata["boardColumn"] = fields?.boardColumn ?? ""
                        allTasks[idx].metadata["areaPath"] = fields?.areaPath ?? ""
                        allTasks[idx].metadata["iterationPath"] = fields?.iterationPath ?? ""
                        allTasks[idx].metadata["workItemType"] = fields?.workItemType ?? ""
                        allTasks[idx].priority = fields?.priority
                        if let assignee = fields?.assignedTo?.displayName ?? fields?.assignedTo?.uniqueName {
                            allTasks[idx].assignees = [assignee]
                        } else {
                            allTasks[idx].assignees = []
                        }
                        // Update state
                        let stateStr = fields?.state ?? "New"
                        switch stateStr.lowercased() {
                        case "new", "to do", "proposed":
                            allTasks[idx].state = .open
                        case "active", "in progress", "doing", "committed":
                            allTasks[idx].state = .inProgress
                        default:
                            allTasks[idx].state = .closed
                        }
                    }
                }
            } catch {
                dbg.error("Drag-drop update failed: \(error)", category: "boards")
                appState.errorMessage = "Failed to move item: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Load GitHub Project Info (for New Issue / New Project context)

    private func loadGhProjectInfo() {
        Task {
            isLoadingGhInfo = true
            defer { isLoadingGhInfo = false }
            do {
                let config = try FleetMateConfig.load()
                guard var ghConfig = config.tasks?.providers.github, ghConfig.enabled else { return }

                let service = GitHubProjectsService(config: ghConfig)
                guard try await service.authenticate() else { return }

                let scope: ProjectScope
                switch ghConfig.projectScope.lowercased() {
                case "user": scope = .user
                case "repository", "repo": scope = .repository
                default: scope = .organization
                }
                let owner = ghConfig.organization ?? ghConfig.owner ?? ""

                let projectId: String?
                if let num = ghConfig.projectNumber {
                    projectId = try await service.getProject(
                        scope: scope, owner: owner, projectNumber: num, repo: ghConfig.repo)?.id
                } else {
                    projectId = try await service.listProjects(
                        scope: scope, owner: owner, repo: ghConfig.repo, limit: 1).first?.id
                }
                currentProjectId = projectId
                if let pid = projectId {
                    projectStatusField = try await service.getStatusField(projectId: pid)

                    // Auto-detect owner/repo from project items when not set in config
                    if ghConfig.repo == nil || ghConfig.owner == nil {
                        let items = try await service.listProjectItems(projectId: pid, limit: 10)
                        if let repoPath = items.compactMap({ $0.content?.repository }).first {
                            let parts = repoPath.split(separator: "/")
                            if parts.count == 2 {
                                if ghConfig.owner == nil { ghConfig.owner = String(parts[0]) }
                                if ghConfig.repo == nil { ghConfig.repo = String(parts[1]) }
                            }
                        }
                    }
                }
                currentGhConfig = ghConfig
            } catch {
                print("GitHub project info (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sync

    private func syncTasks() {
        Task {
            isSyncing = true
            defer { isSyncing = false }
            do {
                let config = try FleetMateConfig.load()
                let openTasks = allTasks.filter { $0.state != .closed }
                var messages: [String] = []

                let plannerService = PlannerSyncService(config: config)
                if await plannerService.isEnabled {
                    if try await plannerService.authenticate() {
                        let result = try await plannerService.syncTasks(openTasks)
                        messages.append(result.message)
                    }
                }

                let mdService = MarkdownSyncService(config: config)
                if await mdService.isEnabled {
                    let result = try await mdService.syncBidirectional(providerTasks: openTasks)
                    messages.append(result.message)
                }

                syncMessage = messages.isEmpty
                    ? "No sync destinations configured. Enable Planner or Markdown sync in your config."
                    : messages.joined(separator: "\n")
                showSyncAlert = true
            } catch {
                syncMessage = "Sync failed: \(error.localizedDescription)"
                showSyncAlert = true
            }
        }
    }

    // MARK: - Load Azure DevOps Boards

    private func loadBoards() {
        Task {
            isLoadingBoards = true
            defer { isLoadingBoards = false }
            do {
                // Load boards from all DevOps projects for full backlog level coverage
                let projects = try await appState.devOpsService.listProjects()
                var allBoards: [Board] = []
                var projectMap: [String: String] = [:]
                for project in projects {
                    do {
                        let boards = try await appState.devOpsService.getBoards(project: project.name)
                        for board in boards {
                            if let name = board.name {
                                projectMap[name] = project.name
                            }
                        }
                        allBoards.append(contentsOf: boards)
                    } catch {
                        dbg.debug("Failed to load boards for project '\(project.name ?? "?")': \(error)", category: "boards")
                    }
                }
                // Deduplicate by name (boards across projects often share names like "Stories", "Bugs")
                var seen = Set<String>()
                var unique: [Board] = []
                for board in allBoards {
                    guard let name = board.name, !seen.contains(name) else { continue }
                    seen.insert(name)
                    unique.append(board)
                }
                availableBoards = unique
                boardProjectMap = projectMap
                dbg.info("Loaded \(unique.count) unique boards from \(projects.count) projects: \(unique.compactMap(\.name).joined(separator: ", "))", category: "boards")
                // Auto-select the first board if none selected
                if selectedBoardName == nil, let first = unique.first?.name {
                    selectedBoardName = first
                    loadBoardColumns()
                }
            } catch {
                // Fallback: try just the default project
                do {
                    let boards = try await appState.devOpsService.getBoards()
                    availableBoards = boards
                    if selectedBoardName == nil, let first = boards.first?.name {
                        selectedBoardName = first
                        loadBoardColumns()
                    }
                } catch {
                    dbg.debug("Failed to load boards: \(error)", category: "boards")
                }
            }
        }
    }

    private func loadBoardColumns() {
        guard let boardName = selectedBoardName else {
            boardColumnDefs = []
            return
        }
        let project = boardProjectMap[boardName]
        Task {
            do {
                boardColumnDefs = try await appState.devOpsService.getBoardColumns(boardName: boardName, project: project)
                // Extract allowed work item types from column state mappings
                var types = Set<String>()
                for col in boardColumnDefs {
                    if let mappings = col.stateMappings {
                        types.formUnion(mappings.keys)
                    }
                }
                boardAllowedTypes = types
                dbg.info("Loaded \(boardColumnDefs.count) columns for board '\(boardName)': \(boardColumnDefs.map(\.name).joined(separator: ", ")), types: \(types.sorted().joined(separator: ", "))", category: "boards")
            } catch {
                dbg.debug("Failed to load board columns: \(error)", category: "boards")
                boardColumnDefs = []
                boardAllowedTypes = []
            }
        }
    }

    // MARK: - Registry Creation

    private func createRegistry(config: FleetMateConfig) async -> TaskProviderRegistry {
        dbg.info("createRegistry starting — devOpsService.hasValidToken=\(appState.devOpsService.hasValidToken) org=\(config.devopsOrganization ?? "nil") project=\(config.devopsProject ?? "nil")", category: "boards")
        let registry = TaskProviderRegistry()
        let azdo   = AzureDevOpsTaskProvider(service: appState.devOpsService, config: config)
        let github = GitHubProjectsTaskProvider(config: config.tasks?.providers.github ?? GitHubProviderConfig())
        let gitea  = GiteaTaskProvider(config: config)

        await registry.registerProvider(azdo)
        await registry.registerProvider(github)
        await registry.registerProvider(gitea)

        dbg.info("Registered providers: azdo.enabled=\(await azdo.isEnabled) github.enabled=\(await github.isEnabled) gitea.enabled=\(await gitea.isEnabled)", category: "boards")

        // Use the registry's built-in authenticateAll() which isolates per-provider failures
        let authResults = await registry.authenticateAll()
        for (id, success) in authResults {
            dbg.info("Provider \(id) auth: \(success ? "OK" : "FAILED")", category: "boards")
        }
        return registry
    }
}

// MARK: - Task List Row

struct TaskListRow: View {
    let task: UnifiedTask
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    if let p = task.priority {
                        PriorityIndicator(priority: p)
                    }
                    Text(task.state.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor.opacity(0.15))
                        .foregroundColor(stateColor)
                        .cornerRadius(4)
                }
                HStack(spacing: 8) {
                    if let wiType = task.metadata["workItemType"] {
                        Text(wiType)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(3)
                    }
                    if let area = task.metadata["areaPath"] {
                        Text(area)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if let bucket = task.bucket {
                        Text(bucket)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    ForEach(task.labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                    if !task.assignees.isEmpty {
                        Spacer()
                        HStack(spacing: 2) {
                            Image(systemName: "person")
                                .font(.caption2)
                            Text(task.assignees.prefix(2).joined(separator: ", "))
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private var stateColor: Color {
        switch task.state {
        case .open: return .green
        case .inProgress: return .blue
        case .closed: return .gray
        }
    }
}

// MARK: - Kanban Column (with drag-and-drop)

struct KanbanColumn: View {
    let title: String
    let color: Color
    let tasks: [UnifiedTask]
    let selectedTask: UnifiedTask?
    let onSelect: (UnifiedTask) -> Void
    var onDrop: ((String) -> Void)? = nil

    @State private var isTargeted = false

    private var groupedByProvider: [(provider: String, tasks: [UnifiedTask])] {
        let providers = Array(Set(tasks.map(\.provider))).sorted()
        return providers.map { p in (p, tasks.filter { $0.provider == p }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(title).fontWeight(.semibold)
                Text("(\(tasks.count))").foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if groupedByProvider.count > 1 {
                        // Multiple providers — show section headers
                        ForEach(groupedByProvider, id: \.provider) { group in
                            HStack {
                                Text(providerDisplayName(group.provider))
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .tracking(0.5)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                            ForEach(group.tasks, id: \.compositeKey) { task in
                                TaskCard(
                                    task: task,
                                    isSelected: selectedTask?.compositeKey == task.compositeKey
                                )
                                .draggable(task.compositeKey)
                                .onTapGesture { onSelect(task) }
                            }
                        }
                    } else {
                        // Single provider — no section header needed
                        ForEach(tasks, id: \.compositeKey) { task in
                            TaskCard(
                                task: task,
                                isSelected: selectedTask?.compositeKey == task.compositeKey
                            )
                            .draggable(task.compositeKey)
                            .onTapGesture { onSelect(task) }
                        }
                    }

                    // Empty column drop zone
                    if tasks.isEmpty {
                        Text("Drop items here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(isTargeted ? color.opacity(0.15) : Color.secondary.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? color : Color.clear, lineWidth: 2)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let taskKey = items.first else { return false }
            onDrop?(taskKey)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "github": return "GitHub"
        case "azdevops":   return "DevOps"
        case "gitea":  return "Gitea"
        case "tdx":    return "TDX"
        default:       return provider.capitalized
        }
    }
}

// MARK: - Task Card (with selection highlight)

struct TaskCard: View {
    let task: UnifiedTask
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.title)
                    .fontWeight(.medium)
                    .lineLimit(3)
                Spacer()
                if let p = task.priority {
                    PriorityIndicator(priority: p)
                }
            }
            // Type + provider
            HStack(spacing: 6) {
                if let wiType = task.metadata["workItemType"] {
                    Text(wiType)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(3)
                }
                Text(task.provider)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // Area path
            if let area = task.metadata["areaPath"] {
                Text(area)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            // Iteration
            if let iter = task.metadata["iterationPath"] ?? task.bucket {
                Text(iter)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(task.state == .closed ? 0.7 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    BoardsView()
        .environmentObject(AppState())
}
