import SwiftUI
import FleetMateCore

// MARK: - Compact sidebar row

/// A single row in the Users sidebar list (Contacts-style master column).
struct UserSidebarRow: View {
    let user: EntraUser

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle.fill")
                .appFont(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName ?? "Unknown")
                    .appFont(.body)
                    .lineLimit(1)
                Text(user.userPrincipalName ?? user.mail ?? "-")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(user.accountEnabled == false ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
                .help(user.accountEnabled == false ? "Disabled" : "Enabled")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Full Entra user inspector (right pane)

/// The full Entra user profile — mirrors the Azure portal user Properties view,
/// plus tabs for the user's devices and group memberships. The row passed in is
/// the lean search result; the full projection + manager + devices + groups are
/// fetched on appear.
struct EntraUserInspector: View {
    @EnvironmentObject var appState: AppState
    let user: EntraUser

    enum InspectorTab: Hashable { case properties, devices, groups }

    @State private var tab: InspectorTab = .properties
    @State private var full: EntraUser?
    @State private var manager: EntraUserRef?
    @State private var devices: [EntraDevice] = []
    @State private var groups: [EntraGroup] = []
    @State private var isLoading = true

    // Directory writes — each one is confirmed before it is sent.
    @State private var pendingAccountChange: Bool?
    @State private var groupToAdd = ""
    @State private var pendingAddGroup: String?
    @State private var pendingRemoveGroup: EntraGroup?
    @State private var isWriting = false
    @State private var writeError: String?

    private var u: EntraUser { full ?? user }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let writeError {
                Label(writeError, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            Divider()
            Picker("", selection: $tab) {
                Text("Properties").tag(InspectorTab.properties)
                Text("Devices").tag(InspectorTab.devices)
                Text("Groups").tag(InspectorTab.groups)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                switch tab {
                case .properties: properties
                case .devices:    devicesTab
                case .groups:     groupsTab
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: user.id) { await load() }
        .alert(pendingAccountChange == true ? "Enable account?" : "Disable account?",
               isPresented: Binding(
                   get: { pendingAccountChange != nil },
                   set: { if !$0 { pendingAccountChange = nil } }
               ),
               presenting: pendingAccountChange) { enable in
            Button("Cancel", role: .cancel) { pendingAccountChange = nil }
            Button(enable ? "Enable" : "Disable", role: enable ? nil : .destructive) {
                pendingAccountChange = nil
                Task { await setAccount(enabled: enable) }
            }
        } message: { enable in
            Text(enable
                 ? "\(userLabel) will be able to sign in again."
                 : "\(userLabel) will be unable to sign in.")
        }
        .alert("Add to group?", isPresented: Binding(
            get: { pendingAddGroup != nil },
            set: { if !$0 { pendingAddGroup = nil } }
        ), presenting: pendingAddGroup) { group in
            Button("Cancel", role: .cancel) { pendingAddGroup = nil }
            Button("Add") {
                pendingAddGroup = nil
                Task { await addToGroup(group) }
            }
        } message: { group in
            Text("Add \(userLabel) to \u{201C}\(group)\u{201D}?")
        }
        .alert("Remove from group?", isPresented: Binding(
            get: { pendingRemoveGroup != nil },
            set: { if !$0 { pendingRemoveGroup = nil } }
        ), presenting: pendingRemoveGroup) { group in
            Button("Cancel", role: .cancel) { pendingRemoveGroup = nil }
            Button("Remove", role: .destructive) {
                pendingRemoveGroup = nil
                Task { await removeFromGroup(group) }
            }
        } message: { group in
            Text("Remove \(userLabel) from \u{201C}\(group.displayName ?? "this group")\u{201D}?")
        }
    }

    private var userLabel: String {
        u.displayName ?? u.userPrincipalName ?? "This user"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 46))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(u.displayName ?? "Unknown")
                    .appFont(.title2).bold()
                Text(u.userPrincipalName ?? u.email)
                    .appFont(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                if let title = u.jobTitle {
                    Text(title).appFont(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                enabledBadge
                Button(u.accountEnabled == false ? "Enable Account" : "Disable Account") {
                    pendingAccountChange = u.accountEnabled == false
                }
                .controlSize(.small)
                .disabled(isWriting || full == nil)
                if isLoading || isWriting { ProgressView().controlSize(.small) }
            }
        }
        .padding()
    }

    private var enabledBadge: some View {
        let enabled = u.accountEnabled != false
        return Label(enabled ? "Enabled" : "Disabled",
                     systemImage: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundColor(enabled ? .green : .orange)
            .appFont(.callout)
    }

    // MARK: Properties (full Azure-style)

    private var properties: some View {
        VStack(alignment: .leading, spacing: 20) {
            propertySection("Identity", [
                ("Display name", u.displayName),
                ("First name", u.givenName),
                ("Last name", u.surname),
                ("User principal name", u.userPrincipalName),
                ("Object ID", u.id),
                ("User type", u.userType),
                ("Created date time", formatDate(u.createdDateTime)),
                ("Last password change", formatDate(u.lastPasswordChangeDateTime)),
                ("Password policies", u.passwordPolicies),
            ])
            propertySection("Job information", [
                ("Job title", u.jobTitle),
                ("Company name", u.companyName),
                ("Department", u.department),
                ("Employee ID", u.employeeId),
                ("Employee type", u.employeeType),
                ("Office location", u.officeLocation),
                ("Manager", manager?.displayName),
            ])
            propertySection("Contact information", [
                ("Email", u.mail),
                ("Other emails", u.otherMails?.joined(separator: ", ")),
                ("Mobile phone", u.mobilePhone),
                ("Business phones", u.businessPhones?.joined(separator: ", ")),
                ("Street address", u.streetAddress),
                ("City", u.city),
                ("State or province", u.state),
                ("ZIP or postal code", u.postalCode),
                ("Country or region", u.country),
                ("Proxy addresses", u.proxyAddresses?.joined(separator: "\n")),
            ])
            propertySection("Settings", [
                ("Account enabled", u.accountEnabled.map { $0 ? "Yes" : "No" }),
                ("Usage location", u.usageLocation),
                ("Preferred language", u.preferredLanguage),
            ])
            propertySection("On-premises", [
                ("Sync enabled", u.onPremisesSyncEnabled.map { $0 ? "Yes" : "No" }),
                ("Last sync date time", formatDate(u.onPremisesLastSyncDateTime)),
                ("Distinguished name", u.onPremisesDistinguishedName),
                ("SAM account name", u.onPremisesSamAccountName),
                ("Security identifier", u.onPremisesSecurityIdentifier),
                ("Immutable ID", u.onPremisesImmutableId),
                ("User principal name", u.onPremisesUserPrincipalName),
                ("Domain name", u.onPremisesDomainName),
            ])
        }
        .padding()
    }

    // MARK: Devices tab

    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if devices.isEmpty {
                emptyTab("No registered devices", "laptopcomputer.and.iphone")
            } else {
                ForEach(devices, id: \.id) { device in
                    HStack(spacing: 10) {
                        Image(systemName: deviceIcon(device.operatingSystem))
                            .foregroundColor(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.displayName ?? "Unknown").appFont(.body)
                            Text([device.operatingSystem, device.operatingSystemVersion]
                                .compactMap { $0 }.joined(separator: " "))
                                .appFont(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if device.isCompliant == true {
                            tagBadge("Compliant", .green)
                        } else if device.isCompliant == false {
                            tagBadge("Non-compliant", .orange)
                        }
                        if device.isManaged == true {
                            tagBadge("Managed", .secondary)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 7)
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Groups tab

    private var groupsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Group name or id…", text: $groupToAdd)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(requestAddGroup)
                Button("Add to Group", action: requestAddGroup)
                    .disabled(groupToAdd.trimmingCharacters(in: .whitespaces).isEmpty || isWriting || u.id == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            if groups.isEmpty {
                emptyTab("No group memberships", "person.2")
            } else {
                ForEach(groups, id: \.id) { group in
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.displayName ?? "Unknown").appFont(.body)
                            if let d = group.description, !d.isEmpty {
                                Text(d).appFont(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Remove") { pendingRemoveGroup = group }
                            .controlSize(.small)
                            .disabled(isWriting || group.id == nil || u.id == nil)
                    }
                    .padding(.horizontal).padding(.vertical, 7)
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func requestAddGroup() {
        let group = groupToAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.isEmpty, u.id != nil else { return }
        pendingAddGroup = group
    }

    // MARK: Directory writes

    private func setAccount(enabled: Bool) async {
        guard let key = u.id ?? u.userPrincipalName else { return }
        await write("\(enabled ? "enable" : "disable") the account") {
            try await appState.graphService.setUserAccountEnabled(key, enabled: enabled)
        }
    }

    private func addToGroup(_ group: String) async {
        guard let objectId = u.id else { return }
        await write("add to \(group)") {
            try await appState.graphService.addGroupMember(group: group, objectId: objectId)
        }
        if writeError == nil { groupToAdd = "" }
    }

    private func removeFromGroup(_ group: EntraGroup) async {
        guard let objectId = u.id, let groupId = group.id else { return }
        await write("remove from \(group.displayName ?? "the group")") {
            try await appState.graphService.removeGroupMember(group: groupId, objectId: objectId)
        }
    }

    /// Runs one confirmed write, then re-reads the user so the badge and the
    /// group list show what Entra now holds rather than what we asked for.
    private func write(_ what: String, _ action: () async throws -> Void) async {
        isWriting = true
        writeError = nil
        defer { isWriting = false }
        do {
            try await action()
            await load()
        } catch {
            writeError = "Couldn't \(what): \(error.localizedDescription)"
        }
    }

    // MARK: Reusable pieces

    private func propertySection(_ title: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(.headline)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    propertyRow(label: row.0, value: row.1)
                }
            }
        }
    }

    private func propertyRow(label: String, value: String?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .appFont(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 210, alignment: .leading)
                Text(value?.isEmpty == false ? value! : "—")
                    .appFont(.callout)
                    .foregroundColor(value?.isEmpty == false ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            Divider()
        }
    }

    private func emptyTab(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34)).foregroundColor(.secondary.opacity(0.5))
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func tagBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .appFont(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: .rect(cornerRadius: 4))
            .foregroundColor(color)
    }

    private func deviceIcon(_ os: String?) -> String {
        switch (os ?? "").lowercased() {
        case let s where s.contains("mac"): return "desktopcomputer"
        case let s where s.contains("ios") || s.contains("ipad"): return "ipad"
        case let s where s.contains("android"): return "candybarphone"
        default: return "pc"
        }
    }

    private func formatDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    // MARK: Load

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let key = user.userPrincipalName ?? user.id ?? ""
        guard !key.isEmpty else { return }
        async let fullTask = appState.graphService.getUser(key, includeGroups: true)
        async let managerTask = appState.graphService.getUserManager(key)
        async let devicesTask = appState.graphService.getUserDevices(key)

        if let fetched = (try? await fullTask) ?? nil {
            full = fetched
            groups = fetched.memberOf ?? []
        }
        manager = (try? await managerTask) ?? nil
        devices = (try? await devicesTask) ?? []
    }
}
