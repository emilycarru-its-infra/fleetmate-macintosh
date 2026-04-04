import SwiftUI
import FleetMateCore

enum AssetSortField: String, CaseIterable {
    case assetTag = "Asset Tag"
    case serial = "Serial"
    case name = "Name"
    case status = "Status"
    case category = "Category"
    case platform = "Platform"
    case manufacturer = "Manufacturer"
    case model = "Model"
    case usage = "Usage"
    case catalog = "Catalog"
    case area = "Area"
    case location = "Location"
}

// MARK: - Asset Filter Categories

enum AssetFilterCategory: String, FilterCategoryProtocol {
    case status = "Status"
    case category = "Category"
    case platform = "Platform"
    case manufacturer = "Manufacturer"
    case model = "Model"
    case usage = "Usage"
    case catalog = "Catalog"
    case area = "Area"
    case location = "Location"
    var id: String { rawValue }
}

extension FilterState where Category == AssetFilterCategory {
    func buildFromAssets(_ assets: [SnipeAsset]) {
        func extract(_ keyPath: (SnipeAsset) -> String?) -> [String] {
            Array(Set(assets.compactMap(keyPath).filter { !$0.isEmpty })).sorted()
        }
        availableValues[.status] = extract { $0.statusLabel?.statusMeta?.capitalized }
        availableValues[.category] = extract { $0.category?.name }
        availableValues[.platform] = extract { $0.customFieldByName("Platform")?.value }
        availableValues[.manufacturer] = extract { $0.manufacturer?.name }
        availableValues[.model] = extract { $0.model?.name }
        availableValues[.usage] = extract { $0.customFieldByName("Usage")?.value }
        availableValues[.catalog] = extract { $0.customFieldByName("Catalog")?.value }
        availableValues[.area] = extract { $0.customFieldByName("Area")?.value }
        availableValues[.location] = extract { $0.location?.name }
    }

    func matches(_ asset: SnipeAsset) -> Bool {
        for (category, selected) in selectedValues where !selected.isEmpty {
            let value: String?
            switch category {
            case .status:       value = asset.statusLabel?.statusMeta?.capitalized
            case .category:     value = asset.category?.name
            case .platform:     value = asset.customFieldByName("Platform")?.value
            case .manufacturer: value = asset.manufacturer?.name
            case .model:        value = asset.model?.name
            case .usage:        value = asset.customFieldByName("Usage")?.value
            case .catalog:      value = asset.customFieldByName("Catalog")?.value
            case .area:         value = asset.customFieldByName("Area")?.value
            case .location:     value = asset.location?.name
            }
            if let v = value, !selected.contains(v) { return false }
            if value == nil { return false }
        }
        return true
    }
}

