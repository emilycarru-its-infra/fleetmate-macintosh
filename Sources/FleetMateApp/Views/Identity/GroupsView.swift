import SwiftUI
import FleetMateCore

struct GroupsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var expandedGroupIds: Set<String> = []
    @State private var groupDevices: [String: [EntraDevice]] = [:]
    @State private var loadingGroupIds: Set<String> = []
    
    // Use cached groups from appState
    var groups: [EntraGroup] { appState.cachedGroups }

    var filteredGroups: [EntraGroup] {
        if searchText.isEmpty {
            return groups
        }
        return groups.filter {
            $0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Device Groups")
                        .font(.largeTitle)
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
                        .font(.caption)
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
            // Load members if not already loaded
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

struct GroupDisclosureRow: View {
    let group: EntraGroup
    let isExpanded: Bool
    let isLoadingMembers: Bool
    let devices: [EntraDevice]
    let onToggle: () -> Void

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
                            .font(.headline)
                        if let description = group.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
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

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    
                    // Group ID with copy button
                    HStack {
                        Text("Group ID:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(group.id ?? "-")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button(action: {
                            if let id = group.id {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(id, forType: .string)
                            }
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
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
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 24)
                    } else if devices.isEmpty {
                        Text("No device members")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Members (\(devices.count))")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            ForEach(devices) { device in
                                DeviceMemberRow(device: device)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName ?? "-")
                    .font(.caption)
                    .textSelection(.enabled)
                
                HStack(spacing: 8) {
                    if let os = device.operatingSystem {
                        Text(os)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if device.isCompliant == true {
                        Label("Compliant", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if device.isCompliant == false {
                        Label("Non-compliant", systemImage: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    if device.isManaged == true {
                        Text("Managed")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.leading, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(4)
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
