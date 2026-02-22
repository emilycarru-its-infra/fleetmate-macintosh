import SwiftUI
import FleetMateCore

// MARK: - View Mode

enum BoardsViewMode: String, CaseIterable {
    case board = "Board"
    case list = "List"
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
    @State private var showClosed = false
    @State private var selectedTask: UnifiedTask? = nil
    @State private var isSyncing = false
    @State private var showSyncAlert = false
    @State private var syncMessage = ""
    @State private var syncEnabled = false

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
        return result
    }

    private var openTasks: [UnifiedTask]       { filteredTasks.filter { $0.state == .open } }
    private var inProgressTasks: [UnifiedTask] { filteredTasks.filter { $0.state == .inProgress } }
    private var closedTasks: [UnifiedTask]     { filteredTasks.filter { $0.state == .closed } }

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
            CreateWorkItemView(onCreated: { loadTasks() })
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
            .onChange(of: appState.devOpsProjectReady) { ready in
                if ready { loadTasks() }
            }

            // Bucket filter (only when buckets exist)
            if !buckets.isEmpty {
                Picker("Bucket", selection: $filterBucket) {
                    Text("Statuses").tag(nil as String?)
                    ForEach(buckets, id: \.self) { Text($0).tag($0 as String?) }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .labelsHidden()
            }

            // Show Closed toggle
            Toggle("Closed", isOn: $showClosed)
                .toggleStyle(.checkbox)
                .font(.subheadline)

            Divider().frame(height: 20)

            // Sync
            if syncEnabled {
                Button(action: syncTasks) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
                .help("Sync tasks to Planner / Markdown")
            }

            // New item (backend chooser)
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

            // New GitHub Project
            Button(action: { showCreateProject = true }) {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(!canCreateProject)
            .help(canCreateProject ? "New GitHub Project" : "Set organization in GitHub config")

            Spacer()

            // Refresh — top right
            Button(action: { loadTasks(); loadGhProjectInfo() }) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading || isLoadingGhInfo)
            .help("Refresh")
            .keyboardShortcut("r", modifiers: .command)

            // Search field — far right
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
                    .frame(width: selectedTask != nil ? geometry.size.width * 0.6 : geometry.size.width)
                if selectedTask != nil {
                    Divider()
                    taskDetailSidebar
                        .frame(width: geometry.size.width * 0.4)
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
                GeometryReader { geo in
                    let columnCount = CGFloat(showClosed ? 3 : 2)
                    let spacing: CGFloat = 16
                    let totalSpacing = spacing * (columnCount - 1) + 32 // 32 = padding
                    let columnWidth = max(220, (geo.size.width - totalSpacing) / columnCount)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: spacing) {
                            KanbanColumn(
                                title: "Open", color: .green,
                                tasks: openTasks, selectedTask: selectedTask,
                                onSelect: { selectedTask = $0 }
                            )
                            .frame(width: columnWidth)
                            KanbanColumn(
                                title: "In Progress", color: .blue,
                                tasks: inProgressTasks, selectedTask: selectedTask,
                                onSelect: { selectedTask = $0 }
                            )
                            .frame(width: columnWidth)
                            if showClosed {
                                KanbanColumn(
                                    title: "Closed", color: .gray,
                                    tasks: closedTasks, selectedTask: selectedTask,
                                    onSelect: { selectedTask = $0 }
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

    // MARK: - List (All Providers + Inline Sidebar 60/40)

    private var listWithSidebar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                listContent
                    .frame(width: selectedTask != nil ? geometry.size.width * 0.6 : geometry.size.width)
                if selectedTask != nil {
                    Divider()
                    taskDetailSidebar
                        .frame(width: geometry.size.width * 0.4)
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
                onClose: { selectedTask = nil }
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
            // Provider icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(providerColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: providerSystemImage)
                    .font(.system(size: 16))
                    .foregroundColor(providerColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(task.state.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor.opacity(0.15))
                        .foregroundColor(stateColor)
                        .cornerRadius(4)
                }
                HStack(spacing: 8) {
                    if let bucket = task.bucket {
                        Text(bucket)
                            .font(.caption)
                            .foregroundColor(.secondary)
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

    private var providerColor: Color {
        switch task.provider {
        case "github": return .purple
        case "azdevops":   return .blue
        case "gitea":  return .green
        case "tdx":    return .orange
        default:       return .secondary
        }
    }

    private var providerSystemImage: String {
        switch task.provider {
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "azdevops":   return "building.2"
        case "gitea":  return "arrow.triangle.branch"
        case "tdx":    return "ticket"
        default:       return "square.and.pencil"
        }
    }
}

// MARK: - Kanban Column (with provider grouping within each column)

struct KanbanColumn: View {
    let title: String
    let color: Color
    let tasks: [UnifiedTask]
    let selectedTask: UnifiedTask?
    let onSelect: (UnifiedTask) -> Void

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
                            .onTapGesture { onSelect(task) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
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
