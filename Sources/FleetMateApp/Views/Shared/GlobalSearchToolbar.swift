import SwiftUI
import FleetMateCore

/// Where a search hit takes you. Shared by every place the search appears.
@MainActor
enum GlobalSearchRouter {
    static func open(_ hit: GlobalSearchResult, appState: AppState) {
        if let link = hit.link {
            appState.open(link.url)
            return
        }
        switch hit.category {
        case .devices:
            if let deviceId = hit.deviceId { appState.navigateToDeviceId = deviceId }
            appState.navigateToTab = .devices
        case .inventory:
            if let assetId = hit.assetId {
                appState.navigateToAssetId = assetId
            } else {
                appState.navigateToInventorySearch = hit.inventoryFilter
            }
            appState.navigateToTab = .inventory
        case .tickets:
            if let ticketId = hit.ticketId { appState.navigateToTicketId = ticketId }
            appState.navigateToTab = .tickets
        case .workItems:
            if let workItemId = hit.workItemId { appState.navigateToWorkItemId = workItemId }
            appState.navigateToTab = .projects
        case .users, .groups:
            appState.navigateToTab = .identity
        case .pullRequests, .issues, .commits, .pipelines:
            appState.navigateToTab = .development
        }
    }

    /// The caches hold only work items this user is already working on, so an
    /// id someone was handed finds nothing; ask Azure DevOps for it directly.
    static func workItemLookup(for query: String, appState: AppState, existing: [GlobalSearchResult]) async -> GlobalSearchResult? {
        guard let id = parseWorkItemId(query) else { return nil }
        guard appState.config.isDevOpsConfigured, appState.devOpsService.hasValidToken else { return nil }
        guard !existing.contains(where: { $0.workItemId == id }) else { return nil }
        guard let item = try? await appState.devOpsService.getWorkItem(id: id) else { return nil }
        return GlobalSearchScanner.row(for: item, matchLabel: "ID: AB#\(id)")
    }
}

/// Search everything, from the toolbar of every tab: devices, assets,
/// tickets, work items, pull requests, issues, commits, pipeline runs, users
/// and groups. ⌘K focuses it; results drop down beneath it.
struct GlobalSearchToolbarField: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [GlobalSearchResult] = []
    @State private var showResults = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search everything", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if let first = results.first { open(first) } }
                .onExitCommand { clear() }
            if !query.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .appFont(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 240)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .help("Search everything (⌘K)")
        .background(
            // ⌘K from anywhere puts the cursor here.
            Button("") { focused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        )
        .popover(isPresented: $showResults, arrowEdge: .bottom) {
            ScrollView {
                if results.isEmpty {
                    Text("No matches.").appFont(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    GlobalSearchResultsPanel(results: results, width: 560) { hit in open(hit) }
                        .padding(8)
                }
            }
            .frame(width: 576)
            .frame(maxHeight: 620)
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 || parseWorkItemId(trimmed) != nil else {
                results = []
                showResults = false
                return
            }
            // Debounce; a newer keystroke cancels this scan.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            results = GlobalSearchScanner.search(trimmed, appState: appState)
            showResults = true
            if let row = await GlobalSearchRouter.workItemLookup(for: trimmed, appState: appState, existing: results),
               !Task.isCancelled {
                results.insert(row, at: 0)
            }
        }
    }

    private func open(_ hit: GlobalSearchResult) {
        GlobalSearchRouter.open(hit, appState: appState)
        clear()
    }

    private func clear() {
        query = ""
        results = []
        showResults = false
        focused = false
    }
}
