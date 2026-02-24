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

struct AssetsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sortField: AssetSortField = .assetTag
    @State private var sortAscending = true
    @State private var selectedAsset: SnipeAsset?
    @State private var showReAllocateSheet = false

    // Filter states
    @State private var statusFilter = "All"
    @State private var categoryFilter = "All"
    @State private var platformFilter = "All"
    @State private var manufacturerFilter = "All"
    @State private var modelFilter = "All"
    @State private var usageFilter = "All"
    @State private var catalogFilter = "All"
    @State private var areaFilter = "All"

    // Use cached assets from appState
    var assets: [SnipeAsset] { appState.cachedAssets }

    // MARK: - Filter Options

    var statusOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let s = a.statusLabel?.statusMeta, !s.isEmpty { opts.insert(s.capitalized) }
        }
        return ["All"] + opts.sorted()
    }

    var categoryOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let c = a.category?.name, !c.isEmpty { opts.insert(c) }
        }
        return ["All"] + opts.sorted()
    }

    var platformOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let v = a.customFieldByName("Platform")?.value, !v.isEmpty { opts.insert(v) }
        }
        return ["All"] + opts.sorted()
    }

    var manufacturerOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let m = a.manufacturer?.name, !m.isEmpty { opts.insert(m) }
        }
        return ["All"] + opts.sorted()
    }

    var modelOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let m = a.model?.name, !m.isEmpty { opts.insert(m) }
        }
        return ["All"] + opts.sorted()
    }

    var usageOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let v = a.customFieldByName("Usage")?.value, !v.isEmpty { opts.insert(v) }
        }
        return ["All"] + opts.sorted()
    }

    var catalogOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let v = a.customFieldByName("Catalog")?.value, !v.isEmpty { opts.insert(v) }
        }
        return ["All"] + opts.sorted()
    }

    var areaOptions: [String] {
        var opts = Set<String>()
        for a in assets {
            if let v = a.customFieldByName("Area")?.value, !v.isEmpty { opts.insert(v) }
        }
        return ["All"] + opts.sorted()
    }

    var hasActiveFilters: Bool {
        statusFilter != "All" || categoryFilter != "All" || platformFilter != "All" ||
        manufacturerFilter != "All" || modelFilter != "All" || usageFilter != "All" ||
        catalogFilter != "All" || areaFilter != "All"
    }

    // MARK: - Filtered + Sorted Assets

    var filteredAssets: [SnipeAsset] {
        var result = assets

        if statusFilter != "All" {
            result = result.filter { ($0.statusLabel?.statusMeta ?? "").capitalized == statusFilter }
        }
        if categoryFilter != "All" {
            result = result.filter { $0.category?.name == categoryFilter }
        }
        if platformFilter != "All" {
            result = result.filter { $0.customFieldByName("Platform")?.value == platformFilter }
        }
        if manufacturerFilter != "All" {
            result = result.filter { $0.manufacturer?.name == manufacturerFilter }
        }
        if modelFilter != "All" {
            result = result.filter { $0.model?.name == modelFilter }
        }
        if usageFilter != "All" {
            result = result.filter { $0.customFieldByName("Usage")?.value == usageFilter }
        }
        if catalogFilter != "All" {
            result = result.filter { $0.customFieldByName("Catalog")?.value == catalogFilter }
        }
        if areaFilter != "All" {
            result = result.filter { $0.customFieldByName("Area")?.value == areaFilter }
        }

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
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Inventory")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Assets inventory")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { loadAllAssets() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search bar (constrained width)
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter by serial, asset tag, or name...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: 400)

                if !assets.isEmpty {
                    Text("\(filteredAssets.count) of \(assets.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)

            // Filter dropdowns row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Picker("", selection: $statusFilter) {
                        Text("Status").tag("All")
                        ForEach(statusOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 100, maxWidth: statusFilter != "All" ? 180 : 120)

                    Picker("", selection: $categoryFilter) {
                        Text("Category").tag("All")
                        ForEach(categoryOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 100, maxWidth: categoryFilter != "All" ? 180 : 130)

                    Picker("", selection: $platformFilter) {
                        Text("Platform").tag("All")
                        ForEach(platformOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 100, maxWidth: platformFilter != "All" ? 180 : 120)

                    Picker("", selection: $manufacturerFilter) {
                        Text("Manufacturer").tag("All")
                        ForEach(manufacturerOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 110, maxWidth: manufacturerFilter != "All" ? 200 : 140)

                    Picker("", selection: $modelFilter) {
                        Text("Model").tag("All")
                        ForEach(modelOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 100, maxWidth: modelFilter != "All" ? 200 : 120)

                    Picker("", selection: $usageFilter) {
                        Text("Usage").tag("All")
                        ForEach(usageOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 90, maxWidth: usageFilter != "All" ? 160 : 110)

                    Picker("", selection: $catalogFilter) {
                        Text("Catalog").tag("All")
                        ForEach(catalogOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 100, maxWidth: catalogFilter != "All" ? 180 : 120)

                    Picker("", selection: $areaFilter) {
                        Text("Area").tag("All")
                        ForEach(areaOptions.filter { $0 != "All" }, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 80, maxWidth: areaFilter != "All" ? 160 : 110)

                    if hasActiveFilters {
                        Button(action: {
                            statusFilter = "All"
                            categoryFilter = "All"
                            platformFilter = "All"
                            manufacturerFilter = "All"
                            modelFilter = "All"
                            usageFilter = "All"
                            catalogFilter = "All"
                            areaFilter = "All"
                        }) {
                            Text("Clear Filters")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.yellow)
                        .controlSize(.small)
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

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
            print("[AssetsView] .task - cache valid: \(appState.isAssetsCacheValid), assets count: \(appState.cachedAssets.count)")
            print("[AssetsView] Snipe URL: \(appState.config.snipeUrl ?? "nil"), API Key: \(appState.config.snipeApiKey != nil ? "set" : "nil")")
            print("[AssetsView] isSnipeConfigured: \(appState.config.isSnipeConfigured)")
            if !appState.isAssetsCacheValid || appState.cachedAssets.isEmpty {
                loadAllAssets()
            }
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
    }

    private var assetTableView: some View {
        VStack(spacing: 0) {
            // Sortable column headers
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    assetSortableHeader("Asset Tag", field: .assetTag, width: 90)
                    assetSortableHeader("Serial", field: .serial, width: 100)
                    assetSortableHeader("Name", field: .name, width: 150)
                    assetSortableHeader("Status", field: .status, width: 100)
                    assetSortableHeader("Category", field: .category, width: 100)
                    assetSortableHeader("Platform", field: .platform, width: 90)
                    assetSortableHeader("Manufacturer", field: .manufacturer, width: 110)
                    assetSortableHeader("Model", field: .model, width: 110)
                    assetSortableHeader("Usage", field: .usage, width: 90)
                    assetSortableHeader("Catalog", field: .catalog, width: 90)
                    assetSortableHeader("Area", field: .area, width: 90)
                    assetSortableHeader("Location", field: .location, width: 110)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color.secondary.opacity(0.08))

            Divider()

            List(filteredAssets, selection: $selectedAsset) { asset in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Text(asset.assetTag ?? "-")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text(asset.serial ?? "-")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.name ?? "-")
                            .frame(width: 150, alignment: .leading)
                            .lineLimit(1)
                        StatusBadge(status: asset.statusLabel)
                            .frame(width: 100, alignment: .leading)
                        Text(asset.category?.name ?? "-")
                            .frame(width: 100, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.customFieldByName("Platform")?.value ?? "-")
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.manufacturer?.name ?? "-")
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.model?.name ?? "-")
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.customFieldByName("Usage")?.value ?? "-")
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.customFieldByName("Catalog")?.value ?? "-")
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.customFieldByName("Area")?.value ?? "-")
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Text(asset.location?.name ?? "-")
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                .contentShape(Rectangle())
                .tag(asset)
            }
            .listStyle(.plain)
        }
    }

    /// Clickable sortable column header for assets
    private func assetSortableHeader(_ title: String, field: AssetSortField, width: CGFloat?) -> some View {
        Button(action: {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = true
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
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
                // Step 1: Check in the asset (silent)
                let checkinReq = SnipeCheckinRequest(
                    note: "Re-allocated via FleetMate\(note.isEmpty ? "" : ": \(note)")"
                )
                _ = try await snipeService.checkinAsset(assetId: asset.id, request: checkinReq)

                // Step 2: Check out to new user
                let checkoutReq = SnipeCheckoutRequest(
                    assignedUser: targetUser.id,
                    note: "Re-allocated via FleetMate\(note.isEmpty ? "" : ": \(note)")"
                )
                let result = try await snipeService.checkoutAsset(assetId: asset.id, request: checkoutReq)

                onComplete(result.payload)
            } catch {
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

#Preview {
    AssetsView()
        .environmentObject(AppState())
}
