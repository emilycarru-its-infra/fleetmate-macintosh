import SwiftUI
import FleetMateCore

/// Pick several labs at once, grouped by area, for a multi-room target set.
struct LabPickerSheet: View {
    @ObservedObject var manage: ManageState
    @Binding var isPresented: Bool

    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""

    private struct AreaGroup: Identifiable {
        var id: String { name }
        let name: String
        let rooms: [RosterRoom]
        var computerCount: Int { rooms.reduce(0) { $0 + $1.count } }
    }

    private var areaGroups: [AreaGroup] {
        let grouped = Dictionary(grouping: manage.roster.labs) { room in
            let area = room.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return area.isEmpty ? "Other" : area
        }
        return grouped
            .map { AreaGroup(name: $0.key, rooms: $0.value.sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filteredAreaGroups: [AreaGroup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return areaGroups }
        return areaGroups.compactMap { group in
            if group.name.localizedCaseInsensitiveContains(q) { return group }
            let rooms = group.rooms.filter {
                $0.number.localizedCaseInsensitiveContains(q) || ($0.displayName?.localizedCaseInsensitiveContains(q) ?? false)
            }
            return rooms.isEmpty ? nil : AreaGroup(name: group.name, rooms: rooms)
        }
    }

    private var selectedRooms: [RosterRoom] {
        manage.roster.labs.filter { selectedIDs.contains($0.id) }
            .sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
    }

    private var selectedComputerCount: Int { selectedRooms.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).appFont(fixed: 12)
                TextField("Filter areas or labs", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            HStack(spacing: 8) {
                Button("All") { selectedIDs = Set(manage.roster.labs.map(\.id)) }.buttonStyle(.borderless)
                Button("Visible") { selectedIDs.formUnion(filteredAreaGroups.flatMap { $0.rooms.map(\.id) }) }
                    .buttonStyle(.borderless)
                    .disabled(filteredAreaGroups.isEmpty)
                Button("Clear") { selectedIDs = [] }.buttonStyle(.borderless).disabled(selectedIDs.isEmpty)
                Spacer()
                Text("\(selectedIDs.count) labs · \(selectedComputerCount) machines")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HSplitView {
                List {
                    ForEach(filteredAreaGroups) { group in
                        Section {
                            areaRow(group)
                            ForEach(group.rooms) { room in labRow(room) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 280, idealWidth: 340)

                VStack(spacing: 0) {
                    List(selectedRooms) { room in selectedLabRow(room) }
                        .listStyle(.inset)
                        .overlay {
                            if selectedRooms.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "tray").appFont(fixed: 22).foregroundStyle(.secondary)
                                    Text("No labs selected").appFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    Divider()
                    HStack {
                        Text("Selection").appFont(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        CountBadge(value: selectedComputerCount)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(minWidth: 240, idealWidth: 280)
            }

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    manage.selectRooms(selectedIDs)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 680, height: 580)
        .onAppear { selectedIDs = manage.selection.roomIDs }
    }

    private func areaRow(_ group: AreaGroup) -> some View {
        HStack(spacing: 8) {
            Button { selectedIDs.formUnion(group.rooms.map(\.id)) } label: {
                Image(systemName: "plus.circle").appFont(fixed: 12)
            }
            .buttonStyle(.plain)
            .help("Add every lab in this area")
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).appFont(.body, weight: .semibold)
                Text("\(group.rooms.count) labs").appFont(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            CountBadge(value: group.computerCount)
        }
        .contentShape(Rectangle())
    }

    private func labRow(_ room: RosterRoom) -> some View {
        HStack(spacing: 8) {
            Button { toggle(room) } label: {
                Image(systemName: selectedIDs.contains(room.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selectedIDs.contains(room.id) ? Color.accentColor : Color(NSColor.tertiaryLabelColor))
                    .appFont(fixed: 12)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.number).appFont(.body, weight: .medium)
                if let displayName = room.displayName {
                    Text(displayName).appFont(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            CountBadge(value: room.count)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(room) }
    }

    private func selectedLabRow(_ room: RosterRoom) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.number).appFont(.body, weight: .medium)
                if let displayName = room.displayName {
                    Text(displayName).appFont(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            CountBadge(value: room.count)
            Button { selectedIDs.remove(room.id) } label: {
                Image(systemName: "minus.circle").appFont(fixed: 12).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }

    private func toggle(_ room: RosterRoom) {
        if selectedIDs.contains(room.id) { selectedIDs.remove(room.id) } else { selectedIDs.insert(room.id) }
    }
}
