import SwiftUI
import FleetMateCore

enum IdentityTab: String, CaseIterable {
    case groups = "Groups"
    case users = "Users"
}

struct IdentityView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: IdentityTab = .groups

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with inline tab toggle
            HStack {
                Text("Identity")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Picker("", selection: $selectedTab) {
                    Text("Groups").tag(IdentityTab.groups)
                    Text("Users").tag(IdentityTab.users)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Content
            switch selectedTab {
            case .groups:
                GroupsContentView()
                    .environmentObject(appState)
            case .users:
                UsersContentView()
                    .environmentObject(appState)
            }
        }
    }
}

/// Groups content (extracted from GroupsView, without its own header)
struct GroupsContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var expandedGroupIds: Set<String> = []
    @State private var groupDevices: [String: [EntraDevice]] = [:]
    @State private var loadingGroupIds: Set<String> = []

    var groups: [EntraGroup] { appState.cachedGroups }

    var filteredGroups: [EntraGroup] {
        if searchText.isEmpty { return groups }
        return groups.filter {
            $0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search/Filter + Refresh
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter groups...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if !groups.isEmpty {
                    Text("\(filteredGroups.count) of \(groups.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button(action: loadDeviceGroups) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            if !appState.config.isSystemsGraphConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Microsoft Graph (Systems) is not configured.")
                    )
                    Spacer()
                }
            } else if isLoading && appState.cachedGroups.isEmpty {
                VStack {
                    ProgressView("Loading device groups...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if groups.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No Device Groups",
                        systemImage: "person.3.sequence",
                        description: Text("No groups found with 'Devices-' prefix")
                    )
                    .padding(.top, 30)
                    Spacer()
                }
            } else if filteredGroups.isEmpty {
                VStack {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 30)
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredGroups) { group in
                        GroupDisclosureRow(
                            group: group,
                            isExpanded: expandedGroupIds.contains(group.id ?? ""),
                            isLoadingMembers: loadingGroupIds.contains(group.id ?? ""),
                            devices: groupDevices[group.id ?? ""] ?? [],
                            onToggle: { toggleGroup(group) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            if !appState.isGroupsCacheValid {
                loadDeviceGroups()
            }
        }
    }

    private func loadDeviceGroups() {
        guard appState.config.isSystemsGraphConfigured else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let fetchedGroups = try await appState.graphService.searchGroups("Devices-", limit: 100)
                appState.updateGroupsCache(fetchedGroups)
            } catch {
                appState.errorMessage = "Failed to load device groups: \(error.localizedDescription)"
            }
        }
    }

    private func toggleGroup(_ group: EntraGroup) {
        guard let groupId = group.id else { return }
        if expandedGroupIds.contains(groupId) {
            expandedGroupIds.remove(groupId)
        } else {
            expandedGroupIds.insert(groupId)
            if groupDevices[groupId] == nil {
                loadGroupMembers(group)
            }
        }
    }

    private func loadGroupMembers(_ group: EntraGroup) {
        guard let groupId = group.id else { return }
        Task {
            loadingGroupIds.insert(groupId)
            defer { loadingGroupIds.remove(groupId) }
            do {
                let devices = try await appState.graphService.getGroupDeviceMembers(groupId)
                groupDevices[groupId] = devices
            } catch {
                appState.errorMessage = "Failed to load group members: \(error.localizedDescription)"
                groupDevices[groupId] = []
            }
        }
    }
}

/// Users content (extracted from UsersView, without its own header)
struct UsersContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var searchResults: [EntraUser] = []
    @State private var isLoading = false
    @State private var selectedUser: EntraUser?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search by email or name...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { searchUser() }
                Button("Search") { searchUser() }
                    .disabled(searchText.isEmpty || isLoading)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            if !appState.config.isGraphConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Microsoft Graph is not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID in your config.")
                    )
                    Spacer()
                }
            } else if isLoading {
                VStack {
                    ProgressView("Searching...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if searchResults.isEmpty && !searchText.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "person.slash",
                        description: Text("No users found matching '\(searchText)'")
                    )
                    .padding(.top, 30)
                    Spacer()
                }
            } else if searchResults.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "Search for Users",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Enter an email address or name to search for users")
                    )
                    .padding(.top, 30)
                    Spacer()
                }
            } else {
                List(searchResults, id: \.id, selection: $selectedUser) { user in
                    UserRow(user: user)
                }
            }
        }
    }

    private func searchUser() {
        guard appState.config.isGraphConfigured, !searchText.isEmpty else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                // Try exact lookup first (for UPN or ID)
                if searchText.contains("@") || UUID(uuidString: searchText) != nil {
                    if let user = try await appState.graphService.getUser(searchText, includeGroups: true) {
                        searchResults = [user]
                        return
                    }
                }
                // Fuzzy search by display name / UPN prefix
                let users = try await appState.graphService.searchUsers(searchText, limit: 25)
                searchResults = users
            } catch {
                appState.errorMessage = "Failed to search users: \(error.localizedDescription)"
                searchResults = []
            }
        }
    }
}

#Preview {
    IdentityView()
        .environmentObject(AppState())
}
