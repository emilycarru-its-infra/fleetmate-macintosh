import SwiftUI
import FleetMateCore

enum IdentityTab: String, CaseIterable {
    case groups = "Groups"
    case users = "Users"
}

/// How many `Devices-` groups to pull.
///
/// One constant because three call sites used to disagree — the launch preload
/// fetched 100 while the view's own refresh asked for 999. The preload won, since
/// it populated the cache first and left it valid, so the list silently capped at
/// "100 of 100" no matter what the view requested.
enum DeviceGroupFetch {
    static let limit = 1000
}

struct IdentityView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: IdentityTab = .groups

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch selectedTab {
            case .groups:
                GroupsContentView()
                    .environmentObject(appState)
            case .users:
                UsersContentView()
                    .environmentObject(appState)
            }
        }
        // The Groups/Users switcher belongs in the window toolbar, like the view
        // pickers in Tickets and Projects. Inline it rendered as a flat blue
        // segmented control next to a large "Identity" heading — the only tab
        // still repeating its own name in the body, which the tab bar already
        // shows.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SegmentedPill(
                    selection: $selectedTab,
                    options: IdentityTab.allCases,
                    label: { $0.rawValue },
                    segmentWidth: 62
                )
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
    @State private var loadingGroupIds: Set<String> = []

    var groups: [EntraGroup] { appState.cachedGroups }

    /// Members live on AppState so the preload warms them and tab switches
    /// don't throw them away.
    private var groupDevices: [String: [EntraDevice]] { appState.cachedGroupMembers }

    /// Matches on group name OR member device name — the member cache is warm
    /// from the launch preload, so searching "ALLAGUO" surfaces every group
    /// that Mac belongs to.
    var filteredGroups: [EntraGroup] {
        if searchText.isEmpty { return groups }
        return groups.filter { group in
            if group.displayName?.localizedCaseInsensitiveContains(searchText) ?? false {
                return true
            }
            let members = appState.cachedGroupMembers[group.id ?? ""] ?? []
            return members.contains {
                $0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .onAppCommand { command in
            if command == .refresh { loadDeviceGroups() }
        }
        .searchable(text: $searchText, prompt: "Filter groups…")
        .findFocusesSearchField()
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if !groups.isEmpty {
                    Text("\(filteredGroups.count) of \(groups.count)")
                        .appFont(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Button(action: loadDeviceGroups) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
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
                let fetchedGroups = try await appState.graphService.searchGroups("Devices-", limit: DeviceGroupFetch.limit)
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
                appState.cachedGroupMembers[groupId] = devices
            } catch {
                appState.errorMessage = "Failed to load group members: \(error.localizedDescription)"
                appState.cachedGroupMembers[groupId] = []
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
        // Entra is queried on submit rather than per keystroke, so the field
        // keeps its Return-to-search behaviour now that it lives in the toolbar.
        .searchable(text: $searchText, prompt: "Search users…")
        .findFocusesSearchField()
        .onSubmit(of: .search) { searchUser() }
        .onAppCommand { command in
            // Entra is queried on demand, so a refresh re-runs the current
            // search rather than reloading a cache there isn't one of.
            if command == .refresh { searchUser() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isLoading { ProgressView().controlSize(.small) }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
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
