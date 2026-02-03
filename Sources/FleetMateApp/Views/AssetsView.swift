import SwiftUI
import FleetMateCore

enum AssetSortField: String, CaseIterable {
    case assetTag = "Asset Tag"
    case serial = "Serial"
    case name = "Name"
}

struct AssetsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sortField: AssetSortField = .assetTag
    @State private var sortAscending = true
    
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
            }
            return sortAscending ? aVal.localizedCompare(bVal) == .orderedAscending : aVal.localizedCompare(bVal) == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Assets")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Inventory assets (Snipe-IT, ServiceNow, etc.)")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("Sort by", selection: $sortField) {
                    ForEach(AssetSortField.allCases, id: \.self) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                Button(action: { sortAscending.toggle() }) {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(sortAscending ? "Ascending" : "Descending")
                Button(action: { loadAllAssets() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search (client-side filter after loading all)
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
            if appState.config.snipeUrl == nil {
                VStack {
                    ContentUnavailableView(
                        "Not Configured",
                        systemImage: "gear.badge.xmark",
                        description: Text("Snipe-IT is not configured. Set SNIPE_URL and SNIPE_API_KEY in your config.")
                    )
                    Spacer()
                }
            } else if isLoading {
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
                Table(filteredAssets) {
                    TableColumn("Asset Tag") { asset in
                        Text(asset.assetTag ?? "-")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Serial") { asset in
                        Text(asset.serial ?? "-")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Name") { asset in
                        Text(asset.name ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Status") { asset in
                        StatusBadge(status: asset.statusLabel)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Model") { asset in
                        Text(asset.model?.name ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("Location") { asset in
                        Text(asset.location?.name ?? "-")
                            .textSelection(.enabled)
                    }
                    .width(min: 100, ideal: 150)
                }
            }
        }
        .task {
            if !appState.isAssetsCacheValid {
                loadAllAssets()
            }
        }
    }

    private func loadAllAssets() {
        guard appState.config.snipeUrl != nil else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let fetchedAssets = try await appState.snipeService.getAllAssets()
                appState.updateAssetsCache(fetchedAssets)
            } catch {
                appState.errorMessage = "Failed to load assets: \(error.localizedDescription)"
            }
        }
    }
}

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
