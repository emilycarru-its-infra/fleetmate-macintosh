import SwiftUI
import FleetMateCore

enum DeviceSortField: String, CaseIterable {
    case serial = "Serial"
    case name = "Name"
    case compliance = "Compliance"
    case os = "OS"
    case user = "User"
    case lastSync = "Last Sync"
}

struct DevicesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var selectedDeviceIds: Set<String> = []
    @State private var sortField: DeviceSortField = .serial
    @State private var sortAscending = true
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
    @State private var wipeOptions = WipeOptions()
    @State private var freshStartKeepUserData = true
    @State private var offboardPlan = OffboardPlan()
    @State private var offboardResults: [OffboardResult] = []

    // App selection for reinstall
    @State private var availableApps: [MobileApp] = []
    @State private var selectedAppId: String?
    @State private var appSearchText = ""
    
    // Use cached devices from appState
    var devices: [IntuneDevice] { appState.cachedDevices }

    var filteredDevices: [IntuneDevice] {
        var result = devices

        if filters.hasActiveFilters {
            result = result.filter { filters.matches($0) }
        }

        if !searchText.isEmpty {
            result = result.filter {
                ($0.deviceName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.serialNumber?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.userPrincipalName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result.sorted { a, b in
            let aVal: String
            let bVal: String
            switch sortField {
            case .serial: aVal = a.serialNumber ?? ""; bVal = b.serialNumber ?? ""
            case .name: aVal = a.deviceName ?? ""; bVal = b.deviceName ?? ""
            case .compliance: aVal = a.complianceState ?? ""; bVal = b.complianceState ?? ""
            case .os: aVal = a.operatingSystem ?? ""; bVal = b.operatingSystem ?? ""
            case .user: aVal = a.userDisplayName ?? ""; bVal = b.userDisplayName ?? ""
            case .lastSync: aVal = a.lastSyncDateTime ?? ""; bVal = b.lastSyncDateTime ?? ""
            }
            return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
        }
    }
    
    var selectedDevices: [IntuneDevice] {
        devices.filter { selectedDeviceIds.contains($0.id) }
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
        return "This will \(steps) for \(selectedDeviceIds.count) device(s). This cannot be undone."
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
                    Text("\(filteredDevices.count) of \(devices.count)")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                // Content
                if !appState.config.isGraphConfigured {
                    VStack {
                        ContentUnavailableView(
                            "Not Configured",
                            systemImage: "gear.badge.xmark",
                            description: Text("Microsoft Graph is not configured. Set GRAPH_TENANT_ID and credentials in your config.")
                        )
                        Spacer()
                    }
                } else if isLoading && appState.cachedDevices.isEmpty {
                    VStack {
                        ProgressView("Loading devices...")
                            .padding(.top, 50)
                        Spacer()
                    }
                } else if filteredDevices.isEmpty {
                    VStack {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 30)
                        Spacer()
                    }
                } else {
                    Table(filteredDevices, selection: $selectedDeviceIds) {
                        TableColumn(deviceSortHeader("Name", field: .name)) { device in
                            Text(device.deviceName ?? "-")
                                .textSelection(.enabled)
                        }
                        .width(min: 150, ideal: 200)

                        TableColumn(deviceSortHeader("Serial", field: .serial)) { device in
                            Text(device.serialNumber ?? "-")
                                .appFont(.body, design: .monospaced)
                                .textSelection(.enabled)
                        }
                        .width(min: 100, ideal: 130)

                        TableColumn(deviceSortHeader("Compliance", field: .compliance)) { device in
                            ComplianceBadge(state: device.complianceState)
                        }
                        .width(min: 100, ideal: 120)

                        TableColumn(deviceSortHeader("OS", field: .os)) { device in
                            Text("\(device.operatingSystem ?? "-") \(device.osVersion ?? "")")
                                .textSelection(.enabled)
                        }
                        .width(min: 100, ideal: 150)

                        TableColumn(deviceSortHeader("User", field: .user)) { device in
                            Text(device.userDisplayName ?? device.userPrincipalName ?? "-")
                                .textSelection(.enabled)
                        }
                        .width(min: 150, ideal: 200)

                        TableColumn(deviceSortHeader("Last Sync", field: .lastSync)) { device in
                            Text(formatDate(device.lastSyncDateTime))
                                .textSelection(.enabled)
                        }
                        .width(min: 100, ideal: 150)
                    }
                }
            }
            
            // Detail Panel — shown when exactly one device is selected
            if selectedDeviceIds.count == 1, let selectedDevice = selectedDevices.first {
                DeviceDetailView(device: selectedDevice)
                    .frame(minWidth: 456, idealWidth: 540, maxWidth: 660)
            }
            
            // Actions Panel — always visible when devices are selected
            if !selectedDeviceIds.isEmpty {
                DeviceActionsPanel(
                    selectedDevices: selectedDevices,
                    isPerformingAction: $isPerformingAction,
                    actionMessage: $actionMessage,
                    lockPin: $lockPin,
                    showLockConfirmation: $showLockConfirmation,
                    showRebootConfirmation: $showRebootConfirmation,
                    showWipeConfirmation: $showWipeConfirmation,
                    showRetireConfirmation: $showRetireConfirmation,
                    showFreshStartConfirmation: $showFreshStartConfirmation,
                    showOffboardConfirmation: $showOffboardConfirmation,
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
            if !devices.isEmpty { filters.buildFromDevices(devices) }
            if let id = appState.navigateToDeviceId {
                selectedDeviceIds = [id]
                appState.navigateToDeviceId = nil
            }
        }
        .onChange(of: appState.cachedDevices.count) { _, _ in
            filters.buildFromDevices(appState.cachedDevices)
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
                Text("Are you sure you want to reboot \(selectedDeviceIds.count) device(s)? This will interrupt any active user sessions.")
            }
            .alert("Confirm Lock", isPresented: $showLockConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Lock", role: .destructive) { performLock() }
            } message: {
                Text("Are you sure you want to lock \(selectedDeviceIds.count) device(s)?")
            }
            .alert("Confirm Wipe", isPresented: $showWipeConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Wipe", role: .destructive) { performWipe() }
            } message: {
                Text("This will factory-reset \(selectedDeviceIds.count) device(s)\(wipeOptions.keepUserData ? ", keeping user data where the platform allows" : ", erasing all data"). This cannot be undone.")
            }
            .alert("Confirm Retire", isPresented: $showRetireConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Retire", role: .destructive) { performRetire() }
            } message: {
                Text("This will remove company data and unenroll \(selectedDeviceIds.count) device(s), leaving personal data intact.")
            }
            .alert("Confirm Fresh Start", isPresented: $showFreshStartConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Fresh Start", role: .destructive) { performFreshStart() }
            } message: {
                Text("This will reinstall Windows on \(windowsSelection.count) device(s)\(freshStartKeepUserData ? ", preserving user data" : ", removing user data"). Preinstalled OEM apps are removed and the device stays enrolled.")
            }
            .alert("Confirm Offboard", isPresented: $showOffboardConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Offboard", role: .destructive) { performOffboard() }
            } message: {
                Text(offboardSummary)
            }
    }

    var body: some View {
        actionAlerts(mainContent)
        .onAppCommand { command in
            switch command {
            case .refresh:       loadDevices()
            case .toggleFilters: showFilters.toggle()
            case .clearFilters:  filters.clearAll()
            default:             break
            }
        }
        .searchable(text: $searchText, prompt: "Search devices...")
        .findFocusesSearchField()
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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

                Button(action: loadDevices) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }

    private func selectAllVisible() {
        for device in filteredDevices {
            selectedDeviceIds.insert(device.id)
        }
    }

    /// Build a sortable column header label with sort indicator
    private func deviceSortHeader(_ title: String, field: DeviceSortField) -> String {
        if sortField == field {
            return "\(title) \(sortAscending ? "▲" : "▼")"
        }
        return title
    }

    /// Apply a dashboard widget's deep-linked filter (e.g. a Compliance wedge).
    private func consumeModuleFilter() {
        guard let link = appState.navigateToModuleFilter, link.tab == .devices,
              let category = DeviceFilterCategory(rawValue: link.category) else { return }
        appState.navigateToModuleFilter = nil
        filters.selectedValues[category] = [resolveFilterValue(link.value, in: filters.availableValues[category])]
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
            actionMessage = "Syncing \(selectedDeviceIds.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                let results = try await appState.graphService.syncDevices(Array(selectedDeviceIds))
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
            actionMessage = "Rebooting \(selectedDeviceIds.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                let results = try await appState.graphService.rebootDevices(Array(selectedDeviceIds))
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
            actionMessage = "Locking \(selectedDeviceIds.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                let pin = lockPin.isEmpty ? nil : lockPin
                let results = try await appState.graphService.remoteLockDevices(Array(selectedDeviceIds), pin: pin)
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
            actionMessage = "Wiping \(selectedDeviceIds.count) device(s)..."
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

    private func performOffboard() {
        let targets = selectedDevices
        guard !targets.isEmpty else { return }

        Task {
            isPerformingAction = true
            actionMessage = "Offboarding \(targets.count) device(s)..."
            offboardResults = []
            defer { isPerformingAction = false }

            var plan = offboardPlan
            plan.wipeOptions = wipeOptions

            let results = await appState.graphService.offboardDevices(targets, plan: plan)
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
            actionMessage = "Retiring \(selectedDeviceIds.count) device(s)..."
            defer { isPerformingAction = false }

            do {
                let results = try await appState.graphService.retireDevices(Array(selectedDeviceIds))
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
            actionMessage = "Triggering app reinstall on \(selectedDeviceIds.count) device(s)..."
            defer { isPerformingAction = false }
            
            do {
                // Reinstall is triggered via sync which re-evaluates app assignments
                let results = try await appState.graphService.syncDevices(Array(selectedDeviceIds))
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
        guard let dateString = dateString else { return "-" }
        return String(dateString.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

// MARK: - Device Actions Panel

struct DeviceActionsPanel: View {
    let selectedDevices: [IntuneDevice]
    @Binding var isPerformingAction: Bool
    @Binding var actionMessage: String?
    @Binding var lockPin: String
    @Binding var showLockConfirmation: Bool
    @Binding var showRebootConfirmation: Bool
    @Binding var showWipeConfirmation: Bool
    @Binding var showRetireConfirmation: Bool
    @Binding var showFreshStartConfirmation: Bool
    @Binding var showOffboardConfirmation: Bool
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
                Text("\(selectedDevices.count) device(s) selected")
                    .appFont(.subheadline)
                    .fontWeight(.medium)
                
                if selectedDevices.count <= 3 {
                    ForEach(selectedDevices, id: \.id) { device in
                        Text(device.deviceName ?? device.serialNumber ?? "Unknown")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("\(selectedDevices.prefix(2).compactMap { $0.deviceName ?? $0.serialNumber }.joined(separator: ", ")) and \(selectedDevices.count - 2) more...")
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
                        .foregroundColor(message.contains("Error") ? .red : .green)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            
            ScrollView {
                VStack(spacing: 0) {
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
            }
            
            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
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
        case .failed: return .red
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
            case "noncompliant": return (.red, "xmark.circle.fill")
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

#Preview {
    DevicesView()
        .environmentObject(AppState())
}
