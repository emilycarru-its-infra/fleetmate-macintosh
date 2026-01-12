import SwiftUI
import FleetMateCore

struct TicketsView: View {
    @EnvironmentObject var appState: AppState
    @State private var tickets: [TdxTicket] = []
    @State private var isLoading = false
    @State private var searchText = ""

    var filteredTickets: [TdxTicket] {
        if searchText.isEmpty {
            return tickets
        }
        return tickets.filter {
            ($0.title?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.requestorName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            "\($0.id ?? 0)".contains(searchText)
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
                    Text("TeamDynamix tickets")
                        .foregroundColor(.secondary)
                }
                Spacer()
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
                ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("TeamDynamix is not configured. Set TDX_BASE_URL and TDX_APP_ID in your config.")
                )
            } else if isLoading {
                ProgressView("Loading tickets...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTickets.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(filteredTickets) {
                    TableColumn("ID") { ticket in
                        Text("#\(ticket.id ?? 0)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Title") { ticket in
                        Text(ticket.title ?? "-")
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Status") { ticket in
                        TicketStatusBadge(statusName: ticket.statusName)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Priority") { ticket in
                        Text(ticket.priorityName ?? "-")
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Requestor") { ticket in
                        Text(ticket.requestorName ?? "-")
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Responsible") { ticket in
                        Text(ticket.responsibleFullName ?? "-")
                    }
                    .width(min: 120, ideal: 150)
                }
            }
        }
        .task {
            if tickets.isEmpty {
                loadTickets()
            }
        }
    }

    private func loadTickets() {
        guard appState.config.isTdxConfigured else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                tickets = try await appState.tdxService.searchTickets(maxResults: 100)
            } catch {
                appState.errorMessage = "Failed to load tickets: \(error.localizedDescription)"
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
