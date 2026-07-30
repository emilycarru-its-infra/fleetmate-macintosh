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
    @State private var selectedAssetIds: Set<Int> = []
    @State private var lastClickedIndex: Int?
    @State private var showReAllocateSheet = false

    // Column state
    @State private var columnWidths: [AssetSortField: CGFloat] = [
        .assetTag: 120, .serial: 110, .name: 160, .status: 110,
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
                                onClose: { selectedAsset = nil; selectedAssetIds = [] },
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
                        Text("Columns").appFont(.headline).padding(.bottom, 4)
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
                                    selectedAssetIds.contains(asset.id)
                                        ? Color.accentColor.opacity(0.2)
                                        : (idx % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .gesture(TapGesture().modifiers(.command).onEnded {
                                    if selectedAssetIds.contains(asset.id) {
                                        selectedAssetIds.remove(asset.id)
                                        if selectedAsset?.id == asset.id {
                                            selectedAsset = selectedAssetIds.isEmpty ? nil : filteredAssets.first { selectedAssetIds.contains($0.id) }
                                        }
                                    } else {
                                        selectedAssetIds.insert(asset.id)
                                        selectedAsset = asset
                                    }
                                    lastClickedIndex = idx
                                })
                                .gesture(TapGesture().modifiers(.shift).onEnded {
                                    let anchor = lastClickedIndex ?? 0
                                    let range = min(anchor, idx)...max(anchor, idx)
                                    for i in range {
                                        if i < filteredAssets.count {
                                            selectedAssetIds.insert(filteredAssets[i].id)
                                        }
                                    }
                                    selectedAsset = asset
                                })
                                .onTapGesture {
                                    selectedAssetIds = [asset.id]
                                    selectedAsset = asset
                                    lastClickedIndex = idx
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
            if let first = list.first {
                selectedAssetIds = [first.id]
                lastClickedIndex = 0
            }
            return
        }
        let newIndex = min(max(currentIndex + offset, 0), list.count - 1)
        selectedAsset = list[newIndex]
        selectedAssetIds = [list[newIndex].id]
        lastClickedIndex = newIndex
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
                            .appFont(.caption2)
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
                .appFont(.body, design: .monospaced)
                .lineLimit(1)
        case .serial:
            Text(asset.serial ?? "-")
                .appFont(.body, design: .monospaced)
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
            // Hero header: what the asset IS, at a glance — icon, name, the two
            // identifiers everyone copies, and where it stands. The old header
            // was a name and a tag; every other fact was buried in the rows.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: categorySymbol)
                        .appFont(fixed: 22)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.displayName ?? "Unnamed Asset")
                            .appFont(.title3, weight: .semibold)
                            .lineLimit(2)
                        if let model = asset.model?.name {
                            Text(model)
                                .appFont(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if asset.assignedTo != nil || asset.statusLabel?.statusMeta == "deployable" {
                        Button(action: onReAllocate) {
                            Label("Re-Allocate", systemImage: "person.2.arrow.trianglehead.counterclockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
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

                // Identity line: tag and serial as copyable chips, status pill,
                // and who/where — the four questions every lookup starts with.
                HStack(spacing: 8) {
                    if let tag = asset.assetTag {
                        identityChip(tag, help: "Copy asset tag")
                    }
                    if let serial = asset.serial {
                        identityChip(serial, help: "Copy serial number")
                    }
                    StatusBadge(status: asset.statusLabel)
                    Spacer()
                }

                if asset.assignedTo?.name != nil || asset.location?.name != nil {
                    HStack(spacing: 14) {
                        if let who = asset.assignedTo?.name {
                            Label(who, systemImage: "person.fill")
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let place = asset.location?.name {
                            Label(place, systemImage: "mappin.and.ellipse")
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding()

            Divider()

            // Scrollable detail
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Spec chips: the numbers people compare machines by, worn
                    // up front instead of buried among rows.
                    if !specChips.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(specChips, id: \.label) { chip in
                                SpecChip(icon: chip.icon, label: chip.label, value: chip.value)
                            }
                        }
                    }

                    // Status (editable dropdown)
                    sectionCard("Status", systemImage: "circle.dashed") {
                        if !loadedStatusLabels.isEmpty {
                            HStack(alignment: .top) {
                                Text("Status")
                                    .appFont(.callout)
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
                    if asset.assignedTo != nil {
                        sectionCard("Assignment", systemImage: "person.2") {
                            detailRow("Assigned To", value: asset.assignedTo?.name)
                            detailRow("Email", value: asset.assignedTo?.email, copyable: true)
                            detailRow("Employee #", value: asset.assignedTo?.employeeNumber)
                        }
                    }

                    // Hardware: identity rows; the headline specs live in the
                    // chips above, so they don't repeat here.
                    sectionCard("Hardware", systemImage: "cpu") {
                        detailRow("Serial", value: asset.serial, copyable: true, mono: true)
                        detailRow("Model", value: asset.model?.name)
                        detailRow("Category", value: asset.category?.name)
                        detailRow("Manufacturer", value: asset.manufacturer?.name)
                        if let customFields = asset.customFields {
                            ForEach(customFields.sorted(by: { $0.key < $1.key }), id: \.key) { fieldName, field in
                                if hardwareFields.contains(fieldName) && !chipFields.contains(fieldName) {
                                    detailRow(fieldName, value: field.value, copyable: true)
                                }
                            }
                        }
                    }

                    // Management identifiers — long GUIDs, so monospaced.
                    let mgmtFields = managementCustomFields
                    if !mgmtFields.isEmpty {
                        sectionCard("Identifiers", systemImage: "barcode.viewfinder") {
                            ForEach(mgmtFields, id: \.key) { fieldName, field in
                                detailRow(fieldName, value: field.value, copyable: true, mono: true)
                            }
                        }
                    }

                    // Financials section
                    sectionCard("Financials", systemImage: "dollarsign.circle") {
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
                    sectionCard("Location", systemImage: "mappin.and.ellipse") {
                        detailRow("Location", value: asset.location?.name)
                        detailRow("Default Location", value: asset.rtdLocation?.name)
                    }

                    // Dates
                    sectionCard("Dates", systemImage: "calendar") {
                        detailRow("Last Checkout", value: asset.lastCheckout?.formatted)
                        detailRow("Last Audit", value: asset.lastAuditDate?.formatted)
                        detailRow("Next Audit", value: asset.nextAuditDate?.formatted)
                        detailRow("Created", value: asset.createdAt?.formatted)
                        detailRow("Updated", value: asset.updatedAt?.formatted)
                    }

                    if let notes = asset.notes, !notes.isEmpty {
                        sectionCard("Notes", systemImage: "note.text") {
                            Text(notes)
                                .appFont(.callout)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Other custom fields (unmapped)
                    let otherFields = unmappedCustomFields
                    if !otherFields.isEmpty {
                        sectionCard("Other", systemImage: "square.grid.2x2") {
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
                                    .appFont(.caption)
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

    // MARK: - Hero pieces

    /// SF Symbol for the asset's category, so the header says "a desktop"
    /// before a single row is read.
    private var categorySymbol: String {
        let category = (asset.category?.name ?? "").lowercased()
        if category.contains("laptop") { return "laptopcomputer" }
        if category.contains("display") || category.contains("monitor") { return "display" }
        if category.contains("desktop") { return "desktopcomputer" }
        if category.contains("tablet") || category.contains("ipad") { return "ipad" }
        if category.contains("phone") { return "iphone" }
        if category.contains("printer") { return "printer" }
        if category.contains("server") { return "server.rack" }
        if category.contains("network") || category.contains("switch") || category.contains("router") { return "network" }
        if category.contains("camera") { return "camera" }
        if category.contains("audio") || category.contains("speaker") { return "hifispeaker" }
        return "shippingbox"
    }

    private func identityChip(_ value: String, help: String) -> some View {
        Button(action: { copyToClipboard(value) }) {
            HStack(spacing: 4) {
                Text(value)
                    .appFont(.caption, design: .monospaced)
                Image(systemName: "doc.on.doc")
                    .appFont(fixed: 9)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The headline specs, pulled out of the row soup: what people actually
    /// compare machines by.
    private var specChips: [(icon: String, label: String, value: String)] {
        let mapping: [(field: String, icon: String)] = [
            ("Chip", "cpu"),
            ("CPU", "cpu"),
            ("Memory", "memorychip"),
            ("Storage", "internaldrive"),
            ("GPU", "rectangle.3.group"),
            ("Display", "display"),
        ]
        var chips: [(icon: String, label: String, value: String)] = []
        for (field, icon) in mapping {
            if let value = asset.customFieldByName(field)?.value,
               !value.isEmpty, value != "-",
               !chips.contains(where: { $0.label == field }) {
                chips.append((icon: icon, label: field, value: value))
            }
        }
        return chips
    }

    /// Fields shown as chips, excluded from the Hardware card so nothing
    /// appears twice.
    private var chipFields: Set<String> { Set(specChips.map(\.label)) }

    // MARK: - Cards

    @ViewBuilder
    private func sectionCard(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
                Text(title)
                    .appFont(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String?, copyable: Bool = false, mono: Bool = false) -> some View {
        if let value = value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .appFont(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .appFont(.callout, design: mono ? .monospaced : .default)
                    .textSelection(.enabled)
                if copyable {
                    Button(action: { copyToClipboard(value) }) {
                        Image(systemName: "doc.on.doc")
                            .appFont(.caption)
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

// MARK: - Spec Chip

/// One headline spec — "16 GB", "M2 Pro" — as a small labelled tile.
struct SpecChip: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .appFont(fixed: 13)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .appFont(fixed: 9, weight: .medium)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .appFont(fixed: 12, weight: .semibold)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .help("\(label): \(value)")
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
                    .appFont(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            // Asset info
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .appFont(.title2)
                    .foregroundColor(.blue)
                VStack(alignment: .leading) {
                    Text(asset.name ?? "Unnamed")
                        .fontWeight(.medium)
                    Text(asset.assetTag ?? "")
                        .appFont(.caption)
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
                .appFont(.caption)
            }

            Divider()

            // User search
            Text("Assign to:")
                .appFont(.subheadline)
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
                                .appFont(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let dept = user.department?.name {
                            Text(dept)
                                .appFont(.caption)
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
                    .appFont(.caption)
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
                        .appFont(.caption)
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
                .appFont(.callout)
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
                        columnWidths[field] = max(40, startWidth + value.translation.width)
                    }
                    .onEnded { _ in
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
