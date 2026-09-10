import SwiftUI
import AppKit
import FleetMateCore

/// Add machines to a custom group (new or existing) from the roster, from
/// a pasted or imported list, or by typing an address.
struct AddDeviceSheet: View {
    @ObservedObject var manage: ManageState
    @Binding var isPresented: Bool
    let preferredMode: Mode
    let forceNewGroup: Bool

    enum Mode: String, CaseIterable {
        case roster = "Browse Roster"
        case list = "Paste List"
        case manual = "Enter Address"
    }

    enum GroupTarget: Hashable {
        case newGroup
        case existingGroup(UUID)
    }

    @State private var mode: Mode = .roster
    @State private var search = ""
    @State private var checkedKeys: Set<String> = []
    @State private var newGroupName = ""
    @State private var manualHostname = ""
    @State private var manualIP = ""
    @State private var pastedList = ""
    @State private var groupTarget: GroupTarget = .newGroup

    init(manage: ManageState, isPresented: Binding<Bool>, preferredMode: Mode = .roster, forceNewGroup: Bool = false) {
        self.manage = manage
        self._isPresented = isPresented
        self.preferredMode = preferredMode
        self.forceNewGroup = forceNewGroup
    }

    private var targetGroupID: UUID? {
        if case .existingGroup(let id) = groupTarget { return id }
        return nil
    }

    private var alreadyInGroup: Set<String> {
        guard let id = targetGroupID, let group = manage.customGroups.first(where: { $0.id == id }) else { return [] }
        return Set(group.devices.map { $0.hostname.lowercased() })
    }

