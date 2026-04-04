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

    var body: some View {
        HSplitView {
            // Main device list
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("Devices")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        HStack {
                            Text("Devices Management Service")
                                .foregroundColor(.secondary)
                            if !selectedDeviceIds.isEmpty {
                                Text("• \(selectedDeviceIds.count) selected")
                                    .foregroundColor(.accentColor)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    Spacer()
                }
                .padding()

                // Selection controls
                HStack {
                    if !selectedDeviceIds.isEmpty || !filteredDevices.isEmpty {
                        Button("Select All") { selectAllVisible() }
                            .disabled(filteredDevices.isEmpty)
                            .controlSize(.small)
                        Button("Clear") { selectedDeviceIds.removeAll() }
                            .disabled(selectedDeviceIds.isEmpty)
                            .controlSize(.small)
                    }
                    Spacer()
                    Text("\(filteredDevices.count) of \(devices.count)")
                        .font(.caption)
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
                                .font(.system(.body, design: .monospaced))
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
        .alert("Confirm Reboot", isPresented: $showRebootConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reboot", role: .destructive) {
                performReboot()
            }
        } message: {
            Text("Are you sure you want to reboot \(selectedDeviceIds.count) device(s)? This will interrupt any active user sessions.")
        }
        .alert("Confirm Lock", isPresented: $showLockConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Lock", role: .destructive) {
                performLock()
            }
        } message: {
            Text("Are you sure you want to lock \(selectedDeviceIds.count) device(s)?")
        }
        .searchable(text: $searchText, prompt: "Search devices...")
        .toolbar { devicesToolbar }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var devicesToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: { showFilters.toggle() }) {
                Label("Filters", systemImage: filters.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                FilterPanelView(filters: filters)
            }

            if filters.hasActiveFilters {
                Button(action: { filters.clearAll() }) {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }

            Button(action: loadDevices) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: .command)
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
    @Binding var availableApps: [MobileApp]
    @Binding var selectedAppId: String?
    @Binding var appSearchText: String
    
    let onSync: () -> Void
    let onReboot: () -> Void
    let onLock: () -> Void
    let onLoadApps: () -> Void
    let onReinstallApp: () -> Void
    
    @State private var expandedSections: Set<String> = ["sync", "restart", "lock", "app", "update"]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Device Actions")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            
            // Selected devices summary
            VStack(alignment: .leading, spacing: 4) {
                Text("\(selectedDevices.count) device(s) selected")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if selectedDevices.count <= 3 {
                    ForEach(selectedDevices, id: \.id) { device in
                        Text(device.deviceName ?? device.serialNumber ?? "Unknown")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("\(selectedDevices.prefix(2).compactMap { $0.deviceName ?? $0.serialNumber }.joined(separator: ", ")) and \(selectedDevices.count - 2) more...")
                        .font(.caption)
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
                        .font(.caption)
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
                                .font(.caption)
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
                                .font(.caption)
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
                                .font(.caption)
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
                    
                    // App Reinstall Section
                    ActionAccordion(
                        title: "Reinstall App",
                        icon: "arrow.down.app.fill",
                        isExpanded: expandedSections.contains("app"),
                        onToggle: { toggleSection("app") }
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Trigger app reinstallation by initiating a device sync. Select an app to reinstall.")
                                .font(.caption)
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
                                .font(.caption)
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
                .font(.caption)
        }
    }
}

#Preview {
    DevicesView()
        .environmentObject(AppState())
}
