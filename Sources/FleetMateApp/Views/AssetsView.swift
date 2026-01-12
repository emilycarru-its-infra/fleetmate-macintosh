import SwiftUI
import FleetMateCore

struct AssetsView: View {
    @EnvironmentObject var appState: AppState
    @State private var assets: [SnipeAsset] = []
    @State private var isLoading = false
    @State private var searchText = ""

    var filteredAssets: [SnipeAsset] {
        if searchText.isEmpty {
            return assets
        }
        return assets.filter {
            ($0.name?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.assetTag?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.serial?.localizedCaseInsensitiveContains(searchText) ?? false)
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
                    Text("Snipe-IT asset inventory")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: loadAssets) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search assets...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if appState.config.snipeUrl == nil {
                ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("Snipe-IT is not configured. Set SNIPE_URL and SNIPE_API_KEY in your config.")
                )
            } else if isLoading {
                ProgressView("Loading assets...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredAssets.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(filteredAssets) {
                    TableColumn("Asset Tag") { asset in
                        Text(asset.assetTag ?? "-")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Serial") { asset in
                        Text(asset.serial ?? "-")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Name") { asset in
                        Text(asset.name ?? "-")
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Status") { asset in
                        StatusBadge(status: asset.statusLabel)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Model") { asset in
                        Text(asset.model?.name ?? "-")
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("Location") { asset in
                        Text(asset.location?.name ?? "-")
                    }
                    .width(min: 100, ideal: 150)
                }
            }
        }
        .task {
            if assets.isEmpty {
                loadAssets()
            }
        }
    }

    private func loadAssets() {
        guard appState.config.snipeUrl != nil else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                assets = try await appState.snipeService.getAssets()
            } catch {
                appState.errorMessage = "Failed to load assets: \(error.localizedDescription)"
            }
        }
    }
}

struct StatusBadge: View {
    let status: SnipeStatusLabel?

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
