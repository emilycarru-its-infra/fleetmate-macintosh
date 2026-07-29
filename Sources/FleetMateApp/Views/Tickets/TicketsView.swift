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

// MARK: - Date Range Preset

enum DateRangePreset: Hashable {
    case today
    case thisWeek
    case thisMonth
    case lastMonth
    case term(AcademicTerm, Int)  // term + year
    case custom

    var label: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .term(let t, let y): return "\(t.rawValue) \(y)"
        case .custom: return "Custom"
        }
    }

    /// Compute the date range for this preset
    func dateRange() -> (from: Date, to: Date) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            let start = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            return (start, end)
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: now)!.start
            let end = cal.date(byAdding: .weekOfYear, value: 1, to: start)!
            return (start, end)
        case .thisMonth:
            let start = cal.dateInterval(of: .month, for: now)!.start
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        case .lastMonth:
            let thisMonth = cal.dateInterval(of: .month, for: now)!.start
            let start = cal.date(byAdding: .month, value: -1, to: thisMonth)!
            return (start, thisMonth)
        case .term(let term, let year):
            return term.dateRange(year: year)
        case .custom:
            // Custom uses the bound date pickers directly
            return (now, now)
        }
    }

    /// The current academic term based on today's date
    static var currentTerm: DateRangePreset {
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        let term: AcademicTerm
        if month >= 1 && month <= 4 {
            term = .spring
        } else if month >= 5 && month <= 8 {
            term = .summer
        } else {
            term = .fall
        }
        return .term(term, year)
    }
}

enum AcademicTerm: String, CaseIterable {
    case spring = "Spring"
    case summer = "Summer"
    case fall = "Fall"