struct AssetsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sortField: AssetSortField = .assetTag
    @State private var sortAscending = true
    @State private var selectedAsset: SnipeAsset?
    @State private var showReAllocateSheet = false

    // Column state
    @State private var columnWidths: [AssetSortField: CGFloat] = [
        .assetTag: 90, .serial: 110, .name: 160, .status: 110,
        .category: 110, .platform: 100, .manufacturer: 120, .model: 120,
        .usage: 100, .catalog: 100, .area: 100, .location: 120
    ]
    @State private var visibleColumns: Set<AssetSortField> = Set(AssetSortField.allCases)
    @State private var showColumnPicker = false

    // New filter system
    @State private var filters = FilterState<AssetFilterCategory>()
    @State private var showFilters = false

    // Use cached assets from appState
    var assets: [SnipeAsset] { appState.cachedAssets }

    // MARK: - Filtered + Sorted Assets

    var filteredAssets: [SnipeAsset] {
        var result = assets

        // Apply filter panel selections
        if filters.hasActiveFilters {
            result = result.filter { filters.matches($0) }
        }

        // Text search
        if !searchText.isEmpty {
            result = result.filter {
                ($0.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.assetTag?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.serial?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result.sorted { a, b in
            let aVal: String
            let bVal: String
            switch sortField {
            case .assetTag: aVal = a.assetTag ?? ""; bVal = b.assetTag ?? ""
            case .serial: aVal = a.serial ?? ""; bVal = b.serial ?? ""
            case .name: aVal = a.name ?? ""; bVal = b.name ?? ""
            case .status: aVal = a.statusLabel?.name ?? ""; bVal = b.statusLabel?.name ?? ""
            case .category: aVal = a.category?.name ?? ""; bVal = b.category?.name ?? ""
            case .platform: aVal = a.customFieldByName("Platform")?.value ?? ""; bVal = b.customFieldByName("Platform")?.value ?? ""
            case .manufacturer: aVal = a.manufacturer?.name ?? ""; bVal = b.manufacturer?.name ?? ""
            case .model: aVal = a.model?.name ?? ""; bVal = b.model?.name ?? ""
            case .usage: aVal = a.customFieldByName("Usage")?.value ?? ""; bVal = b.customFieldByName("Usage")?.value ?? ""
            case .catalog: aVal = a.customFieldByName("Catalog")?.value ?? ""; bVal = b.customFieldByName("Catalog")?.value ?? ""
            case .area: aVal = a.customFieldByName("Area")?.value ?? ""; bVal = b.customFieldByName("Area")?.value ?? ""
            case .location: aVal = a.location?.name ?? ""; bVal = b.location?.name ?? ""
            }
            return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content
            if !appState.config.isSnipeConfigured {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Snipe-IT is not configured. Set SNIPE_URL and SNIPE_API_KEY in your config.")
                    )
                    Spacer()
                }
            } else if isLoading && appState.cachedAssets.isEmpty {
                VStack {
                    ProgressView("Loading all assets...")
                        .padding(.top, 50)
                    Spacer()
                }
            } else if filteredAssets.isEmpty && !searchText.isEmpty {
                VStack {
                    ContentUnavailableView.search(text: searchText)
                    Spacer()
                }
                .padding(.top, 30)
            } else if assets.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No Assets",
                        systemImage: "tray",
                        description: Text("No assets found in Snipe-IT.")
                    )
                    Spacer()
                }
                .padding(.top, 30)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Asset table (60%)
                        assetTableView
                            .frame(width: selectedAsset != nil ? geometry.size.width * 0.6 : geometry.size.width)

                        // Detail sidebar (40%)
                        if let asset = selectedAsset {
                            Divider()
                            AssetDetailSidebar(
                                asset: asset,
                                snipeUrl: appState.config.snipeUrl,
                                snipeService: appState.snipeService,
                                onClose: { selectedAsset = nil },
                                onReAllocate: { showReAllocateSheet = true },
                                onSaved: { loadAllAssets() }
                            )
                            .frame(width: geometry.size.width * 0.4)
                        }
                    }
                }
            }
        }
        .task {
            if !appState.isAssetsCacheValid || appState.cachedAssets.isEmpty {
                loadAllAssets()
            }
            if !appState.cachedAssets.isEmpty {
                filters.buildFromAssets(appState.cachedAssets)
            }
        }
        .onChange(of: appState.navigateToFilter) { _, filter in
            if let filter, !filter.isEmpty {
                filters.selectedValues[.status] = [filter]
                appState.navigateToFilter = nil
            }
        }
        .onChange(of: appState.cachedAssets) { _, newAssets in
            filters.buildFromAssets(newAssets)
        }
        .sheet(isPresented: $showReAllocateSheet) {
            if let asset = selectedAsset {
                ReAllocateSheet(
                    asset: asset,
                    snipeService: appState.snipeService,
                    onComplete: { updatedAsset in
                        showReAllocateSheet = false
                        // Refresh the cache after re-allocation
                        loadAllAssets()
                    }
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search assets...")
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

                Button(action: { loadAllAssets() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)

                Button(action: { showColumnPicker.toggle() }) {
                    Label("Columns", systemImage: "tablecells.badge.ellipsis")
                }
                .popover(isPresented: $showColumnPicker, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Columns").font(.headline).padding(.bottom, 4)
                        ForEach(AssetSortField.allCases, id: \.self) { field in
                            Toggle(field.rawValue, isOn: Binding(
                                get: { visibleColumns.contains(field) },
                                set: { on in
                                    if on { visibleColumns.insert(field) }
                                    else if visibleColumns.count > 1 { visibleColumns.remove(field) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding()
                    .frame(minWidth: 180)
                }
            }
        }
    }

    // Ordered list of visible columns with their current widths
    private var visibleColumnList: [(field: AssetSortField, width: CGFloat)] {
        AssetSortField.allCases
            .filter { visibleColumns.contains($0) }
            .map { ($0, columnWidths[$0] ?? 90) }
    }

    private var assetTableView: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                let cols = visibleColumnList
                let totalW = cols.reduce(0) { $0 + $1.width }
                VStack(spacing: 0) {
                    // Synchronized column headers
                    HStack(spacing: 0) {
                        ForEach(cols, id: \.field) { col in
                            assetColumnHeader(col.field, width: col.width)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: max(totalW, geo.size.width))
                    .frame(height: 32)
                    .background(Color.secondary.opacity(0.08))

                    Divider()

                    // Data rows — vertical scroll inside the horizontal scroll so both axes sync
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredAssets.enumerated()), id: \.element.id) { idx, asset in
                                HStack(spacing: 0) {
                                    ForEach(cols, id: \.field) { col in
                                        assetCell(for: col.field, asset: asset)
                                            .frame(width: col.width - 12, alignment: .leading)
                                            .padding(.leading, 10)
                                            .padding(.trailing, 2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(minWidth: max(totalW, geo.size.width))
                                .frame(height: 28)
                                .background(
                                    selectedAsset?.id == asset.id
                                        ? Color.accentColor.opacity(0.2)
                                        : (idx % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAsset = selectedAsset?.id == asset.id ? nil : asset
                                }
                                Divider().padding(.leading, 8)
                            }
                        }
                    }
                    .frame(height: max(100, geo.size.height - 33))
                    .frame(minWidth: max(totalW, geo.size.width))
                }
            }
            .focusable()
            .onKeyPress(.upArrow) { moveAssetSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { moveAssetSelection(by: 1); return .handled }
        }
    }

    private func moveAssetSelection(by offset: Int) {
        let list = filteredAssets
        guard !list.isEmpty else { return }
        guard let current = selectedAsset,
              let currentIndex = list.firstIndex(where: { $0.id == current.id }) else {
            selectedAsset = list.first
            return
        }
        let newIndex = min(max(currentIndex + offset, 0), list.count - 1)
        selectedAsset = list[newIndex]
    }

    @ViewBuilder
    private func assetColumnHeader(_ field: AssetSortField, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                if sortField == field { sortAscending.toggle() }
                else { sortField = field; sortAscending = true }
            }) {
                HStack(spacing: 3) {
                    Text(field.rawValue)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if sortField == field {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: width - 12, alignment: .leading)
                .padding(.leading, 10)
                .padding(.trailing, 2)
            }
            .buttonStyle(.plain)
            ColumnResizeHandle(field: field, columnWidths: $columnWidths)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func assetCell(for field: AssetSortField, asset: SnipeAsset) -> some View {
        switch field {
        case .assetTag:
            Text(asset.assetTag ?? "-")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        case .serial:
            Text(asset.serial ?? "-")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        case .name:
            Text(asset.displayName ?? "-").lineLimit(1)
        case .status:
            StatusBadge(status: asset.statusLabel)
        case .category:
            Text(asset.category?.name ?? "-").lineLimit(1)
        case .platform:
            Text(asset.customFieldByName("Platform")?.value ?? "-").lineLimit(1)
        case .manufacturer:
            Text(asset.manufacturer?.name ?? "-").lineLimit(1)
        case .model:
            Text(asset.model?.name ?? "-").lineLimit(1)
        case .usage:
            Text(asset.customFieldByName("Usage")?.value ?? "-").lineLimit(1)
        case .catalog:
            Text(asset.customFieldByName("Catalog")?.value ?? "-").lineLimit(1)
        case .area:
            Text(asset.customFieldByName("Area")?.value ?? "-").lineLimit(1)
        case .location:
            Text(asset.location?.name?.htmlDecoded ?? "-").lineLimit(1)
        }
    }

    private func loadAllAssets() {
        guard appState.config.isSnipeConfigured else { 
            print("[AssetsView] Snipe not configured")
            return 
        }

        print("[AssetsView] Loading assets...")
        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let fetchedAssets = try await appState.snipeService.getAllAssets()
                print("[AssetsView] Loaded \(fetchedAssets.count) assets")
                appState.updateAssetsCache(fetchedAssets)
            } catch {
                print("[AssetsView] Failed to load assets: \(error.localizedDescription)")
                appState.errorMessage = "Failed to load assets: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Custom Field Section Mapping

private let hardwareFields = Set(["Platform", "Chip", "CPU", "GPU", "NPU", "Memory", "Storage", "Display"])
private let managementFields = Set(["Micro ID", "Intune ID", "Object ID"])
private let financialFields = Set(["Invoice Number", "PO Number", "Lease Contract ID", "Lease Contract Name",
                                    "Lease End Date", "Ownership Type", "Purchase Cost", "Purchase Date"])
private let hiddenFields = Set(["Username"])

// MARK: - Asset Detail Sidebar

struct AssetDetailSidebar: View {
    let asset: SnipeAsset
    let snipeUrl: String?
    let snipeService: SnipeService
    let onClose: () -> Void
    let onReAllocate: () -> Void
    let onSaved: () -> Void

    // Edit state
    @State private var editStatusId: Int? = nil
    @State private var hasEdits = false
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var saveSucceeded = false

    // Loaded option lists
    @State private var loadedStatusLabels: [SnipeStatusLabel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with close button + Re-Allocate
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name ?? "Unnamed Asset")
                        .font(.headline)
                        .lineLimit(2)
                    if let tag = asset.assetTag {
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button(action: { copyToClipboard(tag) }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Copy asset tag")
                        }
                    }
                }
                Spacer()
                // Re-Allocate button (top right)
                if asset.assignedTo != nil || asset.statusLabel?.statusMeta == "deployable" {
                    Button(action: onReAllocate) {
                        Label("Re-Allocate", systemImage: "person.2.arrow.trianglehead.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                // Open in Snipe-IT
                if let snipeUrl = snipeUrl, let assetId = Optional(asset.id) {
                    Button(action: {
                        if let url = URL(string: "\(snipeUrl)/hardware/\(assetId)") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open in Snipe-IT")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Scrollable detail
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status (editable dropdown)
                    detailSection("Status") {
                        if !loadedStatusLabels.isEmpty {
                            HStack(alignment: .top) {
                                Text("Status")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { editStatusId ?? asset.statusLabel?.id ?? 0 },
                                    set: { editStatusId = $0; hasEdits = true }
                                )) {
                                    ForEach(loadedStatusLabels, id: \.id) { label in
                                        Text(label.name ?? "Unknown").tag(label.id)
                                    }
                                }
                                .labelsHidden()
                                Spacer()
                            }
                        } else {
                            detailRow("Status", value: asset.statusLabel?.name)
                        }
                        detailRow("Status Type", value: asset.statusLabel?.statusMeta)
                    }

                    // Assignment (Username hidden)
                    detailSection("Assignment") {
                        detailRow("Assigned To", value: asset.assignedTo?.name)
                        detailRow("Email", value: asset.assignedTo?.email, copyable: true)
                        detailRow("Employee #", value: asset.assignedTo?.employeeNumber)
                    }

                    // Hardware section (standard + custom fields)
                    detailSection("Hardware") {
                        detailRow("Serial", value: asset.serial, copyable: true)
                        detailRow("Model", value: asset.model?.name)
                        detailRow("Category", value: asset.category?.name)
                        detailRow("Manufacturer", value: asset.manufacturer?.name)
                        // Custom hardware fields
                        if let customFields = asset.customFields {
                            ForEach(customFields.sorted(by: { $0.key < $1.key }), id: \.key) { fieldName, field in
                                if hardwareFields.contains(fieldName) {
                                    detailRow(fieldName, value: field.value, copyable: true)
                                }
                            }
                        }
                    }

                    // Management section
                    let mgmtFields = managementCustomFields
                    if !mgmtFields.isEmpty {
                        detailSection("Management") {
                            ForEach(mgmtFields, id: \.key) { fieldName, field in
                                detailRow(fieldName, value: field.value, copyable: true)
                            }
                        }
                    }

                    // Financials section
                    detailSection("Financials") {
                        detailRow("Purchase Cost", value: asset.purchaseCost)
                        detailRow("Purchase Date", value: asset.purchaseDate?.formatted)
                        if let customFields = asset.customFields {
                            ForEach(customFields.sorted(by: { $0.key < $1.key }), id: \.key) { fieldName, field in
                                if financialFields.contains(fieldName) && fieldName != "Purchase Cost" && fieldName != "Purchase Date" {
                                    detailRow(fieldName, value: field.value, copyable: true)
                                }
                            }
                        }
                    }

                    // Location
                    detailSection("Location") {
                        detailRow("Location", value: asset.location?.name)
                        detailRow("Default Location", value: asset.rtdLocation?.name)
                    }

                    // Dates
                    detailSection("Dates") {
                        detailRow("Last Checkout", value: asset.lastCheckout?.formatted)
                        detailRow("Last Audit", value: asset.lastAuditDate?.formatted)
                        detailRow("Next Audit", value: asset.nextAuditDate?.formatted)
                        detailRow("Created", value: asset.createdAt?.formatted)
                        detailRow("Updated", value: asset.updatedAt?.formatted)
                    }

                    if let notes = asset.notes, !notes.isEmpty {
                        detailSection("Notes") {
                            Text(notes)
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Other custom fields (unmapped)
                    let otherFields = unmappedCustomFields
                    if !otherFields.isEmpty {
                        detailSection("Other") {
                            ForEach(otherFields, id: \.key) { fieldName, field in
                                detailRow(fieldName, value: field.value, copyable: true)
                            }
                        }
                    }

                    // Save button
                    if hasEdits {
                        HStack {
                            Button(action: saveChanges) {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Save Changes")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)

                            if saveSucceeded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                            if let error = saveError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task {
            await loadDropdownOptions()
        }
        .onChange(of: asset.id) { _, _ in
            resetEditState()
            Task { await loadDropdownOptions() }
        }
    }

    // MARK: - Custom Field Grouping

    private var managementCustomFields: [(key: String, value: SnipeCustomField)] {
        guard let customFields = asset.customFields else { return [] }
        return customFields.sorted(by: { $0.key < $1.key })
            .filter { managementFields.contains($0.key) && !($0.value.value?.isEmpty ?? true) }
    }

    private var unmappedCustomFields: [(key: String, value: SnipeCustomField)] {
        guard let customFields = asset.customFields else { return [] }
        let allMapped = hardwareFields.union(managementFields).union(financialFields).union(hiddenFields)
        return customFields.sorted(by: { $0.key < $1.key })
            .filter { !allMapped.contains($0.key) && !($0.value.value?.isEmpty ?? true) }
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String?, copyable: Bool = false) -> some View {
        if let value = value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                if copyable {
                    Button(action: { copyToClipboard(value) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
                Spacer()
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Edit / Save

    private func resetEditState() {
        editStatusId = nil
        hasEdits = false
        isSaving = false
        saveError = nil
        saveSucceeded = false
    }

    private func loadDropdownOptions() async {
        do {
            loadedStatusLabels = try await snipeService.getStatusLabels()
        } catch {
            print("[AssetDetailSidebar] Failed to load status labels: \(error)")
        }
    }

    private func saveChanges() {
        guard hasEdits else { return }
        Task {
            isSaving = true
            saveError = nil
            saveSucceeded = false
            defer { isSaving = false }

            do {
                var request = SnipeAssetUpdateRequest()
                if let statusId = editStatusId {
                    request.statusId = statusId
                }
                let response = try await snipeService.updateAsset(assetId: asset.id, request: request)
                if response.status == "error" {
                    saveError = response.messages ?? "Update failed"
                } else {
                    saveSucceeded = true
                    hasEdits = false
                    onSaved()
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - Re-Allocate Sheet

struct ReAllocateSheet: View {
    let asset: SnipeAsset
    let snipeService: SnipeService
    let onComplete: (SnipeAsset?) -> Void

    @State private var searchText = ""
    @State private var users: [SnipeUser] = []
    @State private var selectedUser: SnipeUser?
    @State private var isSearching = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Re-Allocate Asset")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            // Asset info
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundColor(.blue)
                VStack(alignment: .leading) {
                    Text(asset.name ?? "Unnamed")
                        .fontWeight(.medium)
                    Text(asset.assetTag ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            if let currentUser = asset.assignedTo?.name {
                HStack {
                    Label("Currently assigned to:", systemImage: "person")
                    Text(currentUser)
                        .fontWeight(.medium)
                }
                .font(.caption)
            }

            Divider()

            // User search
            Text("Assign to:")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search users by name or username...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { searchUsers() }
                Button("Search") { searchUsers() }
                    .disabled(searchText.isEmpty || isSearching)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            if isSearching {
                ProgressView("Searching...")
            } else if !users.isEmpty {
                List(users, selection: $selectedUser) { user in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(user.fullName)
                                .fontWeight(.medium)
                            Text(user.username ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let dept = user.department?.name {
                            Text(dept)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .tag(user)
                }
                .frame(maxHeight: 200)
                .listStyle(.plain)
            }

            // Note
            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            // Action buttons
            HStack {
                Spacer()
                Button("Re-Allocate") {
                    performReAllocation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedUser == nil || isProcessing)
            }

            if isProcessing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing re-allocation...")
                        .font(.caption)
                }
            }
        }
        .padding()
        .frame(minWidth: 450, minHeight: 500)
    }

    private func searchUsers() {
        guard !searchText.isEmpty else { return }
        Task {
            isSearching = true
            defer { isSearching = false }
            do {
                users = try await snipeService.getUsers(search: searchText)
            } catch {
                errorMessage = "Failed to search users: \(error.localizedDescription)"
            }
        }
    }

    private func performReAllocation() {
        guard let targetUser = selectedUser else { return }
        Task {
            isProcessing = true
            errorMessage = nil
            defer { isProcessing = false }

            do {
                let noteText = "Re-allocated via FleetMate\(note.isEmpty ? "" : ": \(note)")"
                print("[ReAllocate] Starting: asset=\(asset.id) → user=\(targetUser.id) (\(targetUser.username ?? "?"))")

                // Step 1: Check in the asset only if it is currently assigned to someone
                if asset.assignedTo != nil {
                    print("[ReAllocate] Checking in asset \(asset.id)...")
                    let checkinReq = SnipeCheckinRequest(note: noteText)
                    let checkinResult = try await snipeService.checkinAsset(assetId: asset.id, request: checkinReq)
                    print("[ReAllocate] Checkin: status=\(checkinResult.status) msg=\(checkinResult.messages ?? "nil")")
                    if checkinResult.status == "error" {
                        errorMessage = "Check-in failed: \(checkinResult.messages ?? "Unknown error")"
                        return
                    }
                }

                // Step 2: Check out to new user (checkout_to_type required by Snipe-IT)
                print("[ReAllocate] Checking out asset \(asset.id) to user \(targetUser.id)...")
                let checkoutReq = SnipeCheckoutRequest(
                    assignedUser: targetUser.id,
                    checkoutToType: "user",
                    note: noteText
                )
                let result = try await snipeService.checkoutAsset(assetId: asset.id, request: checkoutReq)
                print("[ReAllocate] Checkout: status=\(result.status) msg=\(result.messages ?? "nil")")

                if result.status == "error" {
                    errorMessage = "Checkout failed: \(result.messages ?? "Unknown error")"
                } else {
                    onComplete(result.payload)
                }
            } catch {
                print("[ReAllocate] Error: \(error)")
                errorMessage = "Re-allocation failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: SnipeStatusRef?

    var body: some View {
        let color: Color = {
            switch status?.statusMeta {
            case "deployed": return .green
            case "deployable": return .blue
            case "pending": return .yellow
            case "archived": return .gray
            default: return .secondary
            }
        }()

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status?.name ?? "Unknown")
                .font(.callout)
        }
    }
}

// MARK: - Column Resize Handle

struct ColumnResizeHandle: View {
    let field: AssetSortField
    @Binding var columnWidths: [AssetSortField: CGFloat]
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.5 : 0.25))
            .frame(width: isDragging ? 2 : 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4.5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startWidth = columnWidths[field] ?? 90
                        }
                    }
                    .onEnded { value in
                        // Only update width once at the end — no per-frame re-renders
                        let newWidth = max(40, startWidth + value.translation.width)
                        columnWidths[field] = newWidth
                        isDragging = false
                        startWidth = 0
                    }
            )
            .onHover { inside in
                isHovering = inside
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .frame(width: 10)
    }
}

#Preview {
    AssetsView()
        .environmentObject(AppState())
}
