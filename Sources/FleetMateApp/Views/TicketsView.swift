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

    var tickets: [TdxTicket] { appState.cachedTickets }

    var selectedTicket: TdxTicket? {
        guard let id = selectedTicketIds.first, let unwrappedId = id else { return nil }
        return tickets.first { $0.id == unwrappedId }
    }

    // MARK: - Filter Options

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

    var filteredFeed: [TdxFeedEntry] {
        switch feedFilter {
        case .comments:
            return ticketFeed.filter { $0.createdFullName != "System" && $0.body != nil && !($0.body ?? "").isEmpty }
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
                loadTicketFeed(ticketId: unwrappedId)
            } else {
                ticketFeed = []
            }
        }
        .task {
            if !appState.isTicketsCacheValid {
                loadTickets()
            }
        }
        .onChange(of: appState.cachedTickets) { _, _ in
            applyMeMode()
        }
        .onAppear {
            applyMeMode()
            // Auto-trigger SSO if not authenticated and SSO is available
            if !appState.tdxSsoAuthenticated && appState.tdxService.shouldAttemptSso {
                appState.triggerTdxSsoLogin()
            }
        }
        .sheet(isPresented: $appState.showTdxSsoLogin) {
            TdxSsoLoginView(config: appState.config) { result in
                if result.success, let token = result.token {
                    let expiry = Date().addingTimeInterval(23 * 60 * 60)
                    appState.handleTdxSsoSuccess(
                        token: token,
                        expiry: expiry,
                        userId: result.userEmail,
                        userName: result.userName
                    )
                } else {
                    appState.handleTdxSsoFailure(result.error)
                }
            }
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
                // Update ticket status via API
                Task {
                    do {
                        let updates: [String: Any] = ["StatusID": newStatusId]
                        _ = try await appState.tdxService.updateTicket(id: ticketId, updates: updates)
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
        if let ticket = selectedTicket {
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
                Button(action: { loadTicketFeed(ticketId: ticket.id ?? 0) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            Text(ticket.title ?? "Untitled")
                .font(.title3)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                TicketStatusBadge(statusName: ticket.statusName)
                Text(ticket.priorityName ?? "")
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Detail Fields

    private func detailFields(ticket: TdxTicket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailRow(label: "Requestor", value: ticket.requestorName ?? "-")
            DetailRow(label: "Email", value: ticket.requestorEmail ?? "-")
            if let group = ticket.responsibleGroupName, !group.isEmpty {
                DetailRow(label: "Group", value: group)
            }
            DetailRow(label: "Responsible", value: ticket.responsibleFullName ?? "-")
            DetailRow(label: "Created", value: formatDateString(ticket.createdDate))
            DetailRow(label: "Modified", value: formatDateString(ticket.modifiedDate))

            if let description = ticket.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(Self.decodeHtml(description))
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                }
            }
        }
        .padding(.vertical, 4)
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

