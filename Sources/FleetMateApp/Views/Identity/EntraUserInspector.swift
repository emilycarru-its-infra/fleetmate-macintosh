import SwiftUI
import FleetMateCore

// MARK: - Compact sidebar row

/// A single row in the Users sidebar list (Contacts-style master column).
struct UserSidebarRow: View {
    let user: EntraUser

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName ?? "Unknown")
                    .font(.body)
                    .lineLimit(1)
                Text(user.userPrincipalName ?? user.mail ?? "-")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(user.accountEnabled == false ? Color.red : Color.green)
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

    enum InspectorTab: Hashable { case overview, properties, devices, groups }

    @State private var tab: InspectorTab = .overview
    @State private var full: EntraUser?
    @State private var manager: EntraUserRef?
    @State private var devices: [EntraDevice] = []
    @State private var groups: [EntraGroup] = []
    @State private var isLoading = true

    private var u: EntraUser { full ?? user }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                Text("Overview").tag(InspectorTab.overview)
                Text("Properties").tag(InspectorTab.properties)
                Text("Devices (\(devices.count))").tag(InspectorTab.devices)
                Text("Groups (\(groups.count))").tag(InspectorTab.groups)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                switch tab {
                case .overview:   overview
                case .properties: properties
                case .devices:    devicesTab
                case .groups:     groupsTab
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: user.id) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 46))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(u.displayName ?? "Unknown")
                    .font(.title2).bold()
                Text(u.userPrincipalName ?? u.email)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                if let title = u.jobTitle {
                    Text(title).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                enabledBadge
                if isLoading { ProgressView().controlSize(.small) }
            }
        }
        .padding()
    }

    private var enabledBadge: some View {
        let enabled = u.accountEnabled != false
        return Label(enabled ? "Enabled" : "Disabled",
                     systemImage: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundColor(enabled ? .green : .red)
            .font(.callout)
    }

    // MARK: Overview

    private var overview: some View {
        propertySection("Summary", [
            ("User principal name", u.userPrincipalName),
            ("Object ID", u.id),
            ("User type", u.userType),
            ("Email", u.mail),
            ("Job title", u.jobTitle),
            ("Department", u.department),
            ("Company", u.companyName),
            ("Manager", manager?.displayName),
            ("Office", u.officeLocation),
            ("Employee ID", u.employeeId),
            ("Devices", devices.isEmpty ? nil : "\(devices.count)"),
            ("Groups", groups.isEmpty ? nil : "\(groups.count)"),
            ("Created", formatDate(u.createdDateTime)),
        ])
        .padding()
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
                            Text(device.displayName ?? "Unknown").font(.body)
                            Text([device.operatingSystem, device.operatingSystemVersion]
                                .compactMap { $0 }.joined(separator: " "))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if device.isCompliant == true {
                            tagBadge("Compliant", .green)
                        } else if device.isCompliant == false {
                            tagBadge("Non-compliant", .red)
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
            if groups.isEmpty {
                emptyTab("No group memberships", "person.2")
            } else {
                ForEach(groups, id: \.id) { group in
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.displayName ?? "Unknown").font(.body)
                            if let d = group.description, !d.isEmpty {
                                Text(d).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal).padding(.vertical, 7)
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Reusable pieces

    private func propertySection(_ title: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
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
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 210, alignment: .leading)
                Text(value?.isEmpty == false ? value! : "—")
                    .font(.callout)
                    .foregroundColor(value?.isEmpty == false ? .primary : .secondary.opacity(0.6))
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
            .font(.caption2)
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