    private var filteredComputers: [RosterComputer] {
        let pool = manage.roster.sourceComputers
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return pool }
        return pool.filter {
            $0.hostname.localizedCaseInsensitiveContains(q)
                || $0.allocation.localizedCaseInsensitiveContains(q)
                || $0.serial.localizedCaseInsensitiveContains(q)
                || $0.username.localizedCaseInsensitiveContains(q)
                || $0.location.localizedCaseInsensitiveContains(q)
                || $0.area.localizedCaseInsensitiveContains(q)
                || $0.fleet.localizedCaseInsensitiveContains(q)
        }
    }

    private var needsGroupName: Bool {
        guard case .newGroup = groupTarget else { return false }
        return newGroupName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var parsedList: [(hostname: String, ip: String)] {
        pastedList
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { token in
                let parts = token.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                if parts.count >= 2, Self.looksLikeIPv4(parts[1]) { return (parts[0], parts[1]) }
                if Self.looksLikeIPv4(parts[0]) { return ("", parts[0]) }
                return (parts[0], "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Machines").appFont(.headline)
                    Text(destinationLabel).appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            if !manage.customGroups.isEmpty {
                Picker("Add to", selection: $groupTarget) {
                    Text("New group").tag(GroupTarget.newGroup)
                    ForEach(manage.customGroups) { group in
                        Text(group.name).tag(GroupTarget.existingGroup(group.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            if case .newGroup = groupTarget {
                HStack(spacing: 8) {
                    Text("Group name").appFont(.subheadline).foregroundStyle(.secondary)
                    TextField("e.g. Loaner laptops", text: $newGroupName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            switch mode {
            case .roster: rosterTab
            case .list: listTab
            case .manual: manualTab
            }
        }
        .frame(width: 480, height: 580)
        .onAppear {
            mode = preferredMode
            if !forceNewGroup, let current = manage.primaryGroup {
                groupTarget = .existingGroup(current.id)
            }
        }
    }

    private var destinationLabel: String {
        switch groupTarget {
        case .newGroup: "Creates a new custom group"
        case .existingGroup(let id): "Adding to \"\(manage.customGroups.first { $0.id == id }?.name ?? "group")\""
        }
    }

    // MARK: - Roster

    private var rosterTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).appFont(fixed: 12)
                TextField("Search hostnames, people, rooms, fleets…", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(filteredComputers) { computer in
                let inGroup = alreadyInGroup.contains(computer.hostname.lowercased())
                let checked = checkedKeys.contains(computer.id)
                HStack(spacing: 10) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                        .appFont(fixed: 15)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(computer.displayName)
                            .appFont(.body)
                            .foregroundStyle(inGroup ? Color.secondary : Color.primary)
                        Text([computer.allocation == computer.displayName ? "" : computer.allocation, computer.location, computer.fleet.isEmpty ? computer.catalog : computer.fleet]
                            .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if inGroup {
                        Text("already added")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !inGroup else { return }
                    if checked { checkedKeys.remove(computer.id) } else { checkedKeys.insert(computer.id) }
                }
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Button("Select All in View") {
                    for c in filteredComputers where !alreadyInGroup.contains(c.hostname.lowercased()) {
                        checkedKeys.insert(c.id)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(filteredComputers.isEmpty)
                Spacer()
                if !checkedKeys.isEmpty {
                    Text("\(checkedKeys.count) selected").appFont(.caption).foregroundStyle(.secondary)
                }
                Button(targetGroupID != nil ? "Add to Group" : "Create Group") { commitRoster() }
                    .buttonStyle(.borderedProminent)
                    .disabled(checkedKeys.isEmpty || needsGroupName)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Pasted list

    private var listTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One machine per line: a hostname, an address, or both separated by a space or tab. Commas work too.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            TextEditor(text: $pastedList)
                .appFont(.footnote, design: .monospaced)
                .padding(.horizontal, 20)

            HStack {
                Button("Import File…") { importFile() }
                Spacer()
                Text("\(parsedList.count) machine\(parsedList.count == 1 ? "" : "s")")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Button(targetGroupID != nil ? "Add to Group" : "Create Group") { commitList() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedList.isEmpty || needsGroupName)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Manual

    private var manualTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Group {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Address").appFont(.caption).foregroundStyle(.secondary)
                    TextField("e.g. 10.17.0.42", text: $manualIP).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hostname (optional)").appFont(.caption).foregroundStyle(.secondary)
                    TextField("Optional", text: $manualHostname).textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 40)
            Spacer()
            Divider()
            HStack {
                Button("Add to Current View Only") {
                    manage.addAdhocComputer(hostname: manualHostname.trimmingCharacters(in: .whitespaces), ip: manualIP.trimmingCharacters(in: .whitespaces))
                    isPresented = false
                }
                .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty || !manage.hasSelection)
                .help("Adds the machine to what is on screen without saving it to a group")
                Spacer()
                Button(targetGroupID != nil ? "Add to Group" : "Create Group") { commitManual() }
                    .buttonStyle(.borderedProminent)
                    .disabled((manualIP.trimmingCharacters(in: .whitespaces).isEmpty && manualHostname.trimmingCharacters(in: .whitespaces).isEmpty) || needsGroupName)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Actions

    private func resolveOrCreateGroupID() -> UUID? {
        switch groupTarget {
        case .existingGroup(let id): return id
        case .newGroup:
            let name = newGroupName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return manage.createCustomGroup(name: name)
        }
    }

    private func finish(groupID: UUID) {
        if case .newGroup = groupTarget, let group = manage.customGroups.first(where: { $0.id == groupID }) {
            manage.selectGroup(group)
        }
        isPresented = false
    }

    private func commitRoster() {
        guard let groupID = resolveOrCreateGroupID() else { return }
        for c in filteredComputers where checkedKeys.contains(c.id) && !alreadyInGroup.contains(c.hostname.lowercased()) {
            manage.addDevice(toGroupID: groupID, hostname: c.hostname, ip: manage.ipFor(c) ?? "", serial: c.serial)
        }
        finish(groupID: groupID)
    }

    private func commitList() {
        guard let groupID = resolveOrCreateGroupID() else { return }
        for entry in parsedList {
            manage.addDevice(toGroupID: groupID, hostname: entry.hostname, ip: entry.ip)
        }
        finish(groupID: groupID)
    }

    private func commitManual() {
        guard let groupID = resolveOrCreateGroupID() else { return }
        manage.addDevice(toGroupID: groupID,
                         hostname: manualHostname.trimmingCharacters(in: .whitespaces),
                         ip: manualIP.trimmingCharacters(in: .whitespaces))
        finish(groupID: groupID)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import a list of machines"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // A CSV with a header keeps only its first two columns.
        let lines = text.components(separatedBy: .newlines)
        let body = lines.first.map { $0.lowercased().contains("hostname") || $0.lowercased().contains("serial") } == true
            ? Array(lines.dropFirst()) : lines
        pastedList = body.joined(separator: "\n")
    }

    static func looksLikeIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
