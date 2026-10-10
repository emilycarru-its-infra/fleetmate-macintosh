import SwiftUI
import FleetMateCore

/// One list for every device: each Intune record, enriched with its Apple
/// organization record by serial, plus the organization's devices Intune
/// does not hold yet. The columns are the same for every row.
struct DevicesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        DevicesContentView(appleOrg: appState.appleOrg, autopilot: appState.autopilot)
    }
}

private struct DevicesContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var appleOrg: AppleOrgStore
    @ObservedObject var autopilot: AutopilotStore
    @State private var isLoading = false
    @State private var showHashImport = false
    @State private var searchText = ""
    @State private var selectedDeviceIds: Set<String> = []
    @State private var rows: [DeviceListRow] = []
    /// The rows the list starts from: every row, or with a serial lookup
    /// active, the listed devices plus a row for each serial nobody knows.
    @State private var baseRows: [DeviceListRow] = []
    @State private var serialLookupText = ""
    @State private var serialLookup: [String] = []
    @State private var sortOrder = [KeyPathComparator(\DeviceListRow.serialText)]
    /// Column visibility, order and widths, kept across launches. Scene
    /// storage was lost whenever windows were not restored at launch.
    @State private var columnCustomization = TableColumnCustomization<DeviceListRow>()
    @AppStorage("devices.columnCustomization") private var columnCustomizationData = Data()
    /// Where the arrangement used to be kept; read once when nothing newer is saved.
    @SceneStorage("devices.columns") private var legacyColumnCustomization: TableColumnCustomization<DeviceListRow>
    @State private var showSerials = false
    @State private var filters = FilterState<DeviceFilterCategory>()
    @State private var showFilters = false
    
    // Action states
    @State private var isPerformingAction = false
    @State private var actionMessage: String?
    @State private var lockPin = ""
    @State private var showLockConfirmation = false
    @State private var showRebootConfirmation = false
    @State private var showWipeConfirmation = false
    @State private var showRetireConfirmation = false
    @State private var showFreshStartConfirmation = false
    @State private var showOffboardConfirmation = false
    @State private var showAutopilotResetConfirmation = false
    @State private var showDeleteRecordConfirmation = false
    @State private var showPushCimianConfirmation = false
    @State private var wipeOptions = WipeOptions()
    @State private var freshStartKeepUserData = true
    @State private var offboardPlan = OffboardPlan()
    @State private var offboardResults: [OffboardResult] = []

    // App selection for reinstall
    @State private var availableApps: [MobileApp] = []
    @State private var selectedAppId: String?
    @State private var appSearchText = ""
    
    var filteredRows: [DeviceListRow] {
        var result = baseRows
        if filters.hasActiveFilters {
            result = result.filter { filters.matches($0) }
        }
        if !searchText.isEmpty {
            let q = searchText
            result = result.filter {
                ($0.intune?.deviceName?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.serialNumber?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.intune?.userPrincipalName?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.apple?.orderNumber?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.autopilot?.groupTag?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.autopilot?.purchaseOrderIdentifier?.localizedCaseInsensitiveContains(q) ?? false) ||
                ($0.serverName?.localizedCaseInsensitiveContains(q) ?? false) ||
                $0.modelText.localizedCaseInsensitiveContains(q)
            }
        }
        return result.sorted(using: sortOrder)
    }

    /// Selected rows with a record behind them. A looked-up serial no system
    /// knows can be selected but is never an action's target.
    var selectedRows: [DeviceListRow] {
        rows.filter { selectedDeviceIds.contains($0.id) }
    }

    private var unknownLookupCount: Int { baseRows.filter(\.isUnknown).count }

    private var isFiltering: Bool { filters.hasActiveFilters || !serialLookup.isEmpty }

    private func clearAllFilters() {
        filters.clearAll()
        serialLookup = []
        serialLookupText = ""
    }

    /// Each discrepancy check speaks only once both systems it compares
    /// have loaded.
    private var discrepancySources: DeviceDiscrepancy.Sources {
        let inventory = Set(appState.cachedAssets.compactMap(\.serial).map(AppleOrgJoin.normalize).filter { !$0.isEmpty })
        return DeviceDiscrepancy.Sources(
            autopilotRead: autopilot.lastLoaded != nil && !autopilot.isLoading,
            appleOrgsRead: appleOrg.hasProfile && appleOrg.lastLoaded != nil && !appleOrg.isLoading,
            inventorySerials: inventory
        )
    }

    private func applyLookup() {
        baseRows = serialLookup.isEmpty ? rows : SerialList.rows(for: serialLookup, in: rows)
        filters.buildFromRows(baseRows, hasAppleOrg: appleOrg.hasProfile, hasAutopilot: !autopilot.identities.isEmpty)
    }

    /// The Intune records in the selection — every Intune action is keyed on
    /// these, never on an organization-only row.
    var selectedDevices: [IntuneDevice] {
        selectedRows.compactMap(\.intune)
    }

    private func rebuildRows() {
        let merged = AppleOrgJoin.merge(
            intune: appState.cachedDevices,
            apple: appleOrg.devices,
            servers: appleOrg.servers,
            orgLabels: appleOrg.orgLabels
        )
        rows = DeviceDiscrepancy.annotate(AutopilotJoin.enrich(merged, autopilot: autopilot.identities),
                                          sources: discrepancySources)
        applyLookup()
        dbg.debug("Device rows: \(rows.count) from \(appState.cachedDevices.count) Intune, \(appleOrg.devices.count) Apple organization and \(autopilot.identities.count) Autopilot records", category: "devices")
    }

    /// Fresh Start is a Windows-only Intune action, so it runs against the
    /// Windows subset rather than refusing a mixed selection outright.
    var windowsSelection: [IntuneDevice] {
        selectedDevices.filter { $0.platform == .windows }
    }

    private var offboardSummary: String {
        var parts: [String] = []
        switch offboardPlan.terminalAction {
        case .wipe: parts.append("factory-reset")
        case .retire: parts.append("retire")
        case .none: break
        }
        if offboardPlan.deleteAutopilotRegistration { parts.append("delete the Autopilot registration") }
        switch offboardPlan.entraAction {
        case .disable: parts.append("disable the Entra device object")
        case .delete: parts.append("delete the Entra device object")
        case .none: break
        }
        if offboardPlan.deleteIntuneRecord { parts.append("delete the Intune record") }

        guard !parts.isEmpty else { return "No offboard steps are selected." }
        let steps = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        let orphans = offboardOrphanRows.count
        let note = orphans == 0 ? "" : " \(orphans) of them have no Intune record, so the wipe or retire is skipped for those."
        return "This will \(steps) for \(selectedDevices.count + orphans) device(s).\(note) This cannot be undone."
    }

    private var mainContent: some View {
        HSplitView {
            // Main device list
            VStack(alignment: .leading, spacing: 0) {
                // Selection controls
                HStack {
                    if !selectedDeviceIds.isEmpty {
                        Button("Select All") { selectAllVisible() }
                            .controlSize(.small)
                        Button("Clear Selection") { selectedDeviceIds.removeAll() }
                            .controlSize(.small)
                    }
                    Spacer()
                    if appleOrg.isLoading {
                        ProgressView().controlSize(.small)
                        Text("Reading Apple organizations…")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    } else if autopilot.isLoading {
                        ProgressView().controlSize(.small)
                        Text("Reading Autopilot…")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("\(filteredRows.count) of \(rows.count)")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // Content
                if !appState.config.isGraphConfigured && !appleOrg.hasProfile {
                    VStack {
                        ContentUnavailableView(
                            "Not Configured",
                            systemImage: "gear.badge.xmark",
                            description: Text("Microsoft Graph is not configured. Set GRAPH_TENANT_ID and credentials in your config.")
                        )
                        Spacer()
                    }
                } else if (isLoading || appleOrg.isLoading) && rows.isEmpty {
                    VStack {
                        ProgressView("Loading devices...")
                            .padding(.top, 50)
                        Spacer()
                    }
                } else if filteredRows.isEmpty {
                    VStack {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 30)
                        Spacer()
                    }
                } else {
                    deviceTable
                }
            }
            
            // Detail Panel — shown when exactly one device is selected
            if selectedDeviceIds.count == 1, selectedRows.count == 1, let selectedRow = selectedRows.first {
                DeviceDetailView(row: selectedRow)
                    .frame(minWidth: 456, idealWidth: 540, maxWidth: 660)
            }
            
            // Actions Panel — always visible when devices are selected
            if !selectedRows.isEmpty {
                DeviceActionsPanel(
                    selectedRows: selectedRows,
                    appleOrg: appleOrg,
                    autopilot: autopilot,
                    isPerformingAction: $isPerformingAction,
                    actionMessage: $actionMessage,
                    lockPin: $lockPin,
                    showLockConfirmation: $showLockConfirmation,
                    showRebootConfirmation: $showRebootConfirmation,
                    showWipeConfirmation: $showWipeConfirmation,
                    showRetireConfirmation: $showRetireConfirmation,
                    showFreshStartConfirmation: $showFreshStartConfirmation,
                    showOffboardConfirmation: $showOffboardConfirmation,
                    showAutopilotResetConfirmation: $showAutopilotResetConfirmation,
                    showDeleteRecordConfirmation: $showDeleteRecordConfirmation,
                    showPushCimianConfirmation: $showPushCimianConfirmation,
                    wipeOptions: $wipeOptions,
                    freshStartKeepUserData: $freshStartKeepUserData,
                    offboardPlan: $offboardPlan,
                    offboardResults: $offboardResults,
                    availableApps: $availableApps,
                    selectedAppId: $selectedAppId,
                    appSearchText: $appSearchText,
                    onSync: performSync,
                    onReboot: performReboot,
                    onLock: performLock,
                    onLoadApps: loadApps,
                    onReinstallApp: performAppReinstall
                )
                .frame(minWidth: 300, maxWidth: 350)
            }
        }
        .task {
            if !appState.isDevicesCacheValid {
                loadDevices()
            }
            appleOrg.load()
            if appState.config.isGraphConfigured && appState.modules.isOn(.enrollment) { autopilot.load(using: appState.graphService) }
            rebuildRows()
            if let id = appState.navigateToDeviceId {
                selectedDeviceIds = [id]
                appState.navigateToDeviceId = nil
            }
        }
        .onReceive(appState.$cachedDevices) { _ in DispatchQueue.main.async { rebuildRows() } }
        .onChange(of: appleOrg.devices) { _, _ in rebuildRows() }
        .onChange(of: appleOrg.servers) { _, _ in rebuildRows() }
        .onChange(of: appleOrg.profiles) { _, _ in rebuildRows() }
        .onReceive(autopilot.$identities) { _ in DispatchQueue.main.async { rebuildRows() } }
        .onReceive(appState.$cachedAssets) { _ in DispatchQueue.main.async { rebuildRows() } }
        .onChange(of: serialLookup) { _, _ in applyLookup() }
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<DeviceListRow>.self, from: columnCustomizationData) {
                columnCustomization = saved
            } else {
                columnCustomization = legacyColumnCustomization
            }
        }
        .onChange(of: appleOrg.isLoading) { _, _ in rebuildRows() }
        .onChange(of: autopilot.isLoading) { _, _ in rebuildRows() }
        .onChange(of: columnCustomization) { _, value in
            if let data = try? JSONEncoder().encode(value) { columnCustomizationData = data }
        }
        // Hiding a device also deselects it, so an action never reaches a
        // device that is no longer on screen.
        .onChange(of: filteredRows.map(\.id)) { _, ids in
            let visible = Set(ids)
            if !selectedDeviceIds.isSubset(of: visible) { selectedDeviceIds.formIntersection(visible) }
        }
        .onChange(of: appState.navigateToDeviceId) { _, newId in
            if let id = newId {
                selectedDeviceIds = [id]
                appState.navigateToDeviceId = nil
            }
        }
        .onChange(of: appState.navigateToModuleFilter) { _, _ in consumeModuleFilter() }
        .task { consumeModuleFilter() }
    }

    /// The confirmation alerts, split out of `body`. Chained inline alongside
    /// the rest of the modifiers they push the view builder past what the type
    /// checker will solve in reasonable time.
    private func actionAlerts<V: View>(_ content: V) -> some View {
        content
            .alert("Confirm Reboot", isPresented: $showRebootConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reboot", role: .destructive) { performReboot() }
            } message: {
                Text("Are you sure you want to reboot \(selectedDevices.count) device(s)? This will interrupt any active user sessions.")
            }
            .alert("Confirm Lock", isPresented: $showLockConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Lock", role: .destructive) { performLock() }
            } message: {
                Text("Are you sure you want to lock \(selectedDevices.count) device(s)?")
            }
            .alert("Confirm Wipe", isPresented: $showWipeConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Wipe", role: .destructive) { performWipe() }
            } message: {
                Text("This will factory-reset \(selectedDevices.count) device(s)\(wipeOptions.keepUserData ? ", keeping user data where the platform allows" : ", erasing all data"). This cannot be undone.")
            }
            .alert("Confirm Retire", isPresented: $showRetireConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Retire", role: .destructive) { performRetire() }
            } message: {
                Text("This will remove company data and unenroll \(selectedDevices.count) device(s), leaving personal data intact.")
            }
            .alert("Confirm Fresh Start", isPresented: $showFreshStartConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Fresh Start", role: .destructive) { performFreshStart() }
            } message: {
                Text("This will reinstall Windows on \(windowsSelection.count) device(s)\(freshStartKeepUserData ? ", preserving user data" : ", removing user data"). Preinstalled OEM apps are removed and the device stays enrolled.")
            }
            .alert("Confirm Autopilot Reset", isPresented: $showAutopilotResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Autopilot Reset", role: .destructive) { performAutopilotReset() }
            } message: {
                Text("Autopilot-reset \(selectedDevices.count) device(s)? Kept: the Entra join and the Intune enrollment. Removed: user data, user accounts, apps and settings. The device returns to the out-of-box experience and re-provisions.")
            }
            .alert("Confirm Delete Record", isPresented: $showDeleteRecordConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Record", role: .destructive) { performDeleteRecord() }
            } message: {
                Text("Delete the Intune record for \(selectedDevices.count) device(s)? This is server-side only and cannot be undone from here. A wipe still pending on a record is cancelled with it.")
            }
            .alert("Confirm Push Cimian Run", isPresented: $showPushCimianConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Push Cimian Run") { performPushCimian() }
            } message: {
                Text("Force an Intune sync on \(selectedDevices.count) device(s) so the Cimian remediation creates its trigger file on check-in.")
            }
            .alert("Confirm Offboard", isPresented: $showOffboardConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Offboard", role: .destructive) { performOffboard() }
            } message: {
                Text(offboardSummary)
            }
    }

    var body: some View {
        actionAlerts(VStack(spacing: 0) {
            if appState.config.isGraphConfigured { DevicesWidgetsSection(metrics: appState.widgetMetrics) }
            mainContent
        })
        .onAppCommand { command in
            switch command {
            case .refresh:       refreshAll()
            case .toggleFilters: showFilters.toggle()
            case .clearFilters:  clearAllFilters()
            default:             break
            }
        }
        .tabSearch(text: $searchText, prompt: "Search devices...")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if isFiltering {
                    Button(action: clearAllFilters) {
                        Label("Clear Filters", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                Button(action: { showFilters.toggle() }) {
                    Label("Filters", systemImage: isFiltering
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    FilterPanelView(filters: filters)
                }

                Button(action: { showSerials.toggle() }) {
                    Label("Serials", systemImage: serialLookup.isEmpty ? "barcode.viewfinder" : "barcode")
                }
                .help("Look up a typed, pasted or imported list of serial numbers")
                .popover(isPresented: $showSerials, arrowEdge: .bottom) {
                    SerialLookupView(text: $serialLookupText, serials: $serialLookup, unknownCount: unknownLookupCount)
                        .frame(width: 360, height: 320)
                }

                Button(action: refreshAll) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || appleOrg.isLoading || autopilot.isLoading)

                if appState.config.isGraphConfigured {
                    Button(action: { showHashImport = true }) {
                        Label("Import Hardware Hashes", systemImage: "square.and.arrow.down")
                    }
                    .help("Register Windows devices with Autopilot from a hardware hash CSV")
                    .sheet(isPresented: $showHashImport) {
                        AutopilotImportSheet(store: autopilot)
                    }
                }
            }
        }
    }

    /// The same columns for every device, whichever systems know it; a value
    /// a row's sources lack reads "—". Columns only a missing source could
    /// fill are left out, and the header's context menu shows, hides and
    /// reorders the rest. The arrangement is kept across launches.
    @ViewBuilder
    private var deviceTable: some View {
        if #available(macOS 14.4, *) {
            Table(filteredRows, selection: $selectedDeviceIds, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                identityColumns
                if hasIntune { intuneColumns }
                if hasProvisioning { provisioningColumns }
                hardwareColumns
                if hasIntune { ownershipColumn }
                if hasProvisioning { purchaseColumn }
                if hasAppleOrgSource { appleOrgColumns }
            }
        } else {
            // Conditional columns need macOS 14.4; earlier releases get them all.
            Table(filteredRows, selection: $selectedDeviceIds, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                identityColumns
                intuneColumns
                provisioningColumns
                hardwareColumns
                ownershipColumn
                purchaseColumn
                appleOrgColumns
            }
        }
    }

    // The header menu offers only columns some device fills.
    private var hasIntune: Bool { rows.contains { $0.intune != nil } }
    private var hasAppleOrgSource: Bool { rows.contains { $0.apple != nil } }
    private var hasProvisioning: Bool { rows.contains { $0.apple != nil || $0.autopilot != nil } }

    /// Name, serial and platform: every row has them.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var identityColumns: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("Name", value: \.nameText) { row in
            Text(row.nameText)
                .foregroundStyle(row.intune == nil ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
        .width(min: 150, ideal: 200)
        .customizationID("name")

        TableColumn("Serial", value: \.serialText) { row in
            Text(row.serialText)
                .appFont(.body, design: .monospaced)
                .textSelection(.enabled)
        }
        .width(min: 100, ideal: 130)
        .customizationID("serial")
        // The serial is what every system shares, so it never hides.
        .disabledCustomizationBehavior(.visibility)

        TableColumn("Platform", value: \.platformText) { row in
            Text(row.platformText)
        }
        .width(min: 70, ideal: 90)
        .customizationID("platform")
    }

    /// What Intune reports about an enrolled device.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var intuneColumns: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("OS", value: \.osText) { row in
            Text(row.osText).textSelection(.enabled)
        }
        .width(min: 100, ideal: 150)
        .customizationID("os")

        TableColumn("User", value: \.userText) { row in
            Text(row.userText).textSelection(.enabled)
        }
        .width(min: 150, ideal: 200)
        .customizationID("user")

        TableColumn("Compliance", value: \.complianceText) { row in
            ComplianceBadge(state: row.intune == nil ? "Not Enrolled" : row.intune?.complianceState)
        }
        .width(min: 100, ideal: 120)
        .customizationID("compliance")

        TableColumn("Last Sync", value: \.lastSyncKey) { row in
            Text(formatDate(row.intune?.lastSyncDateTime))
                .textSelection(.enabled)
        }
        .width(min: 100, ideal: 150)
        .customizationID("lastSync")
    }

    /// The Apple organization's or Autopilot's view of the device.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var provisioningColumns: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("Management Service", value: \.serviceText) { row in
            Text(row.serviceText).lineLimit(1)
        }
        .width(min: 100, ideal: 140)
        .customizationID("service")

        TableColumn("Org Status", value: \.orgStatusText) { row in
            Text(row.orgStatusText)
        }
        .width(min: 80, ideal: 95)
        .customizationID("orgStatus")

        TableColumn("Group / Order", value: \.groupOrOrderText) { row in
            Text(row.groupOrOrderText).lineLimit(1).textSelection(.enabled)
        }
        .width(min: 80, ideal: 110)
        .customizationID("groupOrder")
    }

    /// Hardware, from whichever record has it. Hidden until asked for.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var hardwareColumns: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("Model", value: \.modelText) { row in
            Text(row.modelText).lineLimit(1)
        }
        .width(min: 100, ideal: 160)
        .customizationID("model")
        .defaultVisibility(.hidden)

        TableColumn("Manufacturer", value: \.manufacturerText) { row in
            Text(row.manufacturerText)
        }
        .width(min: 80, ideal: 110)
        .customizationID("manufacturer")
        .defaultVisibility(.hidden)
    }

    /// Intune's ownership record. Hidden until asked for.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var ownershipColumn: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("Ownership", value: \.ownershipText) { row in
            Text(row.ownershipText)
        }
        .width(min: 70, ideal: 90)
        .customizationID("ownership")
        .defaultVisibility(.hidden)
    }

    /// Apple's purchase source or Autopilot's purchase order. Hidden until asked for.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var purchaseColumn: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("Purchase Source", value: \.purchaseSourceText) { row in
            Text(row.purchaseSourceText)
        }
        .width(min: 80, ideal: 110)
        .customizationID("purchaseSource")
        .defaultVisibility(.hidden)
    }

    /// Only the Apple organization fills these. Hidden until asked for.
    @TableColumnBuilder<DeviceListRow, KeyPathComparator<DeviceListRow>>
    private var appleOrgColumns: some TableColumnContent<DeviceListRow, KeyPathComparator<DeviceListRow>> {
        TableColumn("Migration", value: \.migrationText) { row in
            Text(row.migrationText)
                .foregroundStyle(row.apple?.migrationStatus?.uppercased() == "FAILED" ? Color.orange : Color.primary)
        }
        .width(min: 80, ideal: 100)
        .customizationID("migration")
        .defaultVisibility(.hidden)

        TableColumn("Added", value: \.addedKey) { row in
            Text(AppleOrgFormat.date(row.apple?.addedToOrg))
        }
        .width(min: 80, ideal: 100)
        .customizationID("added")
        .defaultVisibility(.hidden)

        // Read per device on selection, so most rows read "—" — which is why
        // it is neither sortable nor offered as a filter.
        TableColumn("Activation Lock") { row in
            let lock = row.apple.flatMap { appleOrg.activationLock[$0.serialNumber] }
            Text(lock?.columnText ?? "—")
                .foregroundStyle(lock?.isLocked == true ? Color.orange : Color.primary)
        }
        .width(min: 80, ideal: 110)
        .customizationID("activationLock")
        .defaultVisibility(.hidden)
    }

    private func selectAllVisible() {
        for row in filteredRows {
            selectedDeviceIds.insert(row.id)
        }
    }

    /// Apply a dashboard widget's deep-linked filter (e.g. a Compliance wedge).
    private func consumeModuleFilter() {
        guard let link = appState.navigateToModuleFilter, link.tab == .devices,
              let category = DeviceFilterCategory(rawValue: link.category) else { return }
        appState.navigateToModuleFilter = nil
        // The Platform widget names platforms "Macintosh" and "iOS/iPadOS";
        // the filter holds Intune's names, so each is matched through that
        // label and "iOS/iPadOS" selects both iOS and iPadOS.
        filters.selectedValues[category] = Set(WidgetFilterMatch.matchingValues(
            link.value, in: filters.availableValues[category],
            display: category == .platform ? WidgetFilterMatch.platformLabel : nil))
    }

    private func refreshAll() {
        loadDevices()
        appleOrg.load(force: true)
        if appState.config.isGraphConfigured && appState.modules.isOn(.enrollment) { autopilot.load(using: appState.graphService, force: true) }
    }

    private func loadDevices() {
        guard appState.config.isGraphConfigured else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let fetchedDevices = try await appState.graphService.getManagedDevices(limit: 10000)
                appState.updateDevicesCache(fetchedDevices)
            } catch {
                appState.errorMessage = "Failed to load devices: \(error.localizedDescription)"
            }
        }
    }
    
    private func loadApps() {
        Task {
            do {
                if appSearchText.isEmpty {
                    availableApps = try await appState.graphService.getMobileApps(limit: 100)
                } else {
                    availableApps = try await appState.graphService.searchMobileApps(appSearchText, limit: 50)
                }
            } catch {
                appState.errorMessage = "Failed to load apps: \(error.localizedDescription)"
            }
        }
    }
    
    private func performSync() {
        Task {
            isPerformingAction = true
            actionMessage = "Syncing \(selectedDevices.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                let results = try await appState.graphService.syncDevices(selectedDevices.map(\.id))
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                
                if failed == 0 {
                    actionMessage = "Successfully synced \(successful) device(s)"
                } else {
                    actionMessage = "Synced \(successful) device(s), \(failed) failed"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    private func performReboot() {
        Task {
            isPerformingAction = true
            actionMessage = "Rebooting \(selectedDevices.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                let results = try await appState.graphService.rebootDevices(selectedDevices.map(\.id))
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                
                if failed == 0 {
                    actionMessage = "Successfully sent reboot to \(successful) device(s)"
                } else {
                    actionMessage = "Rebooted \(successful) device(s), \(failed) failed"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    private func performLock() {
        Task {
            isPerformingAction = true
            actionMessage = "Locking \(selectedDevices.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                let pin = lockPin.isEmpty ? nil : lockPin
                let results = try await appState.graphService.remoteLockDevices(selectedDevices.map(\.id), pin: pin)
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                
                if failed == 0 {
                    actionMessage = "Successfully locked \(successful) device(s)"
                } else {
                    actionMessage = "Locked \(successful) device(s), \(failed) failed"
                }
                lockPin = ""
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func performWipe() {
        Task {
            isPerformingAction = true
            actionMessage = "Wiping \(selectedDevices.count) device(s)..."
            defer { isPerformingAction = false }

            do {
                // Pass the device records, not bare ids, so each one's wipe body
                // is built for its own platform.
                let results = try await appState.graphService.wipeDevices(selectedDevices, options: wipeOptions)
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful

                if failed == 0 {
                    actionMessage = "Successfully sent wipe to \(successful) device(s)"
                } else {
                    actionMessage = "Wiped \(successful) device(s), \(failed) failed"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func performFreshStart() {
        let targets = windowsSelection
        guard !targets.isEmpty else {
            actionMessage = "Fresh Start applies to Windows devices only — none selected"
            return
        }

        Task {
            isPerformingAction = true
            actionMessage = "Starting Fresh Start on \(targets.count) device(s)..."
            defer { isPerformingAction = false }

            do {
                let results = try await appState.graphService.freshStartDevices(
                    targets.map { $0.id },
                    keepUserData: freshStartKeepUserData
                )
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful

                if failed == 0 {
                    actionMessage = "Successfully sent Fresh Start to \(successful) device(s)"
                } else {
                    actionMessage = "Fresh Start sent to \(successful) device(s), \(failed) failed"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    /// Autopilot Reset: a wipe with `keepEnrollmentData: true` and
    /// `keepUserData: false`, so the device returns to OOBE still Entra-joined
    /// and enrolled. Fresh Start (`cleanWindowsDevice`) is a different action.
    private func performAutopilotReset() {
        let targets = selectedDevices
        guard !targets.isEmpty else { return }
        Task {
            isPerformingAction = true
            actionMessage = "Autopilot-resetting \(targets.count) device(s)..."
            defer { isPerformingAction = false }
            do {
                let results = try await appState.graphService.wipeDevices(targets, options: .autopilotReset)
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                actionMessage = failed == 0
                    ? "Autopilot reset sent to \(successful) device(s)"
                    : "Autopilot reset sent to \(successful), \(failed) failed"
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func performDeleteRecord() {
        let targets = selectedDevices
        guard !targets.isEmpty else { return }
        Task {
            isPerformingAction = true
            actionMessage = "Deleting \(targets.count) record(s)..."
            defer { isPerformingAction = false }
            do {
                let results = try await appState.graphService.deleteManagedDevices(targets.map(\.id))
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                actionMessage = failed == 0
                    ? "Deleted \(successful) record(s)"
                    : "Deleted \(successful), \(failed) failed"
                if successful > 0 { loadDevices() }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    /// Cimian runs from a remediation that drops a headless trigger file;
    /// forcing a sync is what makes the device pick it up now.
    private func performPushCimian() {
        let targets = selectedDevices
        guard !targets.isEmpty else { return }
        Task {
            isPerformingAction = true
            actionMessage = "Pushing Cimian run to \(targets.count) device(s)..."
            defer { isPerformingAction = false }
            do {
                let results = try await appState.graphService.syncDevices(targets.map(\.id))
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                actionMessage = failed == 0
                    ? "Cimian push initiated on \(successful) device(s) - sync forced, remediation will create trigger file on check-in"
                    : "Push initiated on \(successful), \(failed) sync(s) failed"
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    /// Selected rows Autopilot registered but Intune never enrolled. Offboard
    /// cleans up the records they do have, from the identity the row carries.
    private var offboardOrphanRows: [DeviceListRow] {
        selectedRows.filter { $0.intune == nil && $0.autopilot != nil }
    }

    private func performOffboard() {
        let targets = selectedDevices
        let orphans = offboardOrphanRows.compactMap(\.autopilot)
        guard !targets.isEmpty || !orphans.isEmpty else { return }

        Task {
            isPerformingAction = true
            actionMessage = "Offboarding \(targets.count + orphans.count) device(s)..."
            offboardResults = []
            defer { isPerformingAction = false }

            var plan = offboardPlan
            plan.wipeOptions = wipeOptions

            var results = targets.isEmpty ? [] : await appState.graphService.offboardDevices(targets, plan: plan)
            for identity in orphans {
                results.append(await appState.graphService.offboardRegisteredOnly(identity, plan: plan))
            }
            offboardResults = results.sorted { ($0.deviceName ?? $0.identifier) < ($1.deviceName ?? $1.identifier) }

            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            actionMessage = failed == 0
                ? "Offboarded \(succeeded) device(s)"
                : "Offboarded \(succeeded) device(s), \(failed) with failures"
        }
    }

    private func performRetire() {
        Task {
            isPerformingAction = true
            actionMessage = "Retiring \(selectedDevices.count) device(s)..."
            defer { isPerformingAction = false }

            do {
                let results = try await appState.graphService.retireDevices(selectedDevices.map(\.id))
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful

                if failed == 0 {
                    actionMessage = "Successfully sent retire to \(successful) device(s)"
                } else {
                    actionMessage = "Retired \(successful) device(s), \(failed) failed"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func performAppReinstall() {
        guard let appId = selectedAppId else {
            actionMessage = "Please select an app to reinstall"
            return
        }
        
        Task {
            isPerformingAction = true
            actionMessage = "Triggering app reinstall on \(selectedDevices.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                // Reinstall is triggered via sync which re-evaluates app assignments
                let results = try await appState.graphService.syncDevices(selectedDevices.map(\.id))
                let successful = results.filter { $0.success }.count
                let failed = results.count - successful
                
                let appName = availableApps.first { $0.id == appId }?.displayName ?? "app"
                if failed == 0 {
                    actionMessage = "Triggered \(appName) reinstall check on \(successful) device(s)"
                } else {
                    actionMessage = "Triggered on \(successful), \(failed) failed"
                }
            } catch {
                actionMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return DeviceListRow.missing }
        return String(dateString.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

// MARK: - Device Actions Panel

struct DeviceActionsPanel: View {
    let selectedRows: [DeviceListRow]
    @ObservedObject var appleOrg: AppleOrgStore
    @ObservedObject var autopilot: AutopilotStore

    private var selectedDevices: [IntuneDevice] { selectedRows.compactMap(\.intune) }
    /// Every selected device has an Intune record.
    private var allEnrolled: Bool { !selectedRows.isEmpty && selectedRows.allSatisfy { $0.intune != nil } }
    /// Every selected device is enrolled, or at least registered in Autopilot.
    private var canOffboard: Bool {
        !selectedRows.isEmpty && selectedRows.allSatisfy { $0.intune != nil || $0.autopilot != nil }
    }
    /// The selection when one Apple organization holds every selected
    /// device; empty otherwise, including a selection spanning two.
    private var appleRows: [DeviceListRow] {
        let orgs = Set(selectedRows.map { $0.apple?.orgId })
        return orgs.count == 1 && orgs.first! != nil ? selectedRows : []
    }
    @Binding var isPerformingAction: Bool
    @Binding var actionMessage: String?
    @Binding var lockPin: String
    @Binding var showLockConfirmation: Bool
    @Binding var showRebootConfirmation: Bool
    @Binding var showWipeConfirmation: Bool
    @Binding var showRetireConfirmation: Bool
    @Binding var showFreshStartConfirmation: Bool
    @Binding var showOffboardConfirmation: Bool
    @Binding var showAutopilotResetConfirmation: Bool
    @Binding var showDeleteRecordConfirmation: Bool
    @Binding var showPushCimianConfirmation: Bool
    @Binding var wipeOptions: WipeOptions
    @Binding var freshStartKeepUserData: Bool
    @Binding var offboardPlan: OffboardPlan
    @Binding var offboardResults: [OffboardResult]
    @Binding var availableApps: [MobileApp]
    @Binding var selectedAppId: String?
    @Binding var appSearchText: String

    let onSync: () -> Void
    let onReboot: () -> Void
    let onLock: () -> Void
    let onLoadApps: () -> Void
    let onReinstallApp: () -> Void

    @State private var expandedSections: Set<String> = ["sync", "restart", "lock", "app", "update"]

    /// Platforms present in the selection. Wipe options and whole sections are
    /// gated on this — Graph rejects a wipe body carrying a key that is foreign
    /// to the target platform, so a mixed selection only ever gets the keys all
    /// its platforms share.
    private var platforms: Set<DevicePlatform> {
        Set(selectedDevices.map { $0.platform })
    }

    private var hasWindows: Bool { platforms.contains(.windows) }
    private var hasApple: Bool { platforms.contains(.macOS) || platforms.contains(.ios) }
    private var isMixedPlatform: Bool { platforms.count > 1 }
    /// Every selected device is an enrolled Windows device.
    private var allWindows: Bool { allEnrolled && platforms == [.windows] }
    private var windowsCount: Int { selectedDevices.filter { $0.platform == .windows }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Device Actions")
                    .appFont(.headline)
                Spacer()
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            
            // Selected devices summary
            VStack(alignment: .leading, spacing: 4) {
                Text("\(selectedRows.count) device(s) selected")
                    .appFont(.subheadline)
                    .fontWeight(.medium)
                
                if selectedRows.count <= 3 {
                    ForEach(selectedRows) { row in
                        Text(row.intune?.deviceName ?? row.serialNumber ?? "Unknown")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("\(selectedRows.prefix(2).compactMap { $0.intune?.deviceName ?? $0.serialNumber }.joined(separator: ", ")) and \(selectedRows.count - 2) more...")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            
            Divider()
            
            // Action message
            if let message = actionMessage {
                HStack {
                    if isPerformingAction {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(message)
                        .appFont(.caption)
                        .foregroundColor(message.contains("Error") ? .orange : .green)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            
            ScrollView {
                VStack(spacing: 0) {
                    // Only actions valid for every selected device are
                    // offered: Intune's for devices enrolled in it, the Apple
                    // organization's for devices one organization holds,
                    // Autopilot's for devices it has an identity for.
                    if allEnrolled {
                        intuneActions
                    }
                    // Offboard also reaches devices Autopilot registered and
                    // Intune never enrolled: it cleans up what records remain.
                    if canOffboard {
                        offboardSection
                    }
                    if !appleRows.isEmpty {
                        AppleOrgActionsGroup(store: appleOrg, rows: appleRows)
                    }
                    if AutopilotActionsGroup.applies(to: selectedRows) {
                        AutopilotActionsGroup(store: autopilot, rows: selectedRows)
                    }
                }
            }
            
            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var offboardSection: some View {
        // Offboard Section
        ActionAccordion(
            title: "Offboard Device",
            icon: "shippingbox.and.arrow.backward",
            isExpanded: expandedSections.contains("offboard"),
            onToggle: { toggleSection("offboard") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Decommission across Intune, Autopilot and Entra in one pass. Steps that do not apply to a device's platform are skipped.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)

                Picker("Intune action", selection: $offboardPlan.terminalAction) {
                    ForEach(OffboardPlan.TerminalAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .appFont(.caption)

                if offboardPlan.terminalAction == .wipe {
                    Text("Uses the wipe options set above.")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Delete the Autopilot registration", isOn: $offboardPlan.deleteAutopilotRegistration)
                    .appFont(.caption)
                    .help("Windows only. Releases the hardware hash so the device can be re-registered elsewhere.")

                Picker("Entra device", selection: $offboardPlan.entraAction) {
                    ForEach(OffboardPlan.EntraAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .appFont(.caption)

                Toggle("Delete the Intune record", isOn: $offboardPlan.deleteIntuneRecord)
                    .appFont(.caption)

                if offboardPlan.deleteIntuneRecord && offboardPlan.terminalAction != .none {
                    Label("The pending action lives on the Intune record — deleting it before the device checks in cancels the \(offboardPlan.terminalAction == .wipe ? "wipe" : "retire").", systemImage: "exclamationmark.triangle")
                        .appFont(.caption)
                        .foregroundColor(.orange)
                }

                Button(action: { showOffboardConfirmation = true }) {
                    Label("Offboard Device", systemImage: "shippingbox.and.arrow.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isPerformingAction)

                if !offboardResults.isEmpty {
                    Divider()
                    ForEach(offboardResults) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.deviceName ?? result.identifier)
                                .appFont(.caption)
                                .fontWeight(.medium)
                            ForEach(result.steps) { step in
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: stepIcon(step.outcome))
                                        .foregroundColor(stepColor(step.outcome))
                                    Text(step.detail.map { "\(step.step) — \($0)" } ?? step.step)
                                        .foregroundColor(.secondary)
                                }
                                .appFont(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }

        Divider()
    }

    @ViewBuilder
    private var intuneActions: some View {
        // Sync Section
        ActionAccordion(
            title: "Sync Device",
            icon: "arrow.triangle.2.circlepath",
            isExpanded: expandedSections.contains("sync"),
            onToggle: { toggleSection("sync") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Force devices to check in with Intune and re-evaluate policies and app assignments.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                
                Button(action: onSync) {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingAction)
            }
        }
        
        Divider()
        
        // Restart Section
        ActionAccordion(
            title: "Restart Device",
            icon: "power",
            isExpanded: expandedSections.contains("restart"),
            onToggle: { toggleSection("restart") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Immediately restart the selected devices. Active user sessions will be terminated.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                
                Button(action: { showRebootConfirmation = true }) {
                    Label("Restart", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isPerformingAction)
            }
        }
        
        Divider()
        
        // Lock Section
        ActionAccordion(
            title: "Lock Device",
            icon: "lock.fill",
            isExpanded: expandedSections.contains("lock"),
            onToggle: { toggleSection("lock") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remotely lock devices. For macOS, you can set a PIN that users must enter to unlock.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                
                TextField("PIN (optional, macOS only)", text: $lockPin)
                    .textFieldStyle(.roundedBorder)
                
                Button(action: { showLockConfirmation = true }) {
                    Label("Lock Device", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isPerformingAction)
            }
        }
        
        Divider()

        // Retire Section
        ActionAccordion(
            title: "Retire Device",
            icon: "minus.circle",
            isExpanded: expandedSections.contains("retire"),
            onToggle: { toggleSection("retire") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remove company data and unenroll the selected devices. Personal data is left intact.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)

                Button(action: { showRetireConfirmation = true }) {
                    Label("Retire Device", systemImage: "minus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isPerformingAction)
            }
        }

        Divider()

        // Wipe Section
        ActionAccordion(
            title: "Wipe Device",
            icon: "trash.fill",
            isExpanded: expandedSections.contains("wipe"),
            onToggle: { toggleSection("wipe") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Factory-reset the selected devices. This cannot be undone.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)

                if isMixedPlatform {
                    Label("Mixed selection — each device gets only the options its platform supports.", systemImage: "info.circle")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Leave the device enrolled", isOn: $wipeOptions.keepEnrollmentData)
                    .appFont(.caption)

                if hasWindows {
                    Toggle("Keep user data (Windows)", isOn: $wipeOptions.keepUserData)
                        .appFont(.caption)

                    Toggle("Protected wipe (Windows)", isOn: $wipeOptions.useProtectedWipe)
                        .appFont(.caption)
                        .help("Retries until it succeeds and cannot be circumvented by the user. A device interrupted mid-wipe may not boot.")
                }

                if hasApple {
                    TextField("Recovery PIN (macOS/iOS)", text: Binding(
                        get: { wipeOptions.macOsUnlockCode ?? "" },
                        set: { wipeOptions.macOsUnlockCode = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .appFont(.caption)
                }

                if platforms.contains(.macOS) {
                    Picker("Erase behaviour", selection: Binding(
                        get: { wipeOptions.obliterationBehavior ?? .default },
                        set: { wipeOptions.obliterationBehavior = $0 }
                    )) {
                        ForEach(WipeOptions.ObliterationBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.menu)
                    .appFont(.caption)
                    .help("macOS 12 and later. Erase All Content and Settings is instant; the fallback full erase is not.")
                }

                Button(action: { showWipeConfirmation = true }) {
                    Label("Wipe Device", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isPerformingAction)
            }
        }

        Divider()

        // Fresh Start Section — Windows only
        if hasWindows {
            ActionAccordion(
                title: "Fresh Start",
                icon: "sparkles",
                isExpanded: expandedSections.contains("freshstart"),
                onToggle: { toggleSection("freshstart") }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reinstall Windows and remove preinstalled OEM apps. The device stays enrolled and Entra-joined.")
                        .appFont(.caption)
                        .foregroundColor(.secondary)

                    if isMixedPlatform {
                        Text("Applies to the \(windowsCount) Windows device(s) in the selection.")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Keep user data and account", isOn: $freshStartKeepUserData)
                        .appFont(.caption)

                    Button(action: { showFreshStartConfirmation = true }) {
                        Label("Fresh Start", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isPerformingAction)
                }
            }

            Divider()
        }

        // Autopilot Reset — every selected device must be enrolled Windows
        if allWindows {
            ActionAccordion(
                title: "Autopilot Reset",
                icon: "arrow.counterclockwise.circle",
                isExpanded: expandedSections.contains("autopilotreset"),
                onToggle: { toggleSection("autopilotreset") }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Return the selected devices to the out-of-box experience. Keeps the Entra join and Intune enrollment; removes user data, apps and settings.")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { showAutopilotResetConfirmation = true }) {
                        Label("Autopilot Reset", systemImage: "arrow.counterclockwise.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isPerformingAction)
                }
            }

            Divider()
        }

        // Delete Intune Record — every selected device must have a record
        if allEnrolled {
            ActionAccordion(
                title: "Delete Intune Record",
                icon: "trash.slash",
                isExpanded: expandedSections.contains("deleterecord"),
                onToggle: { toggleSection("deleterecord") }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete the Intune device record server-side only. Nothing is sent to the device; use for stale or duplicate records.")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { showDeleteRecordConfirmation = true }) {
                        Label("Delete Record", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isPerformingAction)
                }
            }

            Divider()
        }

        // Push Cimian Run — Windows only
        if allWindows {
            ActionAccordion(
                title: "Push Cimian Run",
                icon: "shippingbox",
                isExpanded: expandedSections.contains("cimian"),
                onToggle: { toggleSection("cimian") }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trigger an immediate Cimian managed software update on selected devices. Creates a .cimian.headless trigger file via Intune remediation. CimianWatcher picks it up within 10 seconds.")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { showPushCimianConfirmation = true }) {
                        Label("Push Cimian Run", systemImage: "shippingbox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPerformingAction)
                }
            }

            Divider()
        }


        // App Reinstall Section
        ActionAccordion(
            title: "Reinstall App",
            icon: "arrow.down.app.fill",
            isExpanded: expandedSections.contains("app"),
            onToggle: { toggleSection("app") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trigger app reinstallation by initiating a device sync. Select an app to reinstall.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField("Search apps...", text: $appSearchText)
                        .textFieldStyle(.roundedBorder)
                    Button(action: onLoadApps) {
                        Image(systemName: "magnifyingglass")
                    }
                }
                
                if !availableApps.isEmpty {
                    Picker("Select App", selection: $selectedAppId) {
                        Text("Select an app...").tag(nil as String?)
                        ForEach(availableApps, id: \.id) { app in
                            Text(app.displayName ?? "Unknown")
                                .tag(app.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Button(action: onReinstallApp) {
                    Label("Trigger Reinstall", systemImage: "arrow.down.app.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingAction || selectedAppId == nil)
            }
            .onAppear {
                if availableApps.isEmpty {
                    onLoadApps()
                }
            }
        }
        
        Divider()
        
        // OS Update Section
        ActionAccordion(
            title: "OS Update",
            icon: "arrow.up.circle.fill",
            isExpanded: expandedSections.contains("update"),
            onToggle: { toggleSection("update") }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Trigger OS update check on Windows devices. For macOS, updates are managed through update policies.")
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                
                Button(action: onSync) {
                    Label("Check for Updates", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingAction)
            }
        }
    }
    
    private func toggleSection(_ section: String) {
        withAnimation {
            if expandedSections.contains(section) {
                expandedSections.remove(section)
            } else {
                expandedSections.insert(section)
            }
        }
    }

    private func stepIcon(_ outcome: OffboardStepResult.Outcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func stepColor(_ outcome: OffboardStepResult.Outcome) -> Color {
        switch outcome {
        case .succeeded: return .green
        case .skipped: return .secondary
        case .failed: return .orange
        }
    }
}

// MARK: - Action Accordion

struct ActionAccordion<Content: View>: View {
    let title: String
    let icon: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                        .frame(width: 24)
                    Text(title)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }
}

// MARK: - Compliance Badge

struct ComplianceBadge: View {
    let state: String?

    var body: some View {
        let (color, icon): (Color, String) = {
            switch state?.lowercased() {
            case "compliant": return (.green, "checkmark.circle.fill")
            case "noncompliant": return (.orange, "exclamationmark.circle.fill")
            case "ingraceperiod": return (.yellow, "clock.fill")
            default: return (.gray, "questionmark.circle.fill")
            }
        }()

        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(state ?? "Unknown")
                .appFont(.caption)
        }
    }
}

#if DEBUG
#Preview {
    DevicesView()
        .environmentObject(AppState())
}
#endif
