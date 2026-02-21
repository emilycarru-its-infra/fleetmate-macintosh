import SwiftUI
import FleetMateCore

enum AssetSortField: String, CaseIterable {
    case assetTag = "Asset Tag"
    case serial = "Serial"
    case name = "Name"
    case status = "Status"
    case model = "Model"
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
    
    // Use cached assets from appState
    var assets: [SnipeAsset] { appState.cachedAssets }

    var filteredAssets: [SnipeAsset] {
        let filtered = searchText.isEmpty ? assets : assets.filter {
            ($0.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.assetTag?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.serial?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
        return filtered.sorted { a, b in
            let aVal: String
            let bVal: String
            switch sortField {
            case .assetTag: aVal = a.assetTag ?? ""; bVal = b.assetTag ?? ""
            case .serial: aVal = a.serial ?? ""; bVal = b.serial ?? ""
            case .name: aVal = a.name ?? ""; bVal = b.name ?? ""
            case .status: aVal = a.statusLabel?.name ?? ""; bVal = b.statusLabel?.name ?? ""
            case .model: aVal = a.model?.name ?? ""; bVal = b.model?.name ?? ""
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

            // Search
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
                if !assets.isEmpty {
                    Text("\(filteredAssets.count) of \(assets.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

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
                                onClose: { selectedAsset = nil },
                                onReAllocate: { showReAllocateSheet = true }
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
            HStack(spacing: 0) {
                assetSortableHeader("Asset Tag", field: .assetTag, width: 90)
                assetSortableHeader("Serial", field: .serial, width: 110)
                assetSortableHeader("Name", field: .name, width: nil)
                assetSortableHeader("Status", field: .status, width: 110)
                assetSortableHeader("Model", field: .model, width: 120)
                assetSortableHeader("Location", field: .location, width: 120)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))

            Divider()

            List(filteredAssets, selection: $selectedAsset) { asset in
                HStack(spacing: 0) {
                    Text(asset.assetTag ?? "-")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Text(asset.serial ?? "-")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 110, alignment: .leading)
                    Text(asset.name ?? "-")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    StatusBadge(status: asset.statusLabel)
                        .frame(width: 110, alignment: .leading)
                    Text(asset.model?.name ?? "-")
                        .frame(width: 120, alignment: .leading)
                        .lineLimit(1)
                    Text(asset.location?.name ?? "-")
                        .frame(width: 120, alignment: .leading)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
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

// MARK: - Asset Detail Sidebar

struct AssetDetailSidebar: View {
    let asset: SnipeAsset
    let snipeUrl: String?
    let onClose: () -> Void
    let onReAllocate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with close button
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
                    // Status & Assignment
                    detailSection("Status") {
                        detailRow("Status", value: asset.statusLabel?.name)
                        detailRow("Status Type", value: asset.statusLabel?.statusMeta)
                    }

                    detailSection("Assignment") {
                        detailRow("Assigned To", value: asset.assignedTo?.name)
                        detailRow("Email", value: asset.assignedTo?.email, copyable: true)
                        detailRow("Username", value: asset.assignedTo?.username, copyable: true)
                        detailRow("Employee #", value: asset.assignedTo?.employeeNumber)
                    }

                    // Re-Allocate button
                    if asset.assignedTo != nil || asset.statusLabel?.statusMeta == "deployable" {
                        Button(action: onReAllocate) {
                            Label("Re-Allocate", systemImage: "person.2.arrow.trianglehead.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    }

                    detailSection("Hardware") {
                        detailRow("Serial", value: asset.serial, copyable: true)
                        detailRow("Model", value: asset.model?.name)
                        detailRow("Category", value: asset.category?.name)
                        detailRow("Manufacturer", value: asset.manufacturer?.name)
                    }

                    detailSection("Location") {
                        detailRow("Location", value: asset.location?.name)
                        detailRow("Default Location", value: asset.rtdLocation?.name)
                    }

                    detailSection("Dates") {
                        detailRow("Purchase Date", value: asset.purchaseDate?.formatted)
                        detailRow("Last Checkout", value: asset.lastCheckout?.formatted)
                        detailRow("Last Audit", value: asset.lastAuditDate?.formatted)
                        detailRow("Next Audit", value: asset.nextAuditDate?.formatted)
                        detailRow("Created", value: asset.createdAt?.formatted)
                        detailRow("Updated", value: asset.updatedAt?.formatted)
                    }

                    if let notes = asset.notes, !notes.isEmpty {
                        detailSection("Notes") {
                            Text(notes)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Dynamic custom fields
                    if let customFields = asset.customFields, !customFields.isEmpty {
                        detailSection("Custom Fields") {
                            ForEach(customFields.sorted(by: { $0.key < $1.key }), id: \.key) { fieldName, field in
                                detailRow(fieldName, value: field.value, copyable: true)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
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
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
                if copyable {
                    Button(action: { copyToClipboard(value) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
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
                .font(.caption)
        }
    }
}

#Preview {
    AssetsView()
        .environmentObject(AppState())
}
