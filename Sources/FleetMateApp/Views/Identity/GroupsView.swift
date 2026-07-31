import SwiftUI
import FleetMateCore

struct GroupsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var expandedGroupIds: Set<String> = []
    @State private var loadingGroupIds: Set<String> = []
    @State private var pendingRemoval: (group: EntraGroup, device: EntraDevice)?
    @State private var pendingRemediation: EntraGroup?
    @State private var addMemberTarget: EntraGroup?
    @State private var addMemberObjectId: String = ""
    
    // Use cached groups and members from appState — members are preloaded at
    // launch so expanding a group and searching by device are both instant.
    var groups: [EntraGroup] { appState.cachedGroups }
    var groupDevices: [String: [EntraDevice]] { appState.cachedGroupDevices }

    /// True when this group's own name doesn't match the search but one of its
    /// device members does — the search result the group is shown *for*.
    private func matchesByDevice(_ group: EntraGroup) -> Bool {
        guard !searchText.isEmpty, let id = group.id else { return false }
        return groupDevices[id]?.contains {
            $0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false
        } ?? false
    }

    var filteredGroups: [EntraGroup] {
        if searchText.isEmpty {
            return groups
        }
        // A device name is as valid a query as a group name: searching for an
        // Intune device surfaces every group it's a member of.
        return groups.filter {
            ($0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false)
                || matchesByDevice($0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Device Groups")
                        .appFont(.largeTitle)
                        .fontWeight(.bold)
                    Text("Entra ID device groups (Devices-*)")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: loadDeviceGroups) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search/Filter
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
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if !appState.config.isSystemsGraphConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Microsoft Graph (Systems) is not configured.")
                    )
                    Spacer()
                }
            } else if isLoading {
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
                        // A group found via one of its devices auto-expands so
                        // the device you searched for is visible in it.
                        GroupDisclosureRow(
                            group: group,
                            isExpanded: expandedGroupIds.contains(group.id ?? "") || matchesByDevice(group),
                            isLoadingMembers: loadingGroupIds.contains(group.id ?? ""),
                            devices: groupDevices[group.id ?? ""] ?? [],
                            highlightedDeviceFilter: matchesByDevice(group) ? searchText : nil,
                            onToggle: { toggleGroup(group) },
                            onRemoveMember: { device in pendingRemoval = (group, device) },
                            onDeployRemediation: { pendingRemediation = group },
                            onAddMember: { addMemberTarget = group; addMemberObjectId = "" }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            if !appState.isGroupsCacheValid {
                loadDeviceGroups()
            } else {
                // Groups may be cached from before members were preloaded.
                await appState.preloadGroupMembers()
            }
        }
        .alert("Remove from group?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { item in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                removeMember(group: item.group, device: item.device)
                pendingRemoval = nil
            }
        } message: { item in
            Text("Remove \(item.device.displayName ?? "this device") from \(item.group.displayName ?? "the group")?")
        }
        .alert("Deploy Cimian Push?", isPresented: Binding(
            get: { pendingRemediation != nil },
            set: { if !$0 { pendingRemediation = nil } }
        ), presenting: pendingRemediation) { group in
            Button("Cancel", role: .cancel) { pendingRemediation = nil }
            Button("Deploy") {
                deployRemediation(group: group)
                pendingRemediation = nil
            }
        } message: { group in
            Text("Deploy the Cimian push-trigger proactive remediation to \(group.displayName ?? "this group")? Targeted Windows devices will run a managed software update.")
        }
        .alert("Add Member", isPresented: Binding(
            get: { addMemberTarget != nil },
            set: { if !$0 { addMemberTarget = nil; addMemberObjectId = "" } }
        ), presenting: addMemberTarget) { group in
            TextField("Object id (user or device)", text: $addMemberObjectId)
            Button("Cancel", role: .cancel) { addMemberTarget = nil; addMemberObjectId = "" }
            Button("Add") {
                addMember(group: group, objectId: addMemberObjectId.trimmingCharacters(in: .whitespacesAndNewlines))
                addMemberTarget = nil
                addMemberObjectId = ""
            }
        } message: { group in
            Text("Enter the object id of the user or device to add to \(group.displayName ?? "the group").")
        }
    }

    private func addMember(group: EntraGroup, objectId: String) {
        guard let groupId = group.id, !objectId.isEmpty else {
            appState.errorMessage = "Group id or object id missing"
            return
        }
        Task {
            do {
                try await appState.graphService.addGroupMember(group: groupId, objectId: objectId)
                let devices = try await appState.graphService.getGroupDeviceMembers(groupId)
                appState.cachedGroupDevices[groupId] = devices
            } catch {
                appState.errorMessage = "Failed to add member: \(error.localizedDescription)"
            }
        }
    }

    private func deployRemediation(group: EntraGroup) {
        guard let groupId = group.id else {
            appState.errorMessage = "Group has no id"
            return
        }
        Task {
            do {
                let scriptId = try await appState.graphService.deployCimianPushRemediation(group: groupId)
                appState.errorMessage = "Deployed Cimian push remediation (script \(scriptId))"
            } catch {
                appState.errorMessage = "Failed to deploy remediation: \(error.localizedDescription)"
            }
        }
    }

    private func removeMember(group: EntraGroup, device: EntraDevice) {
        guard let groupId = group.id, let objectId = device.id else {
            appState.errorMessage = "Missing group or device id"
            return
        }
        Task {
            do {
                try await appState.graphService.removeGroupMember(group: groupId, objectId: objectId)
                // Refresh this group's member list.
                let devices = try await appState.graphService.getGroupDeviceMembers(groupId)
                appState.cachedGroupDevices[groupId] = devices
            } catch {
                appState.errorMessage = "Failed to remove member: \(error.localizedDescription)"
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
                await appState.preloadGroupMembers()
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
            // Load members if not already loaded
            if groupDevices[groupId] == nil {
                loadGroupMembers(group)
            }
        }
    }

    /// Fallback for a group whose members haven't landed in the launch
    /// preload yet — expanding it fetches on demand as before.
    private func loadGroupMembers(_ group: EntraGroup) {
        guard let groupId = group.id else { return }

        Task {
            loadingGroupIds.insert(groupId)
            defer { loadingGroupIds.remove(groupId) }

            do {
                let devices = try await appState.graphService.getGroupDeviceMembers(groupId)
                appState.cachedGroupDevices[groupId] = devices
            } catch {
                appState.errorMessage = "Failed to load group members: \(error.localizedDescription)"
                appState.cachedGroupDevices[groupId] = []
            }
        }
    }
}

