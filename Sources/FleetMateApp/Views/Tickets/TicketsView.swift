import SwiftUI
import FleetMateCore

enum TicketSortField: String, CaseIterable {
    case id = "ID"
    case modified = "Modified"
    case created = "Created"
    case title = "Title"
    case status = "Status"
    case priority = "Priority"
    case requestor = "Requestor"
    case responsible = "Responsible"
}

enum TicketViewMode: String, CaseIterable {
    case table = "Table"
    case board = "Board"
}

struct TicketsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sortField: TicketSortField = .modified
    @State private var sortAscending = false
    @State private var selectedTicketIds: Set<Int?> = []
    @State private var ticketFeed: [TdxFeedEntry] = []
    @State private var isLoadingFeed = false
    @State private var showClosed = false
    @State private var meModeApplied = false
    @State private var maxResults = 500

    // Filter states
    @State private var statusFilter = "All"
    @State private var groupFilter = "All"
    @State private var responsibleFilter = "All"

    // Comment state
    @State private var newComment = ""
    @State private var isCommentPrivate = false
    @State private var isAddingComment = false
    @State private var notifyRequestor = false
    @State private var notifyResponsible = false
    @State private var notifyGroup = false

    // Feed filter
    @State private var feedFilter: FeedFilterType = .comments

    // View mode
    @State private var viewMode: TicketViewMode = .table

    // Detail editing state
    @State private var detailedTicket: TdxTicket? = nil
    @State private var isLoadingDetail = false
    @State private var editTitle = ""
    @State private var editStatusId: Int? = nil
    @State private var editPriorityId: Int? = nil
    @State private var editDescription = ""
    @State private var editResponsibleGroupId: Int? = nil
    @State private var editServiceId: Int? = nil
    @State private var editFormId: Int? = nil
    @State private var editRequestorUid: String? = nil
    @State private var editRequestorName: String = ""
    @State private var editResponsibleUid: String? = nil
    @State private var editResponsibleName: String = ""
    @State private var editClassification: Int? = nil
    // People search state
    @State private var requestorSearchText = ""
    @State private var requestorSearchResults: [TdxPerson] = []
    @State private var isSearchingRequestor = false
    @State private var showRequestorResults = false
    @State private var isChangingRequestor = false
    @State private var responsibleSearchText = ""
    @State private var responsibleSearchResults: [TdxPerson] = []
    @State private var isSearchingResponsible = false
    @State private var showResponsibleResults = false
    @State private var isReassigning = false
    // Actions menu
    @State private var showActionsMenu = false
    @State private var showSetParentSheet = false
    @State private var parentTicketIdText = ""
    @State private var isSettingParent = false
    @State private var isSaving = false
    @State private var hasEdits = false
    @State private var isEditingDescription = false
    @State private var saveErrorMessage: String? = nil
    @State private var saveSucceeded = false
    @State private var isSavingDescription = false

    @FocusState private var descriptionFocused: Bool

    var tickets: [TdxTicket] { appState.cachedTickets }

    var selectedTicket: TdxTicket? {
        guard let id = selectedTicketIds.first, let unwrappedId = id else { return nil }
        return detailedTicket ?? tickets.first { $0.id == unwrappedId }
    }

    // MARK: - Filter Options

    /// Unique status (id, name) pairs from loaded tickets — for edit picker
    var statusIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.statusId, let name = t.statusName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Unique priority (id, name) pairs from loaded tickets — for edit picker
    var priorityIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.priorityId, let name = t.priorityName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Unique group (id, name) pairs from loaded tickets
    var groupIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.responsibleGroupId, let name = t.responsibleGroupName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Unique service (id, name) pairs from loaded tickets
    var serviceIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.serviceId, let name = t.serviceName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Unique form (id, name) pairs from loaded tickets
    var formIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.formId, let name = t.formName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Unique classification (id, name) pairs from loaded tickets
    var classificationIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.classification, let name = t.classificationName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    var statusOptions: [String] {
        var opts = Set<String>()
        for t in tickets {
            if let s = t.statusName, !s.isEmpty { opts.insert(s) }
        }
        return ["All"] + opts.sorted()
    }

    var groupOptions: [String] {
        var opts = Set<String>()
        for t in tickets {
            if let g = t.responsibleGroupName, !g.isEmpty { opts.insert(g) }
        }
        return ["All"] + opts.sorted()
    }

    var responsibleOptions: [String] {
        var opts = Set<String>()
        for t in tickets {
            if let r = t.responsibleFullName, !r.isEmpty { opts.insert(r) }
        }
        return ["All"] + opts.sorted()
    }

    var filteredTickets: [TdxTicket] {
        var result = tickets

        // Show closed toggle (off by default = hide closed)
        if !showClosed {
            result = result.filter {
                let s = ($0.statusName ?? "").lowercased()
                return s != "closed" && s != "cancelled" && s != "canceled"
            }
        }

        // Status filter
        if statusFilter != "All" {
            result = result.filter { $0.statusName == statusFilter }
        }

        // Group filter
        if groupFilter != "All" {
            result = result.filter { $0.responsibleGroupName == groupFilter }
        }

        // Responsible filter
        if responsibleFilter != "All" {
            result = result.filter { $0.responsibleFullName == responsibleFilter }
        }

        // Search
        if !searchText.isEmpty {
            result = result.filter {
                ($0.title?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.requestorName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                "\($0.id ?? 0)".contains(searchText)
            }
        }

        return result.sorted { a, b in
            switch sortField {
            case .id:
                let aId = a.id ?? 0
                let bId = b.id ?? 0
                return sortAscending ? aId < bId : aId > bId
            case .modified:
                return compareDates(a.modifiedDate, b.modifiedDate)
            case .created:
                return compareDates(a.createdDate, b.createdDate)
            case .title:
                return compareStrings(a.title, b.title)
            case .status:
                return compareStrings(a.statusName, b.statusName)
            case .priority:
                return compareStrings(a.priorityName, b.priorityName)
            case .requestor:
                return compareStrings(a.requestorName, b.requestorName)
            case .responsible:
                return compareStrings(a.responsibleFullName, b.responsibleFullName)
            }
        }
    }

    // MARK: - Feed Filtering

    /// Check if a feed entry body looks like a system-generated activity message
    private static func isSystemActivity(_ body: String) -> Bool {
        let stripped = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let activityPhrases = [
            "edited this", "updated this", "changed the", "modified this",
            "reassigned this", "set the", "cleared the", "removed the",
            "added a task", "completed a task", "created this",
            "attached", "unattached", "merged", "associated",
            "escalated", "de-escalated",
            "changed status", "changed priority", "changed responsible",
            "moved from", "moved to"
        ]
        return activityPhrases.contains { stripped.hasPrefix($0) || stripped.contains($0) }
    }

    var filteredFeed: [TdxFeedEntry] {
        switch feedFilter {
        case .comments:
            // Real user comments only — exclude System author AND system-generated activity bodies
            return ticketFeed.filter { entry in
                guard entry.createdFullName != "System" else { return false }
                guard let body = entry.body, !body.isEmpty else { return false }
                return !Self.isSystemActivity(body)
            }
        case .activity:
            return ticketFeed.filter { $0.createdFullName != "System" }
        case .all:
            return ticketFeed
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            contentSection
        }
        .onChange(of: selectedTicketIds) { _, newIds in
            if let ticketId = newIds.first, let unwrappedId = ticketId {
                loadTicketDetail(ticketId: unwrappedId)
                loadTicketFeed(ticketId: unwrappedId)
            } else {
                detailedTicket = nil
                ticketFeed = []
                hasEdits = false
            }
        }
        .task {
            if !appState.isTicketsCacheValid {
                loadTickets()
            }
            // Handle deep link set before view was created
            if let id = appState.navigateToTicketId {
                selectedTicketIds = [id]
                appState.navigateToTicketId = nil
            }
        }
        .onChange(of: appState.navigateToTicketId) { _, newId in
            if let id = newId {
                selectedTicketIds = [id]
                appState.navigateToTicketId = nil
            }
        }
        .onChange(of: appState.cachedTickets) { _, _ in
            applyMeMode()
        }
        .onAppear {
            applyMeMode()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Title + SSO + Refresh
            HStack {
                Text("Tickets")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("\(filteredTickets.count) of \(tickets.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                Spacer()
                ssoSection
                Button(action: loadTickets) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            // Row 2: View mode toggle + filters + search — all in one row
            HStack(spacing: 10) {
                Picker("", selection: $viewMode) {
                    Text("Table").tag(TicketViewMode.table)
                    Text("Board").tag(TicketViewMode.board)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Divider().frame(height: 20)

                HStack(spacing: 4) {
                    Text("Status:").foregroundColor(.secondary).font(.caption)
                    Picker("", selection: $statusFilter) {
                        ForEach(statusOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 120)
                }

                HStack(spacing: 4) {
                    Text("Group:").foregroundColor(.secondary).font(.caption)
                    Picker("", selection: $groupFilter) {
                        ForEach(groupOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 140)
                }

                HStack(spacing: 4) {
                    Text("Responsible:").foregroundColor(.secondary).font(.caption)
                    Picker("", selection: $responsibleFilter) {
                        ForEach(responsibleOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 140)
                }

                Toggle("Show Closed", isOn: $showClosed)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: 4) {
                    Text("Limit:").foregroundColor(.secondary).font(.caption)
                    Picker("", selection: $maxResults) {
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                        Text("2000").tag(2000)
                        Text("5000").tag(5000)
                    }
                    .frame(width: 80)
                    .onChange(of: maxResults) { _, _ in
                        loadTickets()
                    }
                }

                Spacer()

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 140)
                }
                .padding(5)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var ssoSection: some View {
        if appState.tdxSsoAuthenticated, let userName = appState.tdxAuthenticatedUserName {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.green)
                Text(userName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { appState.signOutTdxSso() }) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Sign out of TDX SSO")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1))
            .cornerRadius(6)
        } else if appState.tdxService.shouldAttemptSso {
            Button(action: { appState.triggerTdxSsoLogin() }) {
                Label("Sign In", systemImage: "person.badge.key")
            }
            .help("Sign in with SSO to perform actions as yourself")
        }
    }

    // MARK: - Content Section
    // (filtersSection and viewModeToggle are now in headerSection)

    @ViewBuilder
    private var contentSection: some View {
        if !appState.config.isTdxConfigured {
            VStack {
                ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("TeamDynamix is not configured. Set TDX_BASE_URL and TDX_APP_ID in your config.")
                )
                Spacer()
            }
        } else if isLoading && appState.cachedTickets.isEmpty {
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
            switch viewMode {
            case .table:
                ticketsTableView
            case .board:
                ticketsBoardView
            }
        }
    }

    // MARK: - Table + Detail (60/40)

    private var ticketsTableView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ticketTableContent
                    .frame(width: geometry.size.width * 0.6)
                Divider()
                detailSidebarView
                    .frame(width: geometry.size.width * 0.4)
            }
        }
    }

    // MARK: - Board + Detail (60/40)

    private var ticketsBoardView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ticketBoardContent
                    .frame(width: selectedTicket != nil ? geometry.size.width * 0.6 : geometry.size.width)
                if selectedTicket != nil {
                    Divider()
                    detailSidebarView
                        .frame(width: geometry.size.width * 0.4)
                }
            }
        }
    }

    private var ticketBoardContent: some View {
        let statuses: [Int: String] = {
            var map = [Int: String]()
            for ticket in filteredTickets {
                if let statusId = ticket.statusId, let statusName = ticket.statusName {
                    map[statusId] = statusName
                }
            }
            return map
        }()
        
        return TicketBoardView(
            tickets: filteredTickets,
            statuses: statuses,
            onUpdateStatus: { ticketId, newStatusId in
                // Update ticket status via API — use full TicketUpdateRequest to avoid TDX 400
                Task {
                    do {
                        if let base = filteredTickets.first(where: { $0.id == ticketId }) {
                            let req = TicketUpdateRequest(from: base, statusId: newStatusId)
                            _ = try await appState.tdxService.updateTicket(id: ticketId, request: req)
                        }
                        loadTickets()
                    } catch {
                        print("Failed to update ticket status: \(error)")
                    }
                }
            },
            onSelectTicket: { ticket in
                selectedTicketIds = [ticket.id]
            }
        )
    }

    private var ticketTableContent: some View {
        VStack(spacing: 0) {
            // Sortable column headers
            HStack(spacing: 0) {
                sortableColumnHeader("ID", field: .id, width: 100)
                sortableColumnHeader("Title", field: .title, width: nil)
                sortableColumnHeader("Status", field: .status, width: 110)
                sortableColumnHeader("Priority", field: .priority, width: 90)
                sortableColumnHeader("Requestor", field: .requestor, width: 130)
                sortableColumnHeader("Responsible", field: .responsible, width: 130)
                sortableColumnHeader("Modified", field: .modified, width: 120)
                sortableColumnHeader("Created", field: .created, width: 120)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            
            Divider()
            
            // Ticket rows
            List(filteredTickets, id: \.id, selection: $selectedTicketIds) { ticket in
                HStack(spacing: 0) {
                    Text(verbatim: "#\(ticket.id ?? 0)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100, alignment: .leading)
                        .textSelection(.enabled)
                    Text(ticket.title ?? "-")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    TicketStatusBadge(statusName: ticket.statusName)
                        .frame(width: 110, alignment: .leading)
                    Text(ticket.priorityName ?? "-")
                        .frame(width: 90, alignment: .leading)
                        .textSelection(.enabled)
                    Text(ticket.requestorName ?? "-")
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(ticket.responsibleFullName ?? "-")
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(formatDateString(ticket.modifiedDate))
                        .frame(width: 120, alignment: .leading)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatDateString(ticket.createdDate))
                        .frame(width: 120, alignment: .leading)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    /// Build a clickable sortable column header
    private func sortableColumnHeader(_ title: String, field: TicketSortField, width: CGFloat?) -> some View {
        Button(action: { toggleSort(field) }) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    /// Toggle sort on a column
    private func toggleSort(_ field: TicketSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
    }

    // MARK: - Detail Sidebar (single view, no tabs)

    @ViewBuilder
    private var detailSidebarView: some View {
        if isLoadingDetail && detailedTicket == nil {
            VStack {
                Spacer()
                ProgressView("Loading ticket...")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let ticket = selectedTicket {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(ticket: ticket)
                    Divider()
                    detailFields(ticket: ticket)
                    Divider().padding(.vertical, 8)
                    addCommentSection(ticket: ticket)
                    Divider().padding(.vertical, 8)
                    activitySection
                }
                .padding()
            }
        } else {
            VStack {
                Spacer()
                Image(systemName: "ticket")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.bottom, 8)
                Text("No Ticket Selected")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Select a ticket to view details")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Detail Header

    private func detailHeader(ticket: TdxTicket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Ticket number - click to copy
                Button(action: {
                    let ticketNum = "\(ticket.id ?? 0)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ticketNum, forType: .string)
                }) {
                    Text(verbatim: "#\(ticket.id ?? 0)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Click to copy ticket number")
                
                // Copy link button
                Button(action: {
                    let baseUrl = (appState.config.tdxBaseUrl ?? "").replacingOccurrences(of: "/TDWebApi", with: "")
                    let appId = appState.config.tdxTicketingAppId ?? appState.config.tdxAppId ?? 0
                    let url = "\(baseUrl)/TDNext/Apps/\(appId)/Tickets/TicketDet?TicketID=\(ticket.id ?? 0)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }) {
                    Image(systemName: "link")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Copy ticket link")
                
                // Open in web button
                Button(action: {
                    let baseUrl = (appState.config.tdxBaseUrl ?? "").replacingOccurrences(of: "/TDWebApi", with: "")
                    let appId = appState.config.tdxTicketingAppId ?? appState.config.tdxAppId ?? 0
                    let urlStr = "\(baseUrl)/TDNext/Apps/\(appId)/Tickets/TicketDet?TicketID=\(ticket.id ?? 0)"
                    if let url = URL(string: urlStr) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "globe")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Open ticket in web browser")
                
                Spacer()

                if hasEdits {
                    Button(action: { discardEdits(ticket: ticket) }) {
                        Text("Discard")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Discard changes")

                    Button(action: { saveTicket(ticket: ticket) }) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Save", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .disabled(isSaving)
                    .help("Save changes")
                }

                if saveSucceeded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Saved")
                }

                // Actions menu
                Menu {
                    Button(action: { showSetParentSheet = true }) {
                        Label("Set Parent Ticket", systemImage: "arrow.up.doc")
                    }
                    Button(action: { createParentTicket(for: ticket) }) {
                        Label("Create Parent", systemImage: "plus.rectangle.on.rectangle")
                    }
                    Button(action: { /* TODO: merge into */ }) {
                        Label("Merge Into...", systemImage: "arrow.triangle.merge")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 80)
                .help("Ticket actions")

                Button(action: {
                    loadTicketDetail(ticketId: ticket.id ?? 0)
                    loadTicketFeed(ticketId: ticket.id ?? 0)
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }

            // Editable title
            TextField("Title", text: $editTitle)
                .font(.title3)
                .fontWeight(.semibold)
                .textFieldStyle(.plain)
                .onChange(of: editTitle) { _, _ in trackEdits(ticket: ticket) }

            if let errMsg = saveErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errMsg)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                    Button(action: { saveErrorMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            HStack(spacing: 8) {
                // Editable status picker
                Picker("", selection: Binding(
                    get: { editStatusId ?? ticket.statusId ?? 0 },
                    set: { editStatusId = $0; hasEdits = true }
                )) {
                    ForEach(statusIdOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .frame(width: 140)

                // Editable priority picker
                Picker("", selection: Binding(
                    get: { editPriorityId ?? ticket.priorityId ?? 0 },
                    set: { editPriorityId = $0; hasEdits = true }
                )) {
                    ForEach(priorityIdOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .frame(width: 120)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Detail Fields

    private func detailFields(ticket: TdxTicket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two-column grid: left = editable fields, right = metadata
            HStack(alignment: .top, spacing: 16) {
                // LEFT COLUMN — editable fields
                VStack(alignment: .leading, spacing: 6) {
                    // Responsible + ... menu
                    fieldRow(label: "Responsible") {
                        HStack(spacing: 4) {
                            Text(editResponsibleName.isEmpty ? "-" : editResponsibleName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Menu {
                                if let myName = appState.tdxAuthenticatedUserName,
                                   let myUid = appState.tdxService.authenticatedUserId {
                                    Button(action: {
                                        editResponsibleUid = myUid
                                        editResponsibleName = myName
                                        isReassigning = false
                                        trackEdits(ticket: ticket)
                                    }) {
                                        Label("Assign to me", systemImage: "person.fill")
                                    }
                                }
                                Button(action: {
                                    isReassigning = true
                                    responsibleSearchText = ""
                                    responsibleSearchResults = []
                                }) {
                                    Label("Reassign", systemImage: "person.2.fill")
                                }
                                Button(action: {
                                    editResponsibleUid = nil
                                    editResponsibleName = ""
                                    isReassigning = false
                                    trackEdits(ticket: ticket)
                                }) {
                                    Label("Unassign", systemImage: "person.fill.xmark")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 20)
                        }
                    }
                    // Search field — only shown when reassigning
                    if isReassigning {
                        personSearchField(
                            searchText: $responsibleSearchText,
                            searchResults: $responsibleSearchResults,
                            isSearching: $isSearchingResponsible,
                            showResults: $showResponsibleResults,
                            onSelect: { person in
                                editResponsibleUid = person.uid
                                editResponsibleName = person.fullName ?? ""
                                responsibleSearchText = ""
                                showResponsibleResults = false
                                isReassigning = false
                                trackEdits(ticket: ticket)
                            }
                        )
                        .padding(.leading, 84)
                    }

                    // Group picker (below Responsible)
                    if !groupIdOptions.isEmpty {
                        fieldRow(label: "Group") {
                            Picker("", selection: Binding(
                                get: { editResponsibleGroupId ?? ticket.responsibleGroupId ?? 0 },
                                set: { editResponsibleGroupId = $0; trackEdits(ticket: ticket) }
                            )) {
                                Text("None").tag(0)
                                ForEach(groupIdOptions, id: \.id) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                            .labelsHidden()
                        }
                    } else {
                        DetailRow(label: "Group", value: ticket.responsibleGroupName ?? "-")
                    }

                    // Service picker
                    if !serviceIdOptions.isEmpty {
                        fieldRow(label: "Service") {
                            Picker("", selection: Binding(
                                get: { editServiceId ?? ticket.serviceId ?? 0 },
                                set: { editServiceId = $0; trackEdits(ticket: ticket) }
                            )) {
                                Text("None").tag(0)
                                ForEach(serviceIdOptions, id: \.id) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                            .labelsHidden()
                        }
                    } else if let service = ticket.serviceName, !service.isEmpty {
                        DetailRow(label: "Service", value: service)
                    }

                    // Form picker
                    if !formIdOptions.isEmpty {
                        fieldRow(label: "Form") {
                            Picker("", selection: Binding(
                                get: { editFormId ?? ticket.formId ?? 0 },
                                set: { editFormId = $0; trackEdits(ticket: ticket) }
                            )) {
                                Text("None").tag(0)
                                ForEach(formIdOptions, id: \.id) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                            .labelsHidden()
                        }
                    } else if let form = ticket.formName, !form.isEmpty {
                        DetailRow(label: "Form", value: form)
                    }

                    // Classification picker
                    if !classificationIdOptions.isEmpty {
                        fieldRow(label: "Classification") {
                            Picker("", selection: Binding(
                                get: { editClassification ?? ticket.classification ?? 0 },
                                set: { editClassification = $0; trackEdits(ticket: ticket) }
                            )) {
                                Text("None").tag(0)
                                ForEach(classificationIdOptions, id: \.id) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                            .labelsHidden()
                        }
                    } else if let cls = ticket.classificationName, !cls.isEmpty {
                        DetailRow(label: "Classification", value: cls)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // RIGHT COLUMN — requestor + metadata
                VStack(alignment: .leading, spacing: 6) {
                    // Requestor — with inline search on demand
                    fieldRow(label: "Requestor") {
                        HStack(spacing: 4) {
                            Text(editRequestorName.isEmpty ? "-" : editRequestorName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Button(action: {
                                isChangingRequestor.toggle()
                                if isChangingRequestor {
                                    requestorSearchText = ""
                                    requestorSearchResults = []
                                }
                            }) {
                                Image(systemName: isChangingRequestor ? "xmark" : "pencil")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if isChangingRequestor {
                        personSearchField(
                            searchText: $requestorSearchText,
                            searchResults: $requestorSearchResults,
                            isSearching: $isSearchingRequestor,
                            showResults: $showRequestorResults,
                            onSelect: { person in
                                editRequestorUid = person.uid
                                editRequestorName = person.fullName ?? ""
                                requestorSearchText = ""
                                showRequestorResults = false
                                isChangingRequestor = false
                                trackEdits(ticket: ticket)
                            }
                        )
                        .padding(.leading, 84)
                    }

                    DetailRow(label: "Email", value: ticket.requestorEmail ?? "-")
                    DetailRow(label: "Created", value: formatDateString(ticket.createdDate))
                    DetailRow(label: "Modified", value: formatDateString(ticket.modifiedDate))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Description — full width below the two columns
            descriptionSection(ticket: ticket)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showSetParentSheet) {
            setParentSheet(ticket: ticket)
        }
    }

    /// A labeled field row — compact label + content
    @ViewBuilder
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
            Spacer()
        }
    }

    /// Searchable person field with autocomplete dropdown
    @ViewBuilder
    private func personSearchField(
        searchText: Binding<String>,
        searchResults: Binding<[TdxPerson]>,
        isSearching: Binding<Bool>,
        showResults: Binding<Bool>,
        onSelect: @escaping (TdxPerson) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Search...", text: searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onChange(of: searchText.wrappedValue) { _, newValue in
                        if newValue.count >= 2 {
                            searchPeopleDebounced(text: newValue, results: searchResults, isSearching: isSearching, showResults: showResults)
                        } else {
                            showResults.wrappedValue = false
                        }
                    }
                if isSearching.wrappedValue {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(4)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(4)

            if showResults.wrappedValue && !searchResults.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(searchResults.wrappedValue, id: \.uid) { person in
                        Button(action: { onSelect(person) }) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.fullName ?? "")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                if let email = person.primaryEmail, !email.isEmpty {
                                    Text(email)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            // hover effect handled by SwiftUI
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .shadow(radius: 2)
            }
        }
    }

    /// Debounced people search
    private func searchPeopleDebounced(
        text: String,
        results: Binding<[TdxPerson]>,
        isSearching: Binding<Bool>,
        showResults: Binding<Bool>
    ) {
        let searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchText.count >= 2 else { return }
        Task {
            isSearching.wrappedValue = true
            defer { isSearching.wrappedValue = false }
            do {
                let people = try await appState.tdxService.searchPeople(searchText: searchText)
                results.wrappedValue = people
                showResults.wrappedValue = !people.isEmpty
            } catch {
                results.wrappedValue = []
                showResults.wrappedValue = false
            }
        }
    }

    /// Description section — full width, read-only by default, editable on demand, auto-saves on Done
    @ViewBuilder
    private func descriptionSection(ticket: TdxTicket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Description")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                if isSavingDescription {
                    ProgressView().controlSize(.small)
                }
                Button(action: {
                    if isEditingDescription {
                        saveDescriptionOnly(ticket: ticket)
                    } else {
                        isEditingDescription = true
                        descriptionFocused = true
                    }
                }) {
                    Label(isEditingDescription ? "Done" : "Edit",
                          systemImage: isEditingDescription ? "checkmark" : "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isSavingDescription)
                .help(isEditingDescription ? "Save description" : "Edit description")
            }
            if isEditingDescription {
                TextEditor(text: $editDescription)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 300)
                    .focused($descriptionFocused)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )
            } else {
                let text = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    Text("No description")
                        .font(.body)
                        .foregroundColor(.secondary.opacity(0.6))
                        .italic()
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                } else {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Add Comment Section

    private func addCommentSection(ticket: TdxTicket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Comment")
                .font(.headline)
            TextEditor(text: $newComment)
                .font(.body)
                .frame(height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // Notify options
            VStack(alignment: .leading, spacing: 4) {
                Text("Notify:")
                    .font(.body)
                    .foregroundColor(.secondary)
                if let requestor = ticket.requestorName, !requestor.isEmpty {
                    Toggle("Requestor: \(requestor)", isOn: $notifyRequestor)
                        .toggleStyle(.checkbox)
                        .font(.body)
                }
                if let responsible = ticket.responsibleFullName, !responsible.isEmpty,
                   ticket.responsibleUid != ticket.requestorUid {
                    Toggle("Responsible: \(responsible)", isOn: $notifyResponsible)
                        .toggleStyle(.checkbox)
                        .font(.body)
                }
                if let group = ticket.responsibleGroupName, !group.isEmpty {
                    Toggle("Group: \(group)", isOn: $notifyGroup)
                        .toggleStyle(.checkbox)
                        .font(.body)
                }
            }

            HStack {
                Toggle("Private", isOn: $isCommentPrivate)
                    .toggleStyle(.checkbox)
                    .font(.body)
                Spacer()
                Button("Post Comment") {
                    Task {
                        isAddingComment = true
                        await addComment(ticket: ticket)
                        newComment = ""
                        isAddingComment = false
                    }
                }
                .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
            }
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Picker("", selection: $feedFilter) {
                    Text("Comments").tag(FeedFilterType.comments)
                    Text("Activity").tag(FeedFilterType.activity)
                    Text("All").tag(FeedFilterType.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if isLoadingFeed {
                ProgressView("Loading activity...")
                    .padding()
            } else if filteredFeed.isEmpty {
                Text("No comments yet")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(filteredFeed, id: \.id) { entry in
                    FeedEntryRow(entry: entry)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadTickets() {
        guard appState.config.isTdxConfigured else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                var searchRequest = TicketSearchRequest(maxResults: maxResults)
                if let groupId = appState.config.tdxResponsibleGroupId {
                    searchRequest.responsibleGroupIds = [groupId]
                }
                let fetchedTickets = try await appState.tdxService.searchTickets(search: searchRequest, maxResults: maxResults)
                appState.updateTicketsCache(fetchedTickets)
            } catch {
                print("Failed to load tickets: \(error)")
            }
        }
    }

    private func loadTicketDetail(ticketId: Int) {
        Task {
            isLoadingDetail = true
            defer { isLoadingDetail = false }
            do {
                if let full = try await appState.tdxService.getTicket(id: ticketId) {
                    detailedTicket = full
                    populateEditFields(from: full)
                }
            } catch {
                print("Failed to load ticket detail: \(error)")
            }
        }
    }

    private func loadTicketFeed(ticketId: Int) {
        Task {
            isLoadingFeed = true
            defer { isLoadingFeed = false }
            do {
                ticketFeed = try await appState.tdxService.getTicketFeed(ticketId: ticketId)
            } catch {
                print("Failed to load ticket feed: \(error)")
                ticketFeed = []
            }
        }
    }

    private func populateEditFields(from ticket: TdxTicket) {
        editTitle = ticket.title ?? ""
        editStatusId = ticket.statusId
        editPriorityId = ticket.priorityId
        editDescription = Self.decodeHtml(ticket.description ?? "")
        editResponsibleGroupId = ticket.responsibleGroupId
        editServiceId = ticket.serviceId
        editFormId = ticket.formId
        editClassification = ticket.classification
        editRequestorUid = ticket.requestorUid
        editRequestorName = ticket.requestorName ?? ""
        editResponsibleUid = ticket.responsibleUid
        editResponsibleName = ticket.responsibleFullName ?? ""
        // Reset search state
        requestorSearchText = ""
        requestorSearchResults = []
        showRequestorResults = false
        responsibleSearchText = ""
        responsibleSearchResults = []
        showResponsibleResults = false
        isReassigning = false
        isChangingRequestor = false
        hasEdits = false
        isEditingDescription = false
    }

    private func trackEdits(ticket: TdxTicket) {
        let origTitle = ticket.title ?? ""
        hasEdits = editTitle.trimmingCharacters(in: .whitespacesAndNewlines) != origTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            || editStatusId != ticket.statusId
            || editPriorityId != ticket.priorityId
            || editResponsibleGroupId != ticket.responsibleGroupId
            || editServiceId != ticket.serviceId
            || editFormId != ticket.formId
            || editClassification != ticket.classification
            || editRequestorUid != ticket.requestorUid
            || editResponsibleUid != ticket.responsibleUid
    }

    private func discardEdits(ticket: TdxTicket) {
        populateEditFields(from: ticket)
    }

    /// Save only the description field immediately (called when user clicks Done)
    private func saveDescriptionOnly(ticket: TdxTicket) {
        guard let ticketId = ticket.id else { return }
        let trimmedDesc = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let origDesc = Self.decodeHtml(ticket.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedDesc != origDesc else {
            isEditingDescription = false
            return
        }

        Task {
            isSavingDescription = true
            defer { isSavingDescription = false }
            do {
                let htmlDesc = trimmedDesc.isEmpty ? "" : trimmedDesc
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "<p>\($0)</p>" }
                    .joined()

                let updateRequest = TicketUpdateRequest(from: ticket, description: htmlDesc)

                if let updated = try await appState.tdxService.updateTicket(id: ticketId, request: updateRequest) {
                    detailedTicket = updated
                    editDescription = Self.decodeHtml(updated.description ?? "")
                    isEditingDescription = false
                } else {
                    saveErrorMessage = "Failed to save description — server returned no data."
                }
            } catch {
                saveErrorMessage = "Description save failed: \(error.localizedDescription)"
            }
        }
    }

    private func saveTicket(ticket: TdxTicket) {
        guard let ticketId = ticket.id else { return }
        Task {
            isSaving = true
            saveErrorMessage = nil
            saveSucceeded = false
            defer { isSaving = false }
            do {
                let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)

                // Build update request — always echoes back original description HTML
                // isRichHtml is always true inside TicketUpdateRequest
                let updateRequest = TicketUpdateRequest(
                    from: ticket,
                    title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                    statusId: editStatusId,
                    priorityId: editPriorityId,
                    classification: editClassification != ticket.classification ? editClassification : nil,
                    requestorUid: editRequestorUid != ticket.requestorUid ? editRequestorUid : nil,
                    responsibleUid: editResponsibleUid != ticket.responsibleUid ? editResponsibleUid : nil,
                    responsibleGroupId: editResponsibleGroupId,
                    serviceId: editServiceId != ticket.serviceId ? editServiceId : nil,
                    formId: editFormId != ticket.formId ? editFormId : nil
                )

                if let updated = try await appState.tdxService.updateTicket(id: ticketId, request: updateRequest) {
                    detailedTicket = updated
                    populateEditFields(from: updated)
                    saveSucceeded = true
                    try? await Task.sleep(for: .seconds(2))
                    saveSucceeded = false
                    loadTickets()
                } else {
                    saveErrorMessage = "Save failed — server returned no data. Check your session."
                }
            } catch {
                saveErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Set Parent Sheet

    private func setParentSheet(ticket: TdxTicket) -> some View {
        VStack(spacing: 16) {
            Text("Set Parent Ticket")
                .font(.headline)
            TextField("Parent Ticket ID", text: $parentTicketIdText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack(spacing: 12) {
                Button("Cancel") {
                    showSetParentSheet = false
                    parentTicketIdText = ""
                }
                Button("Set Parent") {
                    setParentTicket(ticket: ticket)
                }
                .disabled(parentTicketIdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSettingParent)
                .keyboardShortcut(.defaultAction)
            }
            if isSettingParent {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(24)
    }

    private func setParentTicket(ticket: TdxTicket) {
        guard let ticketId = ticket.id else { return }
        let parentIdStr = parentTicketIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parentId = Int(parentIdStr) else {
            saveErrorMessage = "Invalid parent ticket ID."
            return
        }
        Task {
            isSettingParent = true
            defer { isSettingParent = false }
            do {
                let updateRequest = TicketUpdateRequest(from: ticket, parentId: parentId)
                if let updated = try await appState.tdxService.updateTicket(id: ticketId, request: updateRequest) {
                    detailedTicket = updated
                    populateEditFields(from: updated)
                    showSetParentSheet = false
                    parentTicketIdText = ""
                } else {
                    saveErrorMessage = "Failed to set parent ticket."
                }
            } catch {
                saveErrorMessage = "Set parent failed: \(error.localizedDescription)"
            }
        }
    }

    private func createParentTicket(for ticket: TdxTicket) {
        // TODO: Implement create parent ticket — creates a new ticket and sets it as parent
        saveErrorMessage = "Create Parent is not yet implemented."
    }

    private func addComment(ticket: TdxTicket) async {
        var notifyIds: [String] = []
        if notifyRequestor, let uid = ticket.requestorUid { notifyIds.append(uid) }
        if notifyResponsible, let uid = ticket.responsibleUid { notifyIds.append(uid) }

        do {
            _ = try await appState.tdxService.addComment(
                ticketId: ticket.id ?? 0,
                comment: newComment,
                isPrivate: isCommentPrivate,
                notify: notifyIds.isEmpty ? nil : notifyIds
            )
            loadTicketFeed(ticketId: ticket.id ?? 0)
        } catch {
            print("Failed to add comment: \(error)")
        }
    }

    // MARK: - Helpers

    /// Apply "me mode" — default the Responsible filter to the authenticated user
    private func applyMeMode() {
        guard !meModeApplied,
              appState.tdxSsoAuthenticated,
              let userName = appState.tdxAuthenticatedUserName,
              !tickets.isEmpty else { return }
        
        // Find a matching responsible name (case-insensitive contains for flexibility)
        let match = responsibleOptions.first { option in
            option != "All" &&
            (option.localizedCaseInsensitiveContains(userName) ||
             userName.localizedCaseInsensitiveContains(option))
        }
        
        if let match = match {
            responsibleFilter = match
            meModeApplied = true
        }

        // Default group filter to the configured responsible group
        if groupFilter == "All",
           let configGroupId = appState.config.tdxResponsibleGroupId {
            let groupMatch = tickets.first(where: { $0.responsibleGroupId == configGroupId })?.responsibleGroupName
            if let groupMatch = groupMatch {
                groupFilter = groupMatch
            }
        }
    }

    private func compareDates(_ a: String?, _ b: String?) -> Bool {
        let aVal = a ?? ""
        let bVal = b ?? ""
        return sortAscending ? aVal < bVal : aVal > bVal
    }

    private func compareStrings(_ a: String?, _ b: String?) -> Bool {
        let aVal = a ?? ""
        let bVal = b ?? ""
        return sortAscending
            ? aVal.localizedCompare(bVal) == .orderedAscending
            : aVal.localizedCompare(bVal) == .orderedDescending
    }

    private func formatDateString(_ dateString: String?) -> String {
        guard let dateString = dateString, let date = Self.parseDate(dateString) else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter.string(from: date)
    }

    static func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    /// Strip HTML tags and decode entities for plain-text display
    static func decodeHtml(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Feed Filter Type

enum FeedFilterType: String, CaseIterable {
    case comments = "Comments"
    case activity = "Activity"
    case all = "All"
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Feed Entry Row

struct FeedEntryRow: View {
    let entry: TdxFeedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.createdFullName ?? "Unknown")
                    .font(.body)
                    .fontWeight(.semibold)
                Spacer()
                if entry.isPrivate == true {
                    Text("Private")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                if let dateStr = entry.createdDate, let date = TicketsView.parseDate(dateStr) {
                    Text(formatRelativeDate(date))
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            if let body = entry.body, !body.isEmpty {
                Text(TicketsView.decodeHtml(body))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Ticket Status Badge

struct TicketStatusBadge: View {
    let statusName: String?

    var body: some View {
        let color: Color = {
            switch statusName?.lowercased() {
            case "new", "open": return .blue
            case "in progress", "in process": return .orange
            case "resolved", "closed": return .green
            case "on hold", "awaiting response": return .gray
            default: return .secondary
            }
        }()

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(statusName ?? "Unknown")
                .font(.body)
        }
    }
}

#Preview {
    TicketsView()
        .environmentObject(AppState())
}

