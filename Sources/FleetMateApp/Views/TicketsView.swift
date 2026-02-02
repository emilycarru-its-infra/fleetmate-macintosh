import SwiftUI
import FleetMateCore

enum TicketSortField: String, CaseIterable {
    case modified = "Modified"
    case created = "Created"
    case title = "Title"
    case status = "Status"
    case priority = "Priority"
    case requestor = "Requestor"
    case responsible = "Responsible"
}

enum TicketViewMode: String, CaseIterable {
    case list = "List"
    case board = "Board"
}

struct TicketsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sortField: TicketSortField = .modified  // Default to modified
    @State private var sortAscending = false  // Default descending (newest first)
    @State private var viewMode: TicketViewMode = .list  // List or Board view
    
    // Filters
    @State private var selectedStatusFilter: String = "All"
    @State private var selectedResponsibleFilter: String = "All"
    @State private var selectedGroupFilter: String = "All"
    @State private var hideClosed = true  // Default to hiding closed tickets
    @State private var availableStatuses: [String] = ["All"]
    @State private var availableResponsible: [String] = ["All"]
    @State private var availableGroups: [String] = ["All"]
    
    // Selection and detail view
    @State private var selectedTicketId: Int?
    @State private var selectedTicket: TdxTicket?
    @State private var ticketFeed: [TdxFeedEntry] = []
    @State private var isLoadingDetail = false
    @State private var showDetailPanel = true
    
    // Actions
    @State private var isPerformingAction = false
    @State private var actionMessage: String?
    @State private var newComment = ""
    @State private var isPrivateComment = false
    @State private var notifyRecipients: Set<String> = []  // Selected notify recipients
    
    // Activity filter
    @State private var showOnlyComments = false  // Default to showing all activity
    
    // Description editing
    @State private var isEditingDescription = false
    @State private var editedDescription = ""
    
    // Reference data for dropdowns
    @State private var allStatuses: [Int: String] = [:]
    @State private var allPriorities: [Int: String] = [:]
    
    // Use cached tickets from appState
    var tickets: [TdxTicket] { appState.cachedTickets }
    
    // Available notify options for current ticket
    var notifyOptions: [(id: String, label: String)] {
        guard let ticket = selectedTicket else { return [] }
        var options: [(id: String, label: String)] = []
        
        if let groupName = ticket.responsibleGroupName, let groupId = ticket.responsibleGroupId {
            options.append((id: "group:\(groupId)", label: "\(groupName) (Responsible Group)"))
        }
        if let name = ticket.requestorName, let uid = ticket.requestorUid {
            options.append((id: "user:\(uid)", label: "\(name) (Requestor)"))
        }
        if let name = ticket.responsibleFullName, let uid = ticket.responsibleUid {
            options.append((id: "user:\(uid)", label: "\(name) (Responsible)"))
        }
        return options
    }

    var filteredTickets: [TdxTicket] {
        var result = tickets
        
        // Hide closed if toggle is on
        if hideClosed {
            result = result.filter { $0.statusName?.lowercased() != "closed" }
        }
        
        // Apply status filter
        if selectedStatusFilter != "All" {
            result = result.filter { $0.statusName == selectedStatusFilter }
        }
        
        // Apply responsible filter
        if selectedResponsibleFilter != "All" {
            result = result.filter { $0.responsibleFullName == selectedResponsibleFilter }
        }
        
        // Apply group filter
        if selectedGroupFilter != "All" {
            result = result.filter { $0.responsibleGroupName == selectedGroupFilter }
        }
        
        // Apply search text
        if !searchText.isEmpty {
            result = result.filter {
                ($0.title?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.requestorName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                "\($0.id ?? 0)".contains(searchText)
            }
        }
        
        return result.sorted { a, b in
            switch sortField {
            case .modified:
                let aVal = a.modifiedDate ?? ""
                let bVal = b.modifiedDate ?? ""
                return sortAscending ? aVal < bVal : aVal > bVal
            case .created:
                let aVal = a.createdDate ?? ""
                let bVal = b.createdDate ?? ""
                return sortAscending ? aVal < bVal : aVal > bVal
            case .title:
                let aVal = a.title ?? ""
                let bVal = b.title ?? ""
                return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
            case .status:
                let aVal = a.statusName ?? ""
                let bVal = b.statusName ?? ""
                return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
            case .priority:
                let aVal = a.priorityName ?? ""
                let bVal = b.priorityName ?? ""
                return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
            case .requestor:
                let aVal = a.requestorName ?? ""
                let bVal = b.requestorName ?? ""
                return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
            case .responsible:
                let aVal = a.responsibleFullName ?? ""
                let bVal = b.responsibleFullName ?? ""
                return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
            }
        }
    }

    // Filtered feed (comments only vs all activity)
    var filteredFeed: [TdxFeedEntry] {
        var result = ticketFeed.filter { $0.createdFullName != "System" }
        if showOnlyComments {
            // itemType 0 = Comment, nil = also treat as comment
            result = result.filter { $0.itemType == nil || $0.itemType == 0 }
        }
        return result
    }

    var body: some View {
        HSplitView {
            // Main content (list or board)
            VStack(spacing: 0) {
                // Unified header for both views
                ticketHeader
                
                // View content based on mode
                if viewMode == .list {
                    ticketListContent
                } else {
                    TicketBoardView(
                        tickets: filteredTickets,
                        statuses: allStatuses,
                        onUpdateStatus: { ticketId, newStatusId in
                            updateTicketStatusById(ticketId: ticketId, newStatusId: newStatusId)
                        },
                        onSelectTicket: { ticket in
                            selectedTicketId = ticket.id
                            showDetailPanel = true
                            if let id = ticket.id {
                                loadTicketDetail(id: id)
                            }
                        }
                    )
                }
            }
            .frame(minWidth: 400)
            
            // Detail Panel
            if showDetailPanel {
                TicketDetailPanel(
                        ticket: selectedTicket,
                        feed: filteredFeed,
                        notifyOptions: notifyOptions,
                        isLoading: isLoadingDetail,
                        isPerformingAction: $isPerformingAction,
                        actionMessage: $actionMessage,
                        newComment: $newComment,
                        isPrivateComment: $isPrivateComment,
                        notifyRecipients: $notifyRecipients,
                        showOnlyComments: $showOnlyComments,
                        isEditingDescription: $isEditingDescription,
                        editedDescription: $editedDescription,
                        allStatuses: allStatuses,
                        allPriorities: allPriorities,
                        onAddComment: addComment,
                        onOpenInWeb: openTicketInWeb,
                        onUpdateStatus: updateTicketStatus,
                        onUpdatePriority: updateTicketPriority,
                        onUpdateDescription: updateTicketDescription,
                        onRefresh: { if let id = selectedTicketId { loadTicketDetail(id: id) } },
                        onClose: { showDetailPanel = false }
                    )
                    .frame(minWidth: 300)
                }
            }
        .task {
            if !appState.isTicketsCacheValid {
                loadTickets()
            } else {
                updateFilterOptions()
            }
            // Load reference data
            await loadReferenceData()
        }
    }
    
    private var ticketHeader: some View {
        VStack(spacing: 0) {
            // Header row
            HStack {
                VStack(alignment: .leading) {
                    Text("Tickets")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(String(format: "%d of %d tickets", filteredTickets.count, tickets.count))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(TicketViewMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode == .list ? "list.bullet" : "square.grid.3x3")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                
                if viewMode == .list {
                    // Sort controls (only for list view)
                    Picker("Sort by", selection: $sortField) {
                        ForEach(TicketSortField.allCases, id: \.self) { field in
                            Text(field.rawValue).tag(field)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    
                    Button(action: { sortAscending.toggle() }) {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    }
                    .help(sortAscending ? "Ascending" : "Descending")
                }
                
                Button(action: { showDetailPanel.toggle() }) {
                    Label("Details", systemImage: showDetailPanel ? "sidebar.trailing" : "sidebar.trailing")
                }
                .help("Toggle detail panel")
                
                Button(action: loadTickets) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Filters row
            HStack(spacing: 12) {
                Toggle("Hide Closed", isOn: $hideClosed)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                    .layoutPriority(1)
                
                Divider()
                    .frame(height: 20)
                
                // Hide status filter in board view (status = columns)
                if viewMode == .list {
                    Picker("Status", selection: $selectedStatusFilter) {
                        ForEach(availableStatuses, id: \.self) { status in
                            Text(status).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                
                Picker("Group", selection: $selectedGroupFilter) {
                    ForEach(availableGroups, id: \.self) { group in
                        Text(group).tag(group)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                
                Picker("Responsible", selection: $selectedResponsibleFilter) {
                    ForEach(availableResponsible, id: \.self) { person in
                        Text(person).tag(person)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                
                Spacer()
                
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 100, maxWidth: 180)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
    
    private var ticketListContent: some View {
        Group {
            if !appState.config.isTdxConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("TeamDynamix is not configured. Set TDX_BASE_URL and TDX_TICKETING_APP_ID in your config.")
                    )
                    Spacer()
                }
            } else if isLoading {
                VStack {
                    ProgressView("Loading tickets...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if filteredTickets.isEmpty {
                VStack {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 30)
                    Spacer()
                }
            } else {
                List(filteredTickets, selection: $selectedTicketId) { ticket in
                    TicketRow(ticket: ticket)
                        .tag(ticket.id)
                        .onTapGesture(count: 2) {
                            selectedTicketId = ticket.id
                            showDetailPanel = true
                            if let id = ticket.id {
                                loadTicketDetail(id: id)
                            }
                        }
                }
                .onChange(of: selectedTicketId) { _, newId in
                    actionMessage = nil
                    if let id = newId {
                        loadTicketDetail(id: id)
                    }
                }
            }
        }
    }
    
    private func openTicketInWeb() {
        guard let ticket = selectedTicket,
              let ticketId = ticket.id,
              let baseUrl = appState.config.tdxBaseUrl else { return }
        
        // Build correct URL format: https://servicedesk.example.com/TDNext/Apps/115/Tickets/TicketDet?TicketID=123
        // Base URL is like "https://servicedesk.example.com/TDWebApi"
        let baseDomain = baseUrl.replacingOccurrences(of: "/TDWebApi", with: "")
        let appId = appState.config.tdxTicketingAppId ?? appState.config.tdxAppId ?? 115
        let webUrl = "\(baseDomain)/TDNext/Apps/\(appId)/Tickets/TicketDet?TicketID=\(ticketId)"
        
        if let url = URL(string: webUrl) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func loadReferenceData() async {
        do {
            allStatuses = try await appState.tdxService.getStatuses()
            allPriorities = try await appState.tdxService.getPriorities()
        } catch {
            print("Failed to load reference data: \(error)")
        }
    }
    
    private func updateTicketStatus(newStatusId: Int) {
        guard let ticketId = selectedTicketId else { return }
        
        Task {
            isPerformingAction = true
            actionMessage = "Updating status..."
            defer { isPerformingAction = false }
            
            do {
                if let updated = try await appState.tdxService.updateTicket(id: ticketId, updates: ["StatusID": newStatusId]) {
                    selectedTicket = updated
                    actionMessage = "Status updated"
                    // Refresh ticket list
                    loadTickets()
                } else {
                    actionMessage = "Failed to update status"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    private func updateTicketPriority(newPriorityId: Int) {
        guard let ticketId = selectedTicketId else { return }
        
        Task {
            isPerformingAction = true
            actionMessage = "Updating priority..."
            defer { isPerformingAction = false }
            
            do {
                if let updated = try await appState.tdxService.updateTicket(id: ticketId, updates: ["PriorityID": newPriorityId]) {
                    selectedTicket = updated
                    actionMessage = "Priority updated"
                    loadTickets()
                } else {
                    actionMessage = "Failed to update priority"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    private func updateTicketDescription(_ newDescription: String) {
        guard let ticketId = selectedTicketId else { return }
        
        Task {
            isPerformingAction = true
            actionMessage = "Updating description..."
            defer { isPerformingAction = false }
            
            do {
                if let updated = try await appState.tdxService.updateTicket(id: ticketId, updates: ["Description": newDescription]) {
                    selectedTicket = updated
                    actionMessage = "Description updated"
                    loadTickets()
                } else {
                    actionMessage = "Failed to update description"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    /// Update ticket status by ticket ID (for Kanban board drag-and-drop)
    private func updateTicketStatusById(ticketId: Int, newStatusId: Int) {
        Task {
            isPerformingAction = true
            actionMessage = "Updating status..."
            defer { isPerformingAction = false }
            
            do {
                if let updated = try await appState.tdxService.updateTicket(id: ticketId, updates: ["StatusID": newStatusId]) {
                    // If this is the selected ticket, update it
                    if ticketId == selectedTicketId {
                        selectedTicket = updated
                    }
                    actionMessage = "Status updated"
                    // Refresh ticket list
                    loadTickets()
                } else {
                    actionMessage = "Failed to update status"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func loadTickets() {
        guard appState.config.isTdxConfigured else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                // Build search request with group filter if configured
                var searchRequest = TicketSearchRequest(maxResults: 500)
                if let groupId = appState.config.tdxResponsibleGroupId {
                    searchRequest.responsibleGroupIds = [groupId]
                }
                
                let fetchedTickets = try await appState.tdxService.searchTickets(search: searchRequest, maxResults: 500)
                appState.updateTicketsCache(fetchedTickets)
                updateFilterOptions()
            } catch {
                print("Failed to load tickets: \(error)")
            }
        }
    }
    
    private func updateFilterOptions() {
        // Extract unique values for filter dropdowns
        var statuses = Set<String>()
        var responsible = Set<String>()
        var groups = Set<String>()
        
        for ticket in tickets {
            if let status = ticket.statusName, !status.isEmpty {
                statuses.insert(status)
            }
            if let person = ticket.responsibleFullName, !person.isEmpty {
                responsible.insert(person)
            }
            if let group = ticket.responsibleGroupName, !group.isEmpty {
                groups.insert(group)
            }
        }
        
        availableStatuses = ["All"] + statuses.sorted()
        availableResponsible = ["All"] + responsible.sorted()
        availableGroups = ["All"] + groups.sorted()
    }
    
    private func loadTicketDetail(id: Int) {
        Task {
            isLoadingDetail = true
            defer { isLoadingDetail = false }
            
            do {
                // Get ticket details
                if let ticket = try await appState.tdxService.getTicket(id: id) {
                    selectedTicket = ticket
                }
                
                // Get ticket feed/comments
                ticketFeed = try await appState.tdxService.getTicketFeed(ticketId: id)
            } catch {
                print("Failed to load ticket detail: \(error)")
            }
        }
    }
    
    private func addComment() {
        guard let ticketId = selectedTicketId, !newComment.isEmpty else { return }
        
        Task {
            isPerformingAction = true
            actionMessage = "Adding comment..."
            defer { isPerformingAction = false }
            
            do {
                let success = try await appState.tdxService.addComment(
                    ticketId: ticketId,
                    comment: newComment,
                    isPrivate: isPrivateComment
                )
                
                if success {
                    actionMessage = "Comment added successfully"
                    newComment = ""
                    // Refresh feed
                    ticketFeed = try await appState.tdxService.getTicketFeed(ticketId: ticketId)
                } else {
                    actionMessage = "Failed to add comment"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Ticket Row

struct TicketRow: View {
    let ticket: TdxTicket
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ticket.title ?? "Untitled")
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                TicketStatusBadge(statusName: ticket.statusName)
            }
            
            HStack(spacing: 12) {
                Label(ticket.requestorName ?? "-", systemImage: "person")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let group = ticket.responsibleGroupName {
                    Label(group, systemImage: "person.2")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                if let responsible = ticket.responsibleFullName {
                    Label(responsible, systemImage: "person.fill")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
                
                Spacer()
                
                Text(ticket.priorityName ?? "-")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Ticket Detail Panel

struct TicketDetailPanel: View {
    let ticket: TdxTicket?
    let feed: [TdxFeedEntry]
    let notifyOptions: [(id: String, label: String)]
    let isLoading: Bool
    @Binding var isPerformingAction: Bool
    @Binding var actionMessage: String?
    @Binding var newComment: String
    @Binding var isPrivateComment: Bool
    @Binding var notifyRecipients: Set<String>
    @Binding var showOnlyComments: Bool
    @Binding var isEditingDescription: Bool
    @Binding var editedDescription: String
    let allStatuses: [Int: String]
    let allPriorities: [Int: String]
    let onAddComment: () -> Void
    let onOpenInWeb: () -> Void
    let onUpdateStatus: (Int) -> Void
    let onUpdatePriority: (Int) -> Void
    let onUpdateDescription: (String) -> Void
    let onRefresh: () -> Void
    let onClose: () -> Void
    
    // Local state for dropdown selections
    @State private var selectedStatusId: Int = 0
    @State private var selectedPriorityId: Int = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if let ticket = ticket, let id = ticket.id {
                    Text("#\(id)")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                } else {
                    Text("Ticket Details")
                        .font(.headline)
                }
                Spacer()
                
                if ticket != nil {
                    Button(action: onOpenInWeb) {
                        Image(systemName: "globe")
                    }
                    .help("Open in Web Browser")
                }
                
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
            } else if let ticket = ticket {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Title
                        Text(ticket.title ?? "Untitled")
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        // Status and Priority - editable dropdowns
                        HStack(spacing: 12) {
                            // Status dropdown
                            HStack(spacing: 4) {
                                Text("Status:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Picker("", selection: $selectedStatusId) {
                                    ForEach(allStatuses.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                                        Text(name).tag(id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                                .onChange(of: selectedStatusId) { _, newValue in
                                    if newValue != ticket.statusId && newValue != 0 {
                                        onUpdateStatus(newValue)
                                    }
                                }
                            }
                            
                            // Priority dropdown
                            HStack(spacing: 4) {
                                Text("Priority:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Picker("", selection: $selectedPriorityId) {
                                    ForEach(allPriorities.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                                        Text(name).tag(id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                                .onChange(of: selectedPriorityId) { _, newValue in
                                    if newValue != ticket.priorityId && newValue != 0 {
                                        onUpdatePriority(newValue)
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Details Grid
                        VStack(alignment: .leading, spacing: 8) {
                            DetailRow(label: "Requestor", value: ticket.requestorName)
                            DetailRow(label: "Email", value: ticket.requestorEmail)
                            DetailRow(label: "Group", value: ticket.responsibleGroupName)
                            
                            // Responsible - editable (if we have people data)
                            HStack {
                                Text("Responsible:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                Text(ticket.responsibleFullName ?? "-")
                                    .font(.body)
                                    .foregroundColor(.primary)
                            }
                            DetailRow(label: "Created", value: formatDate(ticket.createdDate))
                            DetailRow(label: "Modified", value: formatDate(ticket.modifiedDate))
                            if ticket.isOnHold == true {
                                DetailRow(label: "On Hold Until", value: formatDate(ticket.goesOffHoldDate))
                            }
                        }
                        
                        // Description - editable
                        Divider()
                        HStack {
                            Text("Description")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Edit") {
                                isEditingDescription = true
                            }
                            .font(.caption)
                        }
                        
                        if isEditingDescription {
                            TextEditor(text: $editedDescription)
                                .font(.body)
                                .frame(minHeight: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            HStack {
                                Button("Cancel") {
                                    isEditingDescription = false
                                    editedDescription = decodeHtml(ticket.description ?? "")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Save") {
                                    onUpdateDescription(editedDescription)
                                    isEditingDescription = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isPerformingAction)
                            }
                        } else {
                            if let desc = ticket.description, !desc.isEmpty {
                                Text(decodeHtml(desc))
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            } else {
                                Text("No description")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                        
                        // Add Comment (moved BEFORE activity)
                        Divider()
                        Text("Add Comment")
                            .font(.headline)
                        
                        TextEditor(text: $newComment)
                            .font(.body)
                            .frame(height: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        
                        // Notify options
                        if !notifyOptions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Notify:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                ForEach(notifyOptions, id: \.id) { option in
                                    Toggle(option.label, isOn: Binding(
                                        get: { notifyRecipients.contains(option.id) },
                                        set: { isOn in
                                            if isOn {
                                                notifyRecipients.insert(option.id)
                                            } else {
                                                notifyRecipients.remove(option.id)
                                            }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .font(.subheadline)
                                }
                            }
                        }
                        
                        HStack {
                            Toggle("Private", isOn: $isPrivateComment)
                                .toggleStyle(.checkbox)
                                .font(.subheadline)
                            Spacer()
                            Button("Post Comment", action: onAddComment)
                                .disabled(newComment.isEmpty || isPerformingAction)
                        }
                        
                        if let message = actionMessage {
                            Text(message)
                                .font(.subheadline)
                                .foregroundColor(message.contains("Error") ? .red : .green)
                        }
                        
                        // Comments/Feed (after Add Comment)
                        if !feed.isEmpty {
                            Divider()
                            HStack {
                                Text("Activity (\(feed.count))")
                                    .font(.headline)
                                Spacer()
                                Toggle("Comments only", isOn: $showOnlyComments)
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                            }
                            
                            ForEach(feed.prefix(20), id: \.id) { entry in
                                FeedEntryView(entry: entry)
                            }
                        }
                    }
                    .padding()
                }
                .onAppear {
                    // Initialize dropdown selections from ticket
                    selectedStatusId = ticket.statusId ?? 0
                    selectedPriorityId = ticket.priorityId ?? 0
                    // Initialize description editor
                    editedDescription = decodeHtml(ticket.description ?? "")
                    isEditingDescription = false
                }
                .onChange(of: ticket.statusId) { _, newValue in
                    selectedStatusId = newValue ?? 0
                }
                .onChange(of: ticket.priorityId) { _, newValue in
                    selectedPriorityId = newValue ?? 0
                }
            } else {
                VStack {
                    Spacer()
                    ContentUnavailableView(
                        "Select a Ticket",
                        systemImage: "ticket",
                        description: Text("Select a ticket from the list to view details")
                    )
                    Spacer()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private func formatDate(_ dateString: String?) -> String? {
        guard let dateString = dateString else { return nil }
        // Parse ISO8601 date and format in local timezone
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: dateString) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.timeZone = .current  // Use system timezone
            return formatter.string(from: date)
        }
        // Fallback: try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: dateString) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
        // Last fallback: just show the string as-is
        return String(dateString.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
    
    private func decodeHtml(_ html: String) -> String {
        var result = html
        // Strip HTML tags
        result = result.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<p>", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&#160;", with: " ")
        // Trim extra whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

struct DetailRow: View {
    let label: String
    let value: String?
    
    var body: some View {
        if let value = value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label + ":")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(.primary)  // Values should be primary color
                    .textSelection(.enabled)
            }
        }
    }
}

struct FeedEntryView: View {
    let entry: TdxFeedEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.createdFullName ?? "Unknown")
                    .font(.body)
                    .fontWeight(.medium)
                if entry.isPrivate == true {
                    Text("Private")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.3))
                        .cornerRadius(4)
                }
                Spacer()
                Text(formatDate(entry.createdDate))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if let body = entry.body {
                Text(decodeHtml(body))
                    .font(.body)  // Match description font size
                    .foregroundColor(.primary)  // Content should be primary color
                    .lineLimit(nil)  // Allow full content
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
    
    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "-" }
        // Parse ISO8601 date and format in local timezone
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: dateString) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.timeZone = .current  // Use system timezone
            return formatter.string(from: date)
        }
        // Fallback: try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: dateString) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.timeZone = .current
            return formatter.string(from: date)
        }
        // Last fallback: just show the string as-is
        return String(dateString.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
    
    private func decodeHtml(_ html: String) -> String {
        var result = html
        // Convert HTML line breaks to newlines
        result = result.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<p>", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        // Strip remaining HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&#160;", with: " ")
        // Trim extra whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}

struct TicketStatusBadge: View {
    let statusName: String?

    var body: some View {
        let color: Color = {
            switch statusName?.lowercased() {
            case "new", "open": return .blue
            case "in progress", "in process": return .yellow
            case "resolved", "closed": return .green
            case "on hold": return .gray
            default: return .secondary
            }
        }()

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(statusName ?? "Unknown")
                .font(.subheadline)
        }
    }
}

#Preview {
    TicketsView()
        .environmentObject(AppState())
}