    func dateRange(year: Int) -> (from: Date, to: Date) {
        let cal = Calendar.current
        switch self {
        case .spring:
            let from = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
            let to = cal.date(from: DateComponents(year: year, month: 5, day: 1))!
            return (from, to)
        case .summer:
            let from = cal.date(from: DateComponents(year: year, month: 5, day: 1))!
            let to = cal.date(from: DateComponents(year: year, month: 9, day: 1))!
            return (from, to)
        case .fall:
            let from = cal.date(from: DateComponents(year: year, month: 9, day: 1))!
            let to = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59))!
            return (from, to)
        }
    }
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

    // Date range
    @State private var datePreset: DateRangePreset = DateRangePreset.currentTerm
    @State private var customDateFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var customDateTo: Date = Date()
    @State private var termSeason: AcademicTerm = {
        let month = Calendar.current.component(.month, from: Date())
        if month >= 1 && month <= 4 { return .spring }
        if month >= 5 && month <= 8 { return .summer }
        return .fall
    }()
    @State private var termYear: Int = Calendar.current.component(.year, from: Date())

    // Filter system
    @State private var filters = FilterState<TicketFilterCategory>()
    @State private var showFilters = false
    @State private var allForms: [(id: Int, name: String)] = []

    // Column widths
    @State private var columnWidths: [TicketSortField: CGFloat] = [
        .id: 130, .title: 250, .status: 110, .priority: 90,
        .requestor: 130, .responsible: 130, .modified: 120, .created: 120,
    ]

    // Parent/child outline — collapsed is the exception, so an empty set means
    // every parent starts expanded.
    @State private var collapsedTicketIds: Set<Int> = []

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
    @State private var boardGroupBy: BoardGroupBy = .status

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
    @State private var editTypeId: Int? = nil
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
    @State private var notifyNewResponsible = true
    // Actions menu
    @State private var showActionsMenu = false
    @State private var showCreateTicket = false
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

    /// Unique form (id, name) pairs — prefer API-loaded forms, fallback to ticket-derived
    var formIdOptions: [(id: Int, name: String)] {
        if !allForms.isEmpty { return allForms }
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

    var priorityOptions: [String] {
        var opts = Set<String>()
        for t in tickets {
            if let p = t.priorityName, !p.isEmpty { opts.insert(p) }
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
        return ["All", "None"] + opts.sorted()
    }

    var formFilterOptions: [String] {
        if !allForms.isEmpty {
            return ["All"] + allForms.map { $0.name }
        }
        var opts = Set<String>()
        for t in tickets {
            if let f = t.formName, !f.isEmpty { opts.insert(f) }
        }
        return ["All"] + opts.sorted()
    }

    var classificationFilterOptions: [String] {
        var opts = Set<String>()
        for t in tickets {
            if let c = t.classificationName, !c.isEmpty { opts.insert(c) }
        }
        return ["All"] + opts.sorted()
    }

    /// Unique type (id, name) pairs from loaded tickets
    var typeIdOptions: [(id: Int, name: String)] {
        var seen = Set<Int>()
        var result: [(id: Int, name: String)] = []
        for t in tickets {
            if let id = t.typeId, let name = t.typeName, !name.isEmpty, !seen.contains(id) {
                seen.insert(id)
                result.append((id: id, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    var typeFilterOptions: [String] {
        var opts = Set<String>()
        for t in tickets {
            if let tn = t.typeName, !tn.isEmpty { opts.insert(tn) }
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

        // Filter panel selections
        if filters.hasActiveFilters {
            result = result.filter { filters.matches($0) }
        }

        // Text search
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

    // MARK: - Parent/Child Outline

    /// The filtered tickets arranged as parents with their children beneath.
    var ticketTree: [TicketNode] {
        TicketHierarchy.build(from: filteredTickets)
    }

    /// The rows the table draws — the tree flattened, minus collapsed subtrees.
    var outlineRows: [TicketOutlineRow] {
        TicketHierarchy.flatten(ticketTree, collapsed: collapsedTicketIds)
    }

    private var parentIds: Set<Int> {
        TicketHierarchy.foldableIds(in: filteredTickets)
    }

    private func toggleExpansion(_ ticketId: Int) {
        if collapsedTicketIds.contains(ticketId) {
            collapsedTicketIds.remove(ticketId)
        } else {
            collapsedTicketIds.insert(ticketId)
        }
    }

    // MARK: - Feed Filtering

    /// Check if a feed entry looks like a status change
    private static func isStatusChange(_ body: String) -> Bool {
        let stripped = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let phrases = ["changed status", "changed the status", "moved from", "status changed"]
        return phrases.contains { stripped.contains($0) }
    }

    /// Check if a feed entry looks like a field edit (not status change)
    private static func isFieldEdit(_ body: String) -> Bool {
        if isStatusChange(body) { return false }
        let stripped = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let phrases = [
            "edited this", "updated this", "changed the", "modified this",
            "reassigned this", "set the", "cleared the", "removed the",
            "added a task", "completed a task", "created this",
            "attached", "unattached", "merged", "associated",
            "escalated", "de-escalated",
            "changed priority", "changed responsible", "changed group",
            "changed type", "changed classification", "changed form",
            "changed service", "was modified", "was updated",
            "was reassigned", "was created", "was attached",
            "moved to group", "assigned to", "unassigned from",
            "changed from", "changed to"
        ]
        return phrases.contains { stripped.contains($0) }
    }

    /// Check if a feed entry body looks like any system-generated activity
    private static func isSystemActivity(_ body: String) -> Bool {
        return isStatusChange(body) || isFieldEdit(body)
    }

    /// Check if a feed entry is a user comment (not system-generated)
    private static func isUserComment(_ entry: TdxFeedEntry) -> Bool {
        // System entries are never comments
        if entry.createdFullName == "System" { return false }
        guard let body = entry.body, !body.isEmpty else { return false }
        let stripped = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }

        // If there are replies, this is a comment thread
        if let replies = entry.replies, !replies.isEmpty { return true }

        // Check if the body contains ONLY system-generated content.
        // Some entries have a comment AND a status change — those should be included.
        // Split by newlines and check if every line is a system pattern.
        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let allLinesAreSystem = lines.allSatisfy { line in
            let lower = line.lowercased()
            // Field change pattern: "FieldName : OldValue → NewValue"
            if line.contains(" : ") && line.contains(" → ") { return true }
            if lower.contains(" changed from ") && lower.contains(" to ") { return true }
            // Status change patterns
            let statusPhrases = ["changed status", "changed the status", "moved from", "status changed"]
            if statusPhrases.contains(where: { lower.contains($0) }) { return true }
            // Field edit patterns
            let editPhrases = [
                "edited this", "updated this", "changed the", "modified this",
                "reassigned this", "set the", "cleared the", "removed the",
                "added a task", "completed a task", "created this",
                "attached", "unattached", "merged", "associated",
                "escalated", "de-escalated",
                "changed priority", "changed responsible", "changed group",
                "changed type", "changed classification", "changed form",
                "changed service", "was modified", "was updated",
                "was reassigned", "was created", "was attached",
                "moved to group", "assigned to", "unassigned from"
            ]
            if editPhrases.contains(where: { lower.contains($0) }) { return true }
            return false
        }

        // If all lines are system-generated, it's not a comment
        if allLinesAreSystem { return false }

        return true
    }

    var filteredFeed: [TdxFeedEntry] {
        switch feedFilter {
        case .comments:
            return ticketFeed.filter { Self.isUserComment($0) }
        case .edits:
            return ticketFeed.filter { entry in
                guard let body = entry.body, !body.isEmpty else { return false }
                return Self.isFieldEdit(body)
            }
        case .statusChanges:
            return ticketFeed.filter { entry in
                guard let body = entry.body, !body.isEmpty else { return false }
                return Self.isStatusChange(body)
            }
        case .all:
            return ticketFeed
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No header — everything in toolbar
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
            await appState.resolveTdxMe()
            await loadForms()
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
        .onChange(of: appState.cachedTickets) { _, newTickets in
            applyMeMode()
            filters.buildFromTickets(newTickets)
        }
        .onAppear {
            applyMeMode()
            if !tickets.isEmpty { filters.buildFromTickets(tickets) }
        }
        .searchable(text: $searchText, prompt: "Search tickets...")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ViewModePill(selection: $viewMode)

                if viewMode == .board {
                    Picker("Group by", selection: $boardGroupBy) {
                        ForEach(BoardGroupBy.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .help("Group board columns by")
                }

                if filters.hasActiveFilters || showClosed || !isDefaultDatePreset {
                    Button(action: {
                        filters.clearAll()
                        showClosed = false
                        resetToCurrentTerm()
                    }) {
                        Label("Clear Filters", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                let parents = parentIds
                if !parents.isEmpty {
                    let allCollapsed = parents.isSubset(of: collapsedTicketIds)
                    Button(action: {
                        collapsedTicketIds = allCollapsed ? [] : parents
                    }) {
                        Label(allCollapsed ? "Expand All" : "Collapse All",
                              systemImage: allCollapsed
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(allCollapsed ? "Expand all parent tickets" : "Collapse all parent tickets")
                }

                Button(action: { showFilters.toggle() }) {
                    Label("Filters", systemImage: filters.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    FilterPanelView(filters: filters)
                }

                Button(action: { showCreateTicket = true }) {
                    Label("Create Ticket", systemImage: "plus")
                }
                .help("Create a ticket")
                .popover(isPresented: $showCreateTicket, arrowEdge: .bottom) {
                    CreateTicketView(
                        defaultResponsible: appState.tdxMe,
                        onCreated: { ticket in
                            showCreateTicket = false
                            loadTickets()
                            if let id = ticket.id { selectedTicketIds = [id] }
                        },
                        onCancel: { showCreateTicket = false }
                    )
                    .environmentObject(appState)
                }

                Button(action: loadTickets) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }


    @ViewBuilder
    private var ssoSection: some View {
        if appState.tdxSsoAuthenticated, let userName = appState.tdxAuthenticatedUserName {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.secondary)
                Text(userName)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                Button(action: { appState.signOutTdxSso() }) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .appFont(.caption)
                }
                .buttonStyle(.plain)
                .help("Sign out of TDX SSO")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        } else if appState.tdxService.shouldAttemptSso {
            Button(action: { appState.triggerTdxSsoLogin() }) {
                Label("Sign In", systemImage: "person.badge.key")
            }
            .help("Sign in with SSO to perform actions as yourself")
        }
    }

    // MARK: - Content Section

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
        // HSplitView sizes and clips each pane natively (and is user-resizable),
        // so neither the list nor the detail content can spill past its pane.
        HSplitView {
            ticketTableContent
                .frame(minWidth: 380)
            if selectedTicket != nil {
                detailSidebarView
                    .frame(minWidth: 440, idealWidth: 660, maxWidth: 900)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    // MARK: - Board + Detail

    private var ticketsBoardView: some View {
        // HSplitView clips the board's greedy horizontal ScrollView to its pane
        // and the detail to its own, so neither spills past the divider.
        HSplitView {
            ticketBoardContent
                .frame(minWidth: 380)
            if selectedTicket != nil {
                detailSidebarView
                    .frame(minWidth: 440, idealWidth: 660, maxWidth: 900)
                    .background(Color(nsColor: .windowBackgroundColor))
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
            groupBy: boardGroupBy,
            onDropTicket: { ticketId, targetColumnKey in
                handleBoardDrop(ticketId: ticketId, targetColumnKey: targetColumnKey)
            },
            onSelectTicket: { ticket in
                selectedTicketIds = [ticket.id]
            },
            selectedTicketId: selectedTicket?.id,
            collapsedTicketIds: $collapsedTicketIds
        )
    }

    /// Column definitions for the ticket table
    private var ticketColumns: [(title: String, field: TicketSortField)] {
        [
            ("ID", .id), ("Title", .title), ("Status", .status), ("Priority", .priority),
            ("Requestor", .requestor), ("Responsible", .responsible),
            ("Modified", .modified), ("Created", .created),
        ]
    }

    private func colW(_ field: TicketSortField) -> CGFloat {
        columnWidths[field] ?? 100
    }

    private var ticketTableContent: some View {
        GeometryReader { geo in
            let totalW = ticketColumns.reduce(CGFloat(0)) { $0 + colW($1.field) }
            let minW = max(totalW, geo.size.width)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Sortable column headers with resize handles
                    HStack(spacing: 0) {
                        ForEach(ticketColumns, id: \.field) { col in
                            HStack(spacing: 0) {
                                sortableColumnHeader(col.title, field: col.field, width: colW(col.field))
                                TicketColumnResizeHandle(field: col.field, columnWidths: $columnWidths)
                            }
                            .frame(width: colW(col.field))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: minW)
                    .frame(height: 32)
                    .padding(.leading, 8)
                    .background(Color.secondary.opacity(0.08))

                    Divider()

                    // Ticket rows
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(outlineRows.enumerated()), id: \.element.id) { idx, row in
                                let ticket = row.ticket
                                HStack(spacing: 0) {
                                    HStack(spacing: 2) {
                                        Spacer().frame(width: CGFloat(row.depth) * 14)
                                        disclosureControl(for: row)
                                        Text(verbatim: "#\(ticket.id ?? 0)")
                                            .appFont(.body, design: .monospaced)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: colW(.id) - 12, alignment: .leading)
                                    .padding(.leading, 10).padding(.trailing, 2)
                                    HStack(spacing: 6) {
                                        Text(ticket.title ?? "-")
                                            .lineLimit(1)
                                        if row.hasChildren {
                                            Text(verbatim: "\(row.childCount)")
                                                .appFont(.caption2)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.18))
                                                .foregroundColor(.secondary)
                                                .clipShape(Capsule())
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: colW(.title) - 12, alignment: .leading)
                                    .padding(.leading, 10).padding(.trailing, 2)
                                    TicketStatusBadge(statusName: ticket.statusName)
                                        .frame(width: colW(.status) - 12, alignment: .leading)
                                        .padding(.leading, 10).padding(.trailing, 2)
                                    Text(ticket.priorityName ?? "-")
                                        .frame(width: colW(.priority) - 12, alignment: .leading)
                                        .padding(.leading, 10).padding(.trailing, 2)
                                    Text(ticket.requestorName ?? "-")
                                        .frame(width: colW(.requestor) - 12, alignment: .leading)
                                        .padding(.leading, 10).padding(.trailing, 2)
                                        .lineLimit(1)
                                    Text(ticket.responsibleFullName ?? "-")
                                        .frame(width: colW(.responsible) - 12, alignment: .leading)
                                        .padding(.leading, 10).padding(.trailing, 2)
                                        .lineLimit(1)
                                    Text(formatDateString(ticket.modifiedDate))
                                        .frame(width: colW(.modified) - 12, alignment: .leading)
                                        .padding(.leading, 10).padding(.trailing, 2)
                                        .appFont(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formatDateString(ticket.createdDate))
                                        .frame(width: colW(.created) - 12, alignment: .leading)
                                        .padding(.leading, 10).padding(.trailing, 2)
                                        .appFont(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .frame(minWidth: minW)
                                .frame(height: 28)
                                .background(
                                    selectedTicket?.id == ticket.id
                                        ? Color.accentColor.opacity(0.2)
                                        : (idx % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let id = ticket.id {
                                        selectedTicketIds = [id]
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: max(100, geo.size.height - 33))
                    .frame(minWidth: minW)
                }
            }
            .focusable()
            // Keep keyboard focus for arrow-key navigation but drop the blue
            // macOS focus ring, whose right edge showed as a vertical bar against
            // the detail pane.
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveTicketSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { moveTicketSelection(by: 1); return .handled }
        }
    }

    /// The fold/unfold triangle in front of a parent's ticket number. Children
    /// and childless tickets get an equally wide blank so the numbers line up.
    @ViewBuilder
    private func disclosureControl(for row: TicketOutlineRow) -> some View {
        if row.hasChildren {
            Button(action: { toggleExpansion(row.id) }) {
                Image(systemName: "chevron.right")
                    .appFont(.caption2)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.isExpanded
                  ? "Hide \(row.childCount) child ticket\(row.childCount == 1 ? "" : "s")"
                  : "Show \(row.childCount) child ticket\(row.childCount == 1 ? "" : "s")")
        } else {
            Spacer().frame(width: 12)
        }
    }

    private func moveTicketSelection(by offset: Int) {
        let list = outlineRows.map(\.ticket)
        guard !list.isEmpty else { return }
        guard let currentId = selectedTicketIds.first ?? nil,
              let currentIndex = list.firstIndex(where: { $0.id == currentId }) else {
            if let firstId = list.first?.id { selectedTicketIds = [firstId] }
            return
        }
        let newIndex = min(max(currentIndex + offset, 0), list.count - 1)
        if let newId = list[newIndex].id {
            selectedTicketIds = [newId]
        }
    }

    /// Build a clickable sortable column header
    private func sortableColumnHeader(_ title: String, field: TicketSortField, width: CGFloat) -> some View {
        Button(action: { toggleSort(field) }) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .appFont(.caption2)
                        .foregroundColor(.accentColor)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width - 12, alignment: .leading)
            .padding(.leading, 10)
            .padding(.trailing, 2)
        }
        .buttonStyle(.plain)
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
                    Spacer().frame(height: 10)
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
                    .appFont(.headline)
                    .foregroundColor(.secondary)
                Text("Select a ticket to view details")
                    .appFont(.subheadline)
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
                        .appFont(.title2)
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
                        .appFont(.body)
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
                        .appFont(.body)
                }
                .buttonStyle(.plain)
                .help("Open ticket in web browser")
                
                Spacer()

                if hasEdits {
                    Button(action: { discardEdits(ticket: ticket) }) {
                        Text("Discard")
                            .appFont(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red.opacity(0.7))
                    .controlSize(.small)
                    .help("Discard changes")

                    Button(action: { saveTicket(ticket: ticket) }) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Save", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .controlSize(.small)
                    .disabled(isSaving)
                    .help("Save changes")
                }

                if saveSucceeded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Saved")
                }

                Button(action: { showSetParentSheet = true }) {
                    Label("Set Parent", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Set parent ticket")

                Button(action: { createParentTicket(for: ticket) }) {
                    Label("Create Parent", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Create parent ticket")

                Button(action: { /* TODO: merge into */ }) {
                    Label("Merge Into", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Merge into another ticket")

                Button(action: {
                    loadTicketDetail(ticketId: ticket.id ?? 0)
                    loadTicketFeed(ticketId: ticket.id ?? 0)
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh ticket")
            }

            // Editable title
            TextField("Title", text: $editTitle)
                .appFont(.title3)
                .fontWeight(.semibold)
                .textFieldStyle(.plain)
                .onChange(of: editTitle) { _, _ in trackEdits(ticket: ticket) }

            Divider()

            if let errMsg = saveErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errMsg)
                        .appFont(.caption)
                        .foregroundColor(.red)
                    Spacer()
                    Button(action: { saveErrorMessage = nil }) {
                        Image(systemName: "xmark")
                            .appFont(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            // Adaptive grid so these wrap to the pane width instead of forcing
            // the row wider than the detail pane (which spilled off both edges).
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                // Status
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status")
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { editStatusId ?? ticket.statusId ?? 0 },
                        set: { editStatusId = $0; hasEdits = true }
                    )) {
                        ForEach(statusIdOptions, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Priority
                VStack(alignment: .leading, spacing: 2) {
                    Text("Priority")
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { editPriorityId ?? ticket.priorityId ?? 0 },
                        set: { editPriorityId = $0; hasEdits = true }
                    )) {
                        ForEach(priorityIdOptions, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Classification
                VStack(alignment: .leading, spacing: 2) {
                    Text("Classification")
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { editClassification ?? ticket.classification ?? 0 },
                        set: { editClassification = $0; trackEdits(ticket: ticket) }
                    )) {
                        Text("None").tag(0)
                        ForEach(classificationIdOptions, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                        if let cid = ticket.classification, let cname = ticket.classificationName,
                           !classificationIdOptions.contains(where: { $0.id == cid }) {
                            Text(cname).tag(cid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Form
                VStack(alignment: .leading, spacing: 2) {
                    Text("Form")
                        .appFont(.caption2)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { editFormId ?? ticket.formId ?? 0 },
                        set: { editFormId = $0; trackEdits(ticket: ticket) }
                    )) {
                        Text("None").tag(0)
                        ForEach(formIdOptions, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                        if let fid = ticket.formId, let fname = ticket.formName,
                           !formIdOptions.contains(where: { $0.id == fid }) {
                            Text(fname).tag(fid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                VStack(alignment: .leading, spacing: 10) {
                    // Responsible + ... menu
                    fieldRow(label: "Responsible") {
                        HStack(spacing: 4) {
                            Menu {
                                // Resolved from the signed-in Azure identity, not
                                // from the TDX session — the Web API always
                                // authenticates as the service account, so
                                // gating this on TDX SSO hid it permanently.
                                if let me = appState.tdxMe, let myUid = me.uid {
                                    Button(action: {
                                        editResponsibleUid = myUid
                                        editResponsibleName = me.fullName ?? ""
                                        isReassigning = false
                                        trackEdits(ticket: ticket)
                                    }) {
                                        Label("Assign to me", systemImage: "person.fill")
                                    }
                                    .disabled(editResponsibleUid == myUid)
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
                                Image(systemName: "chevron.down")
                                    .appFont(.caption)
                            }
                            .menuStyle(.borderedButton)
                            .controlSize(.small)
                            Text(editResponsibleName.isEmpty ? "-" : editResponsibleName)
                                .appFont(.body)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    // Search field — only shown when reassigning
                    if isReassigning {
                        VStack(alignment: .leading, spacing: 4) {
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
                            Toggle("Notify new responsible", isOn: $notifyNewResponsible)
                                .toggleStyle(.checkbox)
                                .appFont(.caption)
                        }
                        .padding(.leading, 104)
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
                                if let gid = ticket.responsibleGroupId, let gname = ticket.responsibleGroupName,
                                   !groupIdOptions.contains(where: { $0.id == gid }) {
                                    Text(gname).tag(gid)
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

                    // Type picker
                    fieldRow(label: "Type") {
                        Picker("", selection: Binding(
                            get: { editTypeId ?? ticket.typeId ?? 0 },
                            set: { editTypeId = $0; trackEdits(ticket: ticket) }
                        )) {
                            Text("None").tag(0)
                            ForEach(typeIdOptions, id: \.id) { option in
                                Text(option.name).tag(option.id)
                            }
                            if let tid = ticket.typeId, let tname = ticket.typeName,
                               !typeIdOptions.contains(where: { $0.id == tid }) {
                                Text(tname).tag(tid)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // RIGHT COLUMN — requestor + metadata
                VStack(alignment: .leading, spacing: 10) {
                    // Requestor — with inline search on demand
                    fieldRow(label: "Requestor") {
                        HStack(spacing: 4) {
                            Button(action: {
                                isChangingRequestor.toggle()
                                if isChangingRequestor {
                                    requestorSearchText = ""
                                    requestorSearchResults = []
                                }
                            }) {
                                Image(systemName: isChangingRequestor ? "xmark" : "pencil")
                                    .appFont(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Text(editRequestorName.isEmpty ? "-" : editRequestorName)
                                .appFont(.body)
                                .lineLimit(1)
                            Spacer()
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
                        .padding(.leading, 104)
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
                .appFont(.body)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
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
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                TextField("Search...", text: searchText)
                    .textFieldStyle(.plain)
                    .appFont(.caption)
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
                                    .appFont(.caption)
                                    .foregroundColor(.primary)
                                if let email = person.primaryEmail, !email.isEmpty {
                                    Text(email)
                                        .appFont(.caption2)
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
                    .appFont(.body)
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
                    Image(systemName: isEditingDescription ? "checkmark.circle" : "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isSavingDescription)
                .help(isEditingDescription ? "Save description" : "Edit description")

                if !isEditingDescription {
                    Button(action: {
                        let text = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text.isEmpty ? "" : text, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Copy description")
                }
            }
            if isEditingDescription {
                TextEditor(text: $editDescription)
                    .appFont(.body)
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
                        .appFont(.body)
                        .foregroundColor(.secondary.opacity(0.6))
                        .italic()
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                } else {
                    Text(text)
                        .appFont(.body)
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
                .appFont(.headline)
            TextEditor(text: $newComment)
                .appFont(.body)
                .frame(height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Toggle("Private", isOn: $isCommentPrivate)
                    .toggleStyle(.checkbox)
                    .appFont(.body)
                Spacer()
                Button("Post Comment") {
                    Task {
                        isAddingComment = true
                        await addComment(ticket: ticket)
                        isAddingComment = false
                    }
                }
                .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
            }

            // Notify options
            VStack(alignment: .leading, spacing: 4) {
                Text("Notify:")
                    .appFont(.body)
                    .foregroundColor(.secondary)
                if let requestor = ticket.requestorName, !requestor.isEmpty {
                    Toggle("Requestor: \(requestor)", isOn: $notifyRequestor)
                        .toggleStyle(.checkbox)
                        .appFont(.body)
                }
                if let responsible = ticket.responsibleFullName, !responsible.isEmpty,
                   ticket.responsibleUid != ticket.requestorUid {
                    Toggle("Responsible: \(responsible)", isOn: $notifyResponsible)
                        .toggleStyle(.checkbox)
                        .appFont(.body)
                }
                if let group = ticket.responsibleGroupName, !group.isEmpty {
                    Toggle("Group: \(group)", isOn: $notifyGroup)
                        .toggleStyle(.checkbox)
                        .appFont(.body)
                }
            }
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .appFont(.headline)
                Spacer()
                Picker("", selection: $feedFilter) {
                    Text("Comments").tag(FeedFilterType.comments)
                    Text("Edits").tag(FeedFilterType.edits)
                    Text("Status").tag(FeedFilterType.statusChanges)
                    Text("All").tag(FeedFilterType.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
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
                    FeedEntryRow(entry: entry) { text, isPrivate in
                        guard let entryId = entry.id else { return }
                        try await replyToFeedEntry(feedEntryId: entryId, replyText: text, isPrivate: isPrivate)
                    }
                }
            }
        }
    }

    // MARK: - Date Range Helpers

    private var activeDateRange: (from: Date, to: Date) {
        if datePreset == .custom {
            return (customDateFrom, customDateTo)
        }
        return datePreset.dateRange()
    }

    private var dateRangeLabel: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        let range = activeDateRange
        return "\(fmt.string(from: range.from)) – \(fmt.string(from: range.to))"
    }

    private var isTermPreset: Bool {
        if case .term = datePreset { return true }
        return false
    }

    private var isLastTermPreset: Bool {
        if case .term(let t, let y) = datePreset {
            let cal = Calendar.current
            let now = Date()
            let month = cal.component(.month, from: now)
            let year = cal.component(.year, from: now)
            let lastTerm: AcademicTerm
            let lastYear: Int
            if month >= 1 && month <= 4 {
                lastTerm = .fall; lastYear = year - 1
            } else if month >= 5 && month <= 8 {
                lastTerm = .spring; lastYear = year
            } else {
                lastTerm = .summer; lastYear = year
            }
            return t == lastTerm && y == lastYear
        }
        return false
    }

    private var isDefaultDatePreset: Bool {
        if case .term(let t, let y) = datePreset {
            let cal = Calendar.current
            let now = Date()
            let month = cal.component(.month, from: now)
            let year = cal.component(.year, from: now)
            let currentTerm: AcademicTerm
            if month >= 1 && month <= 4 { currentTerm = .spring }
            else if month >= 5 && month <= 8 { currentTerm = .summer }
            else { currentTerm = .fall }
            return t == currentTerm && y == year
        }
        return false
    }

    private func resetToCurrentTerm() {
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        if month >= 1 && month <= 4 { termSeason = .spring }
        else if month >= 5 && month <= 8 { termSeason = .summer }
        else { termSeason = .fall }
        termYear = year
        datePreset = .term(termSeason, termYear)
        loadTickets()
    }

    private func setLastTerm() {
        let cal = Calendar.current
        let now = Date()
        let month = cal.component(.month, from: now)
        let year = cal.component(.year, from: now)
        if month >= 1 && month <= 4 {
            // Current is Spring → last term is Fall of previous year
            termSeason = .fall
            termYear = year - 1
        } else if month >= 5 && month <= 8 {
            // Current is Summer → last term is Spring same year
            termSeason = .spring
            termYear = year
        } else {
            // Current is Fall → last term is Summer same year
            termSeason = .summer
            termYear = year
        }
        datePreset = .term(termSeason, termYear)
        loadTickets()
    }

    // MARK: - Data Loading

    private func loadTickets() {
        guard appState.config.isTdxConfigured else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let range = activeDateRange
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                var searchRequest = TicketSearchRequest(
                    createdDateFrom: formatter.string(from: range.from),
                    createdDateTo: formatter.string(from: range.to),
                    maxResults: 5000
                )
                if let groupId = appState.config.tdxResponsibleGroupId {
                    searchRequest.responsibleGroupIds = [groupId]
                }
                let fetchedTickets = try await appState.tdxService.searchTickets(search: searchRequest, maxResults: 5000)
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

    private func loadForms() async {
        do {
            allForms = try await appState.tdxService.getForms()
        } catch {
            print("Failed to load forms: \(error)")
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
        editTypeId = ticket.typeId
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
        notifyNewResponsible = true
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
            || editTypeId != ticket.typeId
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

                let changes: [String: Any] = [
                    "Description": htmlDesc,
                    "IsRichHtml": true
                ]

                if let updated = try await appState.tdxService.updateTicket(id: ticketId, updates: changes) {
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
                // Fetch fresh ticket to compare against
                let freshTicket = try await appState.tdxService.getTicket(id: ticketId) ?? ticket

                // Build a dictionary of ONLY the fields that actually changed
                var changes: [String: Any] = [:]

                let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let origTitle = (freshTicket.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTitle.isEmpty && trimmedTitle != origTitle {
                    changes["Title"] = trimmedTitle
                }
                if editStatusId != freshTicket.statusId {
                    changes["StatusID"] = editStatusId as Any
                }
                if editPriorityId != freshTicket.priorityId {
                    changes["PriorityID"] = editPriorityId as Any
                }
                if editClassification != freshTicket.classification {
                    changes["Classification"] = editClassification as Any
                }
                if editTypeId != freshTicket.typeId {
                    changes["TypeID"] = editTypeId as Any
                }
                if editRequestorUid != freshTicket.requestorUid {
                    changes["RequestorUid"] = editRequestorUid as Any
                }
                if editResponsibleUid != freshTicket.responsibleUid {
                    changes["ResponsibleUid"] = editResponsibleUid as Any
                }
                if editResponsibleGroupId != freshTicket.responsibleGroupId {
                    changes["ResponsibleGroupID"] = editResponsibleGroupId as Any
                }
                if editServiceId != freshTicket.serviceId {
                    changes["ServiceID"] = editServiceId as Any
                }
                if editFormId != freshTicket.formId {
                    changes["FormID"] = editFormId as Any
                }

                guard !changes.isEmpty else {
                    hasEdits = false
                    return
                }

                let shouldNotify = notifyNewResponsible && editResponsibleUid != freshTicket.responsibleUid

                if let updated = try await appState.tdxService.updateTicket(id: ticketId, updates: changes, notifyNewResponsible: shouldNotify) {
                    detailedTicket = updated
                    populateEditFields(from: updated)
                    saveSucceeded = true
                    loadTickets()
                    loadTicketDetail(ticketId: ticketId)
                    try? await Task.sleep(for: .seconds(2))
                    saveSucceeded = false
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
                .appFont(.headline)
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
            newComment = ""
            loadTicketFeed(ticketId: ticket.id ?? 0)
        } catch {
            saveErrorMessage = "Comment failed: \(error.localizedDescription)"
        }
    }

    /// Reply to a specific feed entry (threaded comment)
    private func replyToFeedEntry(feedEntryId: Int, replyText: String, isPrivate: Bool) async throws {
        _ = try await appState.tdxService.replyToFeedEntry(
            feedEntryId: feedEntryId,
            comment: replyText,
            isPrivate: isPrivate
        )
        if let ticketId = selectedTicket?.id {
            loadTicketFeed(ticketId: ticketId)
        }
    }

    // MARK: - Board Drag-and-Drop

    /// Handle a card drop on a board column — updates the field corresponding to the current groupBy
    private func handleBoardDrop(ticketId: Int, targetColumnKey: String) {
        Task {
            do {
                var changes: [String: Any] = [:]
                switch boardGroupBy {
                case .status:
                    guard let newStatusId = Int(targetColumnKey) else { return }
                    changes["StatusID"] = newStatusId
                case .priority:
                    let targetId = filteredTickets.first(where: { $0.priorityName == targetColumnKey })?.priorityId
                    guard let newPriorityId = targetId else { return }
                    changes["PriorityID"] = newPriorityId
                case .responsible:
                    if targetColumnKey == "Unassigned" {
                        changes["ResponsibleUid"] = ""
                    } else {
                        let targetUid = filteredTickets.first(where: { $0.responsibleFullName == targetColumnKey })?.responsibleUid
                        guard let newUid = targetUid else { return }
                        changes["ResponsibleUid"] = newUid
                    }
                case .group:
                    if targetColumnKey == "No Group" {
                        changes["ResponsibleGroupID"] = 0
                    } else {
                        let targetId = filteredTickets.first(where: { $0.responsibleGroupName == targetColumnKey })?.responsibleGroupId
                        guard let newGroupId = targetId else { return }
                        changes["ResponsibleGroupID"] = newGroupId
                    }
                }
                _ = try await appState.tdxService.updateTicket(id: ticketId, updates: changes)
                loadTickets()
            } catch {
                print("Failed to update ticket via board drop: \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Apply "me mode" — default group filter from config, default Responsible to self when SSO'd
    private func applyMeMode() {
        // Default group filter (always, regardless of SSO)
        if !filters.isActive(.group),
           let configGroupId = appState.config.tdxResponsibleGroupId,
           !tickets.isEmpty {
            let groupMatch = tickets.first(where: { $0.responsibleGroupId == configGroupId })?.responsibleGroupName
            if let groupMatch = groupMatch {
                filters.selectedValues[.group] = [groupMatch]
            }
        }

        // Default responsible filter to self (SSO only, once). Deliberately not
        // keyed off `tdxMe`: that resolves for everyone, and switching this on
        // would silently narrow the queue from the whole group to one person.
        guard !meModeApplied,
              appState.tdxSsoAuthenticated,
              let userName = appState.tdxAuthenticatedUserName,
              !tickets.isEmpty else { return }

        let allResponsible = filters.availableValues[.responsible] ?? []
        let match = allResponsible.first { option in
            option.localizedCaseInsensitiveContains(userName) ||
            userName.localizedCaseInsensitiveContains(option)
        }

        if let match = match {
            filters.selectedValues[.responsible] = [match]
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
    case edits = "Edits"
    case statusChanges = "Status Changes"
    case all = "All"
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .appFont(.body)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .appFont(.body)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Feed Entry Row

struct FeedEntryRow: View {
    let entry: TdxFeedEntry
    /// Posts a threaded reply to this entry. Throws so the row can show why a
    /// reply didn't land instead of quietly clearing the box.
    var onReply: ((String, Bool) async throws -> Void)? = nil

    @State private var isReplying = false
    @State private var replyText = ""
    @State private var isReplyPrivate = false
    @State private var isSendingReply = false
    @State private var replyError: String?

    private var canReply: Bool { onReply != nil && entry.id != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(entry.createdFullName ?? "Unknown")
                    .appFont(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if entry.isPrivate == true {
                    Text("Private")
                        .appFont(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                if let dateStr = entry.createdDate, let date = TicketsView.parseDate(dateStr) {
                    Text(formatRelativeDate(date))
                        .appFont(.callout)
                        .foregroundColor(.secondary)
                }
                if canReply {
                    Button(action: {
                        isReplying.toggle()
                        if isReplying {
                            isReplyPrivate = entry.isPrivate == true
                            replyError = nil
                        }
                    }) {
                        Image(systemName: isReplying ? "xmark" : "arrowshape.turn.up.left")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isReplying ? "Cancel reply" : "Reply in thread")
                }
                Button(action: { copyEntryToClipboard() }) {
                    Image(systemName: "doc.on.doc")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }

            if let body = entry.body, !body.isEmpty {
                Text(TicketsView.decodeHtml(body))
                    .appFont(.body)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }

            // Threaded replies from API
            if !entry.replyList.isEmpty {
                let replies = entry.replyList
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(replies, id: \.id) { reply in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.4))
                                .frame(width: 2)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(reply.createdFullName ?? "Unknown")
                                        .appFont(.callout)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if let dateStr = reply.createdDate, let date = TicketsView.parseDate(dateStr) {
                                        Text(formatRelativeDate(date))
                                            .appFont(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Button(action: { copyReplyToClipboard(reply) }) {
                                        Image(systemName: "doc.on.doc")
                                            .appFont(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy to clipboard")
                                }
                                if let body = reply.body, !body.isEmpty {
                                    Text(TicketsView.decodeHtml(body))
                                        .appFont(.callout)
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(.top, 4)
            }

            if isReplying {
                replyComposer
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $replyText)
                .appFont(.callout)
                .frame(height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )

            if let replyError {
                Text(replyError)
                    .appFont(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Toggle("Private", isOn: $isReplyPrivate)
                    .toggleStyle(.checkbox)
                    .appFont(.caption)
                Spacer()
                if isSendingReply {
                    ProgressView().controlSize(.small)
                }
                Button("Reply", action: sendReply)
                    .controlSize(.small)
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingReply)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 8)
    }

    private func sendReply() {
        guard let onReply else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            isSendingReply = true
            replyError = nil
            defer { isSendingReply = false }
            do {
                try await onReply(text, isReplyPrivate)
                replyText = ""
                isReplying = false
            } catch {
                replyError = "Reply failed: \(error.localizedDescription)"
            }
        }
    }

    private func copyEntryToClipboard() {
        let name = entry.createdFullName ?? "Unknown"
        let date = entry.createdDate ?? ""
        let body = TicketsView.decodeHtml(entry.body ?? "")
        let text = "\(name) (\(date)):\n\(body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyReplyToClipboard(_ reply: TdxFeedEntry) {
        let name = reply.createdFullName ?? "Unknown"
        let date = reply.createdDate ?? ""
        let body = TicketsView.decodeHtml(reply.body ?? "")
        let text = "\(name) (\(date)):\n\(body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                .appFont(.body)
        }
    }
}

// MARK: - View Mode Pill Toggle

/// Thin wrapper preserving the existing call site; the control itself now lives
/// in SegmentedPill so Projects renders an identical one.
struct ViewModePill: View {
    @Binding var selection: TicketViewMode

    var body: some View {
        SegmentedPill(
            selection: $selection,
            options: [.table, .board],
            label: { $0 == .table ? "List" : "Board" }
        )
    }
}

// MARK: - Column Resize Handle

struct TicketColumnResizeHandle: View {
    let field: TicketSortField
    @Binding var columnWidths: [TicketSortField: CGFloat]
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.5 : 0.25))
            .frame(width: isDragging ? 2 : 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4.5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startWidth = columnWidths[field] ?? 100
                        }
                        columnWidths[field] = max(40, startWidth + value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        startWidth = 0
                    }
            )
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .frame(width: 10)
    }
}

#Preview {
    TicketsView()
        .environmentObject(AppState())
}

