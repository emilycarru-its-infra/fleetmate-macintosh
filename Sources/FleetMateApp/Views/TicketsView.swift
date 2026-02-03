import SwiftUI
import FleetMateCore

enum TicketSortField: String, CaseIterable {
    case id = "ID"
    case title = "Title"
    case status = "Status"
    case priority = "Priority"
    case requestor = "Requestor"
}

struct TicketsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sortField: TicketSortField = .id
    @State private var sortAscending = false  // Default descending for ID (newest first)
    
    // Use cached tickets from appState
    var tickets: [TdxTicket] { appState.cachedTickets }

    var filteredTickets: [TdxTicket] {
        var result = tickets
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
                let aVal = a.id ?? 0
                let bVal = b.id ?? 0
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
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Tickets")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    if let groupId = appState.config.tdxResponsibleGroupId {
                        Text("TeamDynamix tickets for group \(groupId)")
                            .foregroundColor(.secondary)
                    } else {
                        Text("TeamDynamix tickets")
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                
                // SSO user info or login button
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
                
                Picker("Sort by", selection: $sortField) {
                    ForEach(TicketSortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                Button(action: { sortAscending.toggle() }) {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(sortAscending ? "Ascending" : "Descending")
                Button(action: loadTickets) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search tickets...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
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
                Table(filteredTickets) {
                    TableColumn("ID") { ticket in
                        Text("#\(ticket.id ?? 0)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Title") { ticket in
                        Text(ticket.title ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Status") { ticket in
                        TicketStatusBadge(statusName: ticket.statusName)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Priority") { ticket in
                        Text(ticket.priorityName ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Requestor") { ticket in
                        Text(ticket.requestorName ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Responsible") { ticket in
                        Text(ticket.responsibleFullName ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 120, ideal: 150)
                }
            }
        }
        .task {
            if !appState.isTicketsCacheValid {
                loadTickets()
            }
        }
        .sheet(isPresented: $appState.showTdxSsoLogin) {
            TdxSsoLoginView(config: appState.config) { result in
                if result.success, let token = result.token {
                    // Token expiry - default 23 hours (matching service account behavior)
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
            } catch {
                print("Failed to load tickets: \(error)")
                // Don't show error if not configured properly - the 400 error suggests empty search
            }
        }
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
                .font(.caption)
        }
    }
}

#Preview {
    TicketsView()
        .environmentObject(AppState())
}
