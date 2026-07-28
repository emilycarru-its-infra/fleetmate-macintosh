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
                let fetchedGroups = try await appState.graphService.searchGroups("Devices-", limit: 999)
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
/// Contacts-style master/detail: a searchable user list on the left, the full
/// Entra profile inspector on the right.
struct UsersContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var searchResults: [EntraUser] = []
    @State private var isLoading = false
    @State private var selectedId: String?

    private func rowId(_ u: EntraUser) -> String {
        u.id ?? u.userPrincipalName ?? u.displayName ?? ""
    }

    private var selectedUser: EntraUser? {
        searchResults.first { rowId($0) == selectedId }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search users…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { searchUser() }
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(10)

            Divider()

            if !appState.config.isGraphConfigured {
                centered(ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("Microsoft Graph is not configured.")))
            } else if searchResults.isEmpty {
                centered(ContentUnavailableView(
                    searchText.isEmpty ? "Search for Users" : "No Results",
                    systemImage: searchText.isEmpty ? "person.crop.circle.badge.questionmark" : "person.slash",
                    description: Text(searchText.isEmpty
                        ? "Enter a name or email to search Entra."
                        : "No users match “\(searchText)”.")))
            } else {
                List(selection: $selectedId) {
                    ForEach(searchResults) { user in
                        UserSidebarRow(user: user).tag(rowId(user))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let user = selectedUser {
            EntraUserInspector(user: user)
                .id(rowId(user))
        } else {
            centered(ContentUnavailableView(
                "No User Selected",
                systemImage: "person.text.rectangle",
                description: Text("Select a user to see their full Entra profile.")))
        }
    }

    private func centered<C: View>(_ content: C) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchUser() {
        guard appState.config.isGraphConfigured, !searchText.isEmpty else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                if searchText.contains("@") || UUID(uuidString: searchText) != nil {
                    if let user = try await appState.graphService.getUser(searchText) {
                        searchResults = [user]
                        selectedId = rowId(user)
                        return
                    }
                }
                let users = try await appState.graphService.searchUsers(searchText, limit: 50)
                searchResults = users
                selectedId = users.first.map(rowId)
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
