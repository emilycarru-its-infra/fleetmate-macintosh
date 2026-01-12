import SwiftUI
import FleetMateCore

struct GroupsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var groups: [EntraGroup] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Groups")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Entra ID groups")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search groups by name...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        searchGroups()
                    }
                Button("Search") {
                    searchGroups()
                }
                .disabled(searchText.isEmpty || isLoading)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if !appState.config.isGraphConfigured {
                ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("Microsoft Graph is not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID in your config.")
                )
            } else if isLoading {
                ProgressView("Searching groups...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty && !searchText.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "person.3.slash",
                    description: Text("No groups found matching '\(searchText)'")
                )
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "Search for Groups",
                    systemImage: "person.3.sequence",
                    description: Text("Enter a group name to search")
                )
            } else {
                Table(groups) {
                    TableColumn("Name") { group in
                        HStack {
                            Image(systemName: group.securityEnabled == true ? "shield.fill" : "person.3.fill")
                                .foregroundColor(.accentColor)
                            Text(group.displayName ?? "-")
                        }
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Description") { group in
                        Text(group.description ?? "-")
                            .lineLimit(2)
                    }
                    .width(min: 200, ideal: 400)

                    TableColumn("Type") { group in
                        GroupTypeBadge(group: group)
                    }
                    .width(min: 100, ideal: 150)
                }
            }
        }
    }

    private func searchGroups() {
        guard appState.config.isGraphConfigured, !searchText.isEmpty else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                groups = try await appState.graphService.searchGroups(searchText, limit: 50)
            } catch {
                appState.errorMessage = "Failed to search groups: \(error.localizedDescription)"
                groups = []
            }
        }
    }
}

struct GroupTypeBadge: View {
    let group: EntraGroup

    var body: some View {
        HStack(spacing: 4) {
            if group.securityEnabled == true {
                Text("Security")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
            }
            if group.mailEnabled == true {
                Text("Mail")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(4)
            }
            if let types = group.groupTypes, types.contains("Unified") {
                Text("M365")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
        }
    }
}

#Preview {
    GroupsView()
        .environmentObject(AppState())
}