struct GroupDisclosureRow: View {
    let group: EntraGroup
    let isExpanded: Bool
    let isLoadingMembers: Bool
    let devices: [EntraDevice]
    /// When the group was surfaced by a device-name search, the search text —
    /// matching member rows get highlighted so the hit is findable at a glance.
    var highlightedDeviceFilter: String? = nil
    let onToggle: () -> Void
    var onRemoveMember: (EntraDevice) -> Void = { _ in }
    var onDeployRemediation: () -> Void = {}
    var onAddMember: () -> Void = {}

    private func isHighlighted(_ device: EntraDevice) -> Bool {
        guard let filter = highlightedDeviceFilter, !filter.isEmpty else { return false }
        return device.displayName?.localizedCaseInsensitiveContains(filter) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header row
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    
                    Image(systemName: group.securityEnabled == true ? "shield.fill" : "person.3.fill")
                        .foregroundColor(.accentColor)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.displayName ?? "-")
                            .appFont(.headline)
                        if let description = group.description, !description.isEmpty {
                            Text(description)
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    GroupTypeBadge(group: group)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .contextMenu {
                Button("Add Member…") { onAddMember() }
                Button("Deploy Cimian Push Remediation…") { onDeployRemediation() }
            }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    
                    // Group ID with copy button
                    HStack {
                        Text("Group ID:")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                        Text(group.id ?? "-")
                            .appFont(.caption, design: .monospaced)
                            .textSelection(.enabled)
                        Button(action: {
                            if let id = group.id {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(id, forType: .string)
                            }
                        }) {
                            Image(systemName: "doc.on.doc")
                                .appFont(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Copy Group ID")
                    }
                    .padding(.leading, 24)

                    // Device members
                    if isLoadingMembers {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading members...")
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 24)
                    } else if devices.isEmpty {
                        Text("No device members")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Members (\(devices.count))")
                                .appFont(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            ForEach(devices) { device in
                                DeviceMemberRow(device: device, isHighlighted: isHighlighted(device))
                                    .contextMenu {
                                        Button("Remove from group", role: .destructive) {
                                            onRemoveMember(device)
                                        }
                                    }
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

struct DeviceMemberRow: View {
    let device: EntraDevice
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName ?? "-")
                    .appFont(.caption)
                    .textSelection(.enabled)
                
                HStack(spacing: 8) {
                    if let os = device.operatingSystem {
                        Text(os)
                            .appFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if device.isCompliant == true {
                        Label("Compliant", systemImage: "checkmark.circle.fill")
                            .appFont(.caption2)
                            .foregroundColor(.green)
                    } else if device.isCompliant == false {
                        Label("Non-compliant", systemImage: "xmark.circle.fill")
                            .appFont(.caption2)
                            .foregroundColor(.red)
                    }
                    if device.isManaged == true {
                        Text("Managed")
                            .appFont(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.leading, 8)
        .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private var deviceIcon: String {
        switch device.operatingSystem?.lowercased() {
        case "macos": return "desktopcomputer"
        case "ios", "ipados": return "iphone"
        case "windows": return "pc"
        case "android": return "apps.iphone"
        default: return "display"
        }
    }
}

struct GroupTypeBadge: View {
    let group: EntraGroup

    var body: some View {
        HStack(spacing: 4) {
            if group.securityEnabled == true {
                Text("Security")
                    .appFont(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
            }
            if group.mailEnabled == true {
                Text("Mail")
                    .appFont(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(4)
            }
            if let types = group.groupTypes, types.contains("Unified") {
                Text("M365")
                    .appFont(.caption2)
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
