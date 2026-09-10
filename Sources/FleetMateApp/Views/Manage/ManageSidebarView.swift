import SwiftUI
import AppKit
import FleetMateCore

/// The roster sidebar: labs, kiosks, staff, faculty and custom groups. With
/// text in the search field it lists matching machines instead, and the
/// checked ones become a temporary target set.
struct ManageSidebarView: View {
    @ObservedObject var manage: ManageState
    @Binding var searchText: String

    @State private var checkedSearchIDs: Set<String> = []
    @State private var showCreateGroupSheet = false
    @State private var showLabPicker = false
    @State private var editingGroupID: UUID?
    @State private var editingGroupName = ""

    @AppStorage("manage.sidebar.labs") private var labsExpanded = true
    @AppStorage("manage.sidebar.kiosks") private var kiosksExpanded = false
    @AppStorage("manage.sidebar.staff") private var staffExpanded = false
    @AppStorage("manage.sidebar.faculty") private var facultyExpanded = false
    @AppStorage("manage.sidebar.groups") private var groupsExpanded = true

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var searchResults: [RosterComputer] { RosterSearch.matches(searchText, in: manage.roster) }

    var body: some View {
        VStack(spacing: 0) {
            if manage.isLoadingRoster {
                Spacer()
                ProgressView("Loading roster…")
                Spacer()
            } else if isSearching {
                searchResultsList
            } else {
                sectionsList
            }

            Divider()
            footer
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onChange(of: searchText) { _, _ in
            checkedSearchIDs = checkedSearchIDs.intersection(Set(searchResults.map(\.id)))
        }
        .sheet(isPresented: $showLabPicker) {
            LabPickerSheet(manage: manage, isPresented: $showLabPicker)
        }
        .sheet(isPresented: $showCreateGroupSheet) {
            AddDeviceSheet(manage: manage, isPresented: $showCreateGroupSheet, preferredMode: .roster, forceNewGroup: true)
        }
    }

    // MARK: - Search mode

    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if searchResults.isEmpty {
                    Text("No matches")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    HStack(spacing: 8) {
                        Text("\(searchResults.count) machine\(searchResults.count == 1 ? "" : "s")")
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("All") { checkedSearchIDs = Set(searchResults.map(\.id)) }
                            .appFont(.caption2)
                            .buttonStyle(.borderless)
                        Button("Clear") { checkedSearchIDs = [] }
                            .appFont(.caption2)
                            .buttonStyle(.borderless)
                            .disabled(checkedSearchIDs.isEmpty)
                        Button {
                            let chosen = searchResults.filter { checkedSearchIDs.contains($0.id) }
                            manage.selectSearchResults(chosen, label: searchText)
                        } label: {
                            Label("Use Selected", systemImage: "play.circle")
                        }
                        .appFont(.caption2)
                        .buttonStyle(.borderless)
                        .disabled(checkedSearchIDs.isEmpty)
                        .help("Open the checked machines as the target set")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    ForEach(searchResults) { computer in
                        SidebarDeviceRow(computer: computer, isChecked: checkedSearchIDs.contains(computer.id))
                            .onTapGesture {
                                if checkedSearchIDs.contains(computer.id) {
                                    checkedSearchIDs.remove(computer.id)
                                } else {
                                    checkedSearchIDs.insert(computer.id)
                                }
                            }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Sections

    private var sectionsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if manage.roster.labs.isEmpty && manage.roster.staff.isEmpty && manage.roster.faculty.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.manageWarning)
                        Text("No rooms found")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                        Text(manage.rosterError ?? "Check the roster path in Settings › Manage")
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .padding(.top, 24)
                }

                if !manage.roster.labs.isEmpty {
                    SidebarSectionHeader(title: "Curriculum", isExpanded: $labsExpanded) {
                        HStack(spacing: 6) {
                            Button { showLabPicker = true } label: {
                                Image(systemName: "checklist").appFont(fixed: 11)
                            }
                            .buttonStyle(.plain)
                            .help("Choose labs")
                            CountBadge(value: manage.roster.labs.reduce(0) { $0 + $1.count })
                        }
                    }
                    if labsExpanded { roomRows(manage.roster.labs, icon: "building.2") }
                }

                if !manage.roster.kiosks.isEmpty {
                    SidebarSectionHeader(title: "Kiosks", isExpanded: $kiosksExpanded) {
                        CountBadge(value: manage.roster.kiosks.reduce(0) { $0 + $1.count })
                    }
                    if kiosksExpanded { roomRows(manage.roster.kiosks, icon: "display") }
                }

                if !manage.roster.staff.isEmpty {
                    SidebarSectionHeader(title: "Staff", isExpanded: $staffExpanded) {
                        CountBadge(value: manage.roster.staff.reduce(0) { $0 + $1.count })
                    }
                    if staffExpanded { roomRows(manage.roster.staff, icon: "person.2") }
                }

                if !manage.roster.faculty.isEmpty {
                    SidebarSectionHeader(title: "Faculty", isExpanded: $facultyExpanded) {
                        CountBadge(value: manage.roster.faculty.reduce(0) { $0 + $1.count })
                    }
                    if facultyExpanded { roomRows(manage.roster.faculty, icon: "graduationcap") }
                }

                SidebarSectionHeader(title: "Custom Groups", isExpanded: $groupsExpanded) {
                    Button { showCreateGroupSheet = true } label: {
                        Image(systemName: "plus").appFont(fixed: 10)
                    }
                    .buttonStyle(.plain)
                    .help("New custom group")
                }
                if manage.customGroups.isEmpty {
                    Text("No groups yet")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }
                if groupsExpanded {
                    ForEach(manage.customGroups) { group in
                        if editingGroupID == group.id {
                            renameRow(group)
                        } else {
                            SidebarCustomGroupRow(
                                group: group,
                                isSelected: manage.selection.groupIDs.contains(group.id),
                                onTap: { manage.selectGroup(group, extending: extendSelection) },
                                onRename: { editingGroupName = group.name; editingGroupID = group.id },
                                onDelete: { manage.deleteCustomGroup(id: group.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func roomRows(_ rooms: [RosterRoom], icon: String) -> some View {
        ForEach(rooms) { room in
            SidebarRoomRow(room: room, icon: icon, isSelected: manage.selection.roomIDs.contains(room.id))
                .onTapGesture { manage.selectRoom(room, extending: extendSelection) }
        }
    }

    private func renameRow(_ group: CustomGroup) -> some View {
        HStack(spacing: 4) {
            TextField("Name", text: $editingGroupName)
                .textFieldStyle(.roundedBorder)
                .appFont(.subheadline)
                .onSubmit { commitRename(group) }
            Button { commitRename(group) } label: {
                Image(systemName: "checkmark").appFont(fixed: 10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func commitRename(_ group: CustomGroup) {
        let name = editingGroupName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { manage.renameCustomGroup(id: group.id, newName: name) }
        editingGroupID = nil
    }

    private var footer: some View {
        HStack {
            Text("\(manage.roster.labs.count) labs · \(manage.roster.allComputers.count) machines")
                .appFont(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button { manage.loadRoster() } label: {
                Image(systemName: "arrow.clockwise").appFont(fixed: 11)
            }
            .buttonStyle(.plain)
            .help("Reload the roster")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var extendSelection: Bool {
        NSEvent.modifierFlags.contains(.command)
    }
}

// MARK: - Rows

struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .appFont(fixed: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title.uppercased())
                    .appFont(.caption2, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SidebarRoomRow: View {
    let room: RosterRoom
    let icon: String
    let isSelected: Bool

    /// Area, room, and size: "Foundation · D3370 · 30 machines".
    private var subtitle: String {
        var parts: [String] = []
        if let area = room.displayName, !area.isEmpty { parts.append(area) }
        if let location = room.location, !location.isEmpty { parts.append(location) }
        parts.append(room.count == 1 ? "1 machine" : "\(room.count) machines")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .appFont(fixed: 11)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.number)
                    .appFont(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.manageSelection : Color.clear)
        .cornerRadius(5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

struct SidebarDeviceRow: View {
    let computer: RosterComputer
    let isChecked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? Color.accentColor : Color(NSColor.tertiaryLabelColor))
                .appFont(fixed: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.displayName).appFont(.body).lineLimit(1)
                Text(secondary)
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !computer.hasHostname {
                Text("no hostname")
                    .appFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isChecked ? Color.manageSelection : Color.clear)
        .cornerRadius(5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var secondary: String {
        var parts: [String] = []
        if !computer.allocation.isEmpty, computer.allocation != computer.displayName { parts.append(computer.allocation) }
        if !computer.location.isEmpty { parts.append(computer.location) }
        if parts.isEmpty { parts.append(computer.serial) }
        return parts.joined(separator: " · ")
    }
}

struct SidebarCustomGroupRow: View {
    let group: CustomGroup
    let isSelected: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(Color.manageWarning)
                .appFont(fixed: 11)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).appFont(.body).lineLimit(1)
                Text("\(group.devices.count) devices").appFont(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if isHovered {
                Button(action: onRename) {
                    Image(systemName: "pencil").appFont(fixed: 10)
                }
                .buttonStyle(.plain)
                .help("Rename")
                Button(action: onDelete) {
                    Image(systemName: "trash").appFont(fixed: 10).foregroundStyle(Color.manageFailure)
                }
                .buttonStyle(.plain)
                .help("Delete group")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.manageSelection : Color.clear)
        .cornerRadius(5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
    }
}
