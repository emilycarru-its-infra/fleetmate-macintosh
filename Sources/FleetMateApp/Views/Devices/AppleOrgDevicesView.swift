import SwiftUI
import FleetMateCore

extension AppleOrgFacet: FilterCategoryProtocol {}

extension FilterState where Category == AppleOrgFacet {
    /// Offer only the values the rows in front of the user carry.
    func buildFromRows(_ rows: [AppleOrgRow]) {
        for facet in AppleOrgFacet.allCases {
            availableValues[facet] = Array(Set(rows.map { $0.value(for: facet) })).sorted()
        }
    }

    func matches(_ row: AppleOrgRow) -> Bool {
        for (facet, selected) in selectedValues where !selected.isEmpty {
            if !selected.contains(row.value(for: facet)) { return false }
        }
        return true
    }
}

/// Which slice of the organization the services sidebar has selected.
enum AppleOrgScope: Hashable {
    case all
    case unassigned
    case server(String)
}

/// The Mac view: every device in the Apple organization, with the Intune
/// record of the same serial beside it, and the organization's actions.
struct AppleOrgDevicesView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AppleOrgStore

    @State private var rows: [AppleOrgRow] = []
    @State private var scope: AppleOrgScope = .all
    @State private var searchText = ""
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\AppleOrgRow.serialKey)]
    @State private var filters = FilterState<AppleOrgFacet>()
    @State private var showFilters = false
    @State private var isLoadingIntune = false

    private var scopedRows: [AppleOrgRow] {
        switch scope {
        case .all: rows
        case .unassigned: rows.filter { $0.device.assignedServerId == nil }
        case .server(let id): rows.filter { $0.device.assignedServerId == id }
        }
    }

    private var visibleRows: [AppleOrgRow] {
        var result = scopedRows
        if filters.hasActiveFilters { result = result.filter { filters.matches($0) } }
        if !searchText.isEmpty {
            result = result.filter {
                $0.device.serialNumber.localizedCaseInsensitiveContains(searchText)
                    || $0.device.model.localizedCaseInsensitiveContains(searchText)
                    || ($0.device.orderNumber?.localizedCaseInsensitiveContains(searchText) ?? false)
                    || ($0.intune?.deviceName?.localizedCaseInsensitiveContains(searchText) ?? false)
                    || ($0.intune?.userPrincipalName?.localizedCaseInsensitiveContains(searchText) ?? false)
                    || ($0.serverName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return result.sorted(using: sortOrder)
    }

    private var selectedRows: [AppleOrgRow] {
        rows.filter { selection.contains($0.id) }
    }

    var body: some View {
        HSplitView {
            AppleOrgServicesSidebar(store: store, rows: rows, scope: $scope)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)

            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(minWidth: 520)

            if !selection.isEmpty {
                AppleOrgInspectorView(store: store, rows: selectedRows)
                    .frame(minWidth: 380, idealWidth: 440, maxWidth: 560)
            }
        }
        .searchable(text: $searchText, prompt: "Search serial, model, order, name…")
        .findFocusesSearchField()
        .toolbar { toolbar }
        .onAppCommand { command in
            switch command {
            case .refresh:       refresh()
            case .toggleFilters: showFilters.toggle()
            case .clearFilters:  filters.clearAll()
            default:             break
            }
        }
        .task {
            store.load()
            loadIntuneIfNeeded()
            rebuild()
        }
        .onChange(of: store.devices) { _, _ in rebuild() }
        .onChange(of: store.servers) { _, _ in rebuild() }
        .onChange(of: appState.cachedDevices.count) { _, _ in rebuild() }
        // Hiding a device also deselects it, so an action never reaches a
        // device that is no longer on screen.
        .onChange(of: visibleRows.map(\.id)) { _, ids in
            let visible = Set(ids)
            if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
        }
    }

    private func rebuild() {
        rows = AppleOrgJoin.join(devices: store.devices, intune: appState.cachedDevices, servers: store.servers)
        filters.buildFromRows(rows)
    }

    private func refresh() {
        store.load(force: true)
        loadIntune(force: true)
    }

    private func loadIntuneIfNeeded() {
        if !appState.isDevicesCacheValid { loadIntune(force: false) }
    }

    private func loadIntune(force: Bool) {
        guard appState.config.isGraphConfigured, !isLoadingIntune else { return }
        Task {
            isLoadingIntune = true
            defer { isLoadingIntune = false }
            do {
                let devices = try await appState.graphService.getManagedDevices(limit: 10000)
                appState.updateDevicesCache(devices)
            } catch {
                dbg.error("Intune read for the Mac view failed: \(error.localizedDescription)", category: "appleorg")
            }
        }
    }

    // MARK: - Header and table

    private var header: some View {
        HStack(spacing: 8) {
            if let profile = store.activeProfile {
                Text(profile.serviceName)
                    .appFont(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            if store.isLoading || isLoadingIntune {
                ProgressView().controlSize(.small)
                Text(store.isLoading ? "Reading the organization…" : "Reading Intune…")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            } else if let loaded = store.lastLoaded {
                Text("Read \(loaded.formatted(date: .omitted, time: .shortened))")
                    .appFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !selection.isEmpty {
                Button("Select All") { selection = Set(visibleRows.map(\.id)) }
                    .controlSize(.small)
                Button("Clear Selection") { selection.removeAll() }
                    .controlSize(.small)
            }
            Text("\(visibleRows.count) of \(rows.count)")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.loadError, rows.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Read the Organization", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { store.load(force: true) }
            }
        } else if store.isLoading && rows.isEmpty {
            VStack {
                ProgressView("Reading the Apple organization…")
                    .padding(.top, 50)
                Text("A full read takes about a minute; it is kept for this session.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if visibleRows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            table
        }
    }

    private var table: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Serial", value: \.serialKey) { row in
                Text(row.device.serialNumber)
                    .appFont(.body, design: .monospaced)
                    .textSelection(.enabled)
            }
            .width(min: 100, ideal: 125)

            TableColumn("Model", value: \.modelKey) { row in
                Text(row.device.model).lineLimit(1)
            }
            .width(min: 110, ideal: 170)

            TableColumn("Status", value: \.statusKey) { row in
                Text(row.statusLabel)
                    .foregroundStyle(row.device.releasedFromOrg != nil ? .secondary : .primary)
            }
            .width(min: 70, ideal: 85)

            TableColumn("Service", value: \.serverKey) { row in
                Text(row.serverName ?? "—")
                    .foregroundStyle(row.serverName == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Intune Name", value: \.nameKey) { row in
                Text(row.intune?.deviceName ?? "Not enrolled")
                    .foregroundStyle(row.intune == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .width(min: 110, ideal: 160)

            TableColumn("Compliance", value: \.complianceKey) { row in
                AppleOrgComplianceLabel(row: row)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Last Sync", value: \.lastSyncKey) { row in
                Text(AppleOrgFormat.isoDate(row.intune?.lastSyncDateTime))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Migration", value: \.migrationKey) { row in
                AppleOrgMigrationLabel(device: row.device)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Order", value: \.orderKey) { row in
                Text(row.device.orderNumber ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .width(min: 70, ideal: 100)

            TableColumn("Added", value: \.addedKey) { row in
                Text(AppleOrgFormat.date(row.device.addedToOrg))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 95)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if store.profiles.count > 1 {
                Menu {
                    ForEach(store.profiles) { profile in
                        Button {
                            selection.removeAll()
                            store.switchProfile(profile.name)
                        } label: {
                            if profile.name == store.activeProfileName {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    Label(store.activeProfileName, systemImage: "building.2")
                }
                .help("Apple organization profile")
            }

            if filters.hasActiveFilters {
                Button(action: { filters.clearAll() }) {
                    Label("Clear Filters", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.yellow)
                }
            }

            Button(action: { showFilters.toggle() }) {
                Label("Filters", systemImage: filters.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                FilterPanelView(filters: filters)
            }

            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)
            .help("Read the Apple organization and Intune again")
        }
    }
}

// MARK: - Services sidebar

private struct AppleOrgServicesSidebar: View {
    @ObservedObject var store: AppleOrgStore
    let rows: [AppleOrgRow]
    @Binding var scope: AppleOrgScope

    private var unassignedCount: Int { rows.filter { $0.device.assignedServerId == nil }.count }

    var body: some View {
        List(selection: Binding(get: { scope }, set: { scope = $0 ?? .all })) {
            Section("Organization") {
                row("All Devices", icon: "laptopcomputer.and.iphone", count: rows.count)
                    .tag(AppleOrgScope.all)
                row("No Service", icon: "questionmark.circle", count: unassignedCount)
                    .tag(AppleOrgScope.unassigned)
            }
            Section("Device Management Services") {
                ForEach(store.servers) { server in
                    row(server.name, icon: "server.rack", count: server.deviceCount)
                        .tag(AppleOrgScope.server(server.id))
                        .help(server.type ?? "")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, icon: String, count: Int?) -> some View {
        HStack {
            Label(title, systemImage: icon).lineLimit(1)
            Spacer()
            if let count {
                Text("\(count)")
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared labels

struct AppleOrgComplianceLabel: View {
    let row: AppleOrgRow

    var body: some View {
        let (color, icon): (Color, String) = {
            guard row.intune != nil else { return (.secondary, "minus.circle") }
            switch row.intune?.complianceState?.lowercased() {
            case "compliant": return (.green, "checkmark.circle.fill")
            case "noncompliant": return (.orange, "exclamationmark.circle.fill")
            case "ingraceperiod": return (.yellow, "clock.fill")
            default: return (.secondary, "questionmark.circle")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(row.complianceLabel).lineLimit(1)
        }
    }
}

struct AppleOrgMigrationLabel: View {
    let device: AppleOrgDevice

    var body: some View {
        if device.migrationStatus == nil {
            Text("—").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Text(AppleOrgRow(device: device, intune: nil, serverName: nil).migrationLabel)
                    .foregroundStyle(device.migrationStatus?.uppercased() == "FAILED" ? .orange : .primary)
                if device.hasActiveMigration, let deadline = device.migrationDeadline {
                    Text("by \(AppleOrgFormat.date(deadline))")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }
}

enum AppleOrgFormat {
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func isoDate(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return date(d) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return date(d) }
        return String(iso.prefix(10))
    }
}
