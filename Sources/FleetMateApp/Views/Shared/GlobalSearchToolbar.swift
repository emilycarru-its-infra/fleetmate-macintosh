import SwiftUI
import FleetMateCore

/// Where a search hit takes you. Shared by every place the search appears.
@MainActor
enum GlobalSearchRouter {
    static func open(_ hit: GlobalSearchResult, appState: AppState) {
        if let page = hit.handbookPage {
            appState.knowledge.openPage = page
            return
        }
        if let link = hit.link {
            appState.open(link.url)
            return
        }
        switch hit.category {
        case .devices:
            if let deviceId = hit.deviceId { appState.navigateToDeviceId = deviceId }
            appState.navigateToTab = .devices
        case .reporting:
            if let serial = hit.reportingSerial { appState.reporting.openDevice(serial: serial) }
            appState.navigateToTab = .reporting
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
        case .handbook:
            break
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

/// The window's one search field. On a tab with a list it filters that list
/// (⌘F); it also searches everything — devices, assets, tickets, work items,
/// pull requests, issues, commits, pipeline runs, users and groups — with
/// results dropping down beneath it (⌘K). The chip on its left shows and
/// switches which of the two it is doing.
struct GlobalSearchToolbarField: View {
    @EnvironmentObject var appState: AppState
    @State private var query = ""
    @State private var results: [GlobalSearchResult] = []
    @State private var showResults = false
    /// Searching everything rather than filtering the tab's list.
    @State private var everything = false
    @FocusState private var focused: Bool

    private var tabSearch: TabSearchRegistration? { appState.tabSearch }
    private var searchingEverything: Bool { everything || tabSearch == nil }

    private var text: Binding<String> {
        searchingEverything ? $query : $appState.tabSearchText
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focused ? Color.accentColor : .secondary)
                .onTapGesture { focused = true }
            if let tabSearch {
                scopeChip(tabSearch)
            }
            TextField("", text: text, prompt: Text(searchingEverything ? "Search everything" : tabSearch?.prompt ?? "").foregroundStyle(.secondary))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { clear() }
            if text.wrappedValue.isEmpty {
                Text(searchingEverything ? "⌘K" : "⌘F")
                    .appFont(fixed: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .appFont(.body)
        .padding(.horizontal, 10)
        .frame(width: 300, height: 28)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: focused ? 1.5 : 1)
        )
        .help(searchingEverything ? "Search everything (⌘K)" : "Filter this tab (⌘F) · search everything (⌘K)")
        // ⌘K (Edit › Search Everything) puts the cursor here from any tab.
        .onChange(of: appState.globalSearchFocusRequest) { _, _ in
            everything = true
            focused = true
        }
        // ⌘F (Edit › Find) filters the tab, where it has a list to filter.
        .onChange(of: appState.tabSearchFocusRequest) { _, _ in
            everything = false
            focused = true
        }
        // A new tab starts out filtering its own list.
        .onChange(of: appState.selectedTab) { _, _ in
            everything = false
            query = ""
            showResults = false
        }
        // ReportMate's device list loads with the Reporting tab; start it when
        // a search begins so its devices are findable before that tab is opened.
        .onChange(of: focused) { _, isFocused in
            if isFocused { Task { await appState.reporting.loadDevicesForSearch() } }
        }
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
        .task(id: searchingEverything ? query : "") {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard searchingEverything, trimmed.count >= 2 || parseWorkItemId(trimmed) != nil else {
                results = []
                showResults = false
                return
            }
            // Debounce; a newer keystroke cancels this scan.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            results = GlobalSearchScanner.search(trimmed, appState: appState)
            showResults = true
            if appState.reporting.session.devicesLoadedAt == nil {
                await appState.reporting.loadDevicesForSearch()
                guard !Task.isCancelled else { return }
                results = GlobalSearchScanner.search(trimmed, appState: appState)
            }
            if let row = await GlobalSearchRouter.workItemLookup(for: trimmed, appState: appState, existing: results),
               !Task.isCancelled {
                results.insert(row, at: 0)
            }
        }
    }

    /// Names what the field is searching; clicking it switches between the
    /// tab's list and everything, carrying the typed text across.
    private func scopeChip(_ tabSearch: TabSearchRegistration) -> some View {
        Button {
            if everything {
                appState.tabSearchText = query
                query = ""
            } else {
                query = appState.tabSearchText
                appState.tabSearchText = ""
            }
            everything.toggle()
            focused = true
        } label: {
            Text(everything ? "All" : tabSearch.tab.rawValue)
                .appFont(fixed: 11, weight: .medium)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(everything ? "Searching everything — click to filter \(tabSearch.tab.rawValue)" : "Filtering \(tabSearch.tab.rawValue) — click to search everything")
    }

    private func submit() {
        if searchingEverything {
            if let first = results.first { open(first) }
        } else {
            tabSearch?.onSubmit?()
        }
    }

    private func open(_ hit: GlobalSearchResult) {
        GlobalSearchRouter.open(hit, appState: appState)
        clear()
    }

    private func clear() {
        if searchingEverything {
            query = ""
            results = []
            showResults = false
        } else {
            appState.tabSearchText = ""
        }
        focused = false
    }
}
