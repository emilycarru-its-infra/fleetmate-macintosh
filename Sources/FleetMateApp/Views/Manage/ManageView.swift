import SwiftUI
import FleetMateCore

/// The Manage tab: roster sidebar, the current room's machines, and a
/// detail panel for the one machine that is selected.
struct ManageView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manage: ManageState
    @State private var searchText = ""

    init(manage: ManageState) {
        self.manage = manage
    }

    var body: some View {
        HSplitView {
            ManageSidebarView(manage: manage, searchText: $searchText)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            if manage.hasSelection {
                MachineListView(manage: manage)
                    .frame(minWidth: 420)
            } else {
                emptyState
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }

            if manage.selectedComputerIDs.count == 1, let computer = manage.selectedComputers.first {
                MachineDetailView(manage: manage, computer: computer)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .searchable(text: $searchText, prompt: "Search hostnames, people, serials, asset tags")
        .findFocusesSearchField()
        .onAppCommand { command in
            switch command {
            case .refresh:
                manage.loadRoster()
                if manage.hasSelection { manage.startScan() }
            default:
                break
            }
        }
        .task {
            if manage.roster.isEmpty && manage.rosterError == nil {
                manage.loadRoster()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if let error = manage.rosterError {
                ContentUnavailableView {
                    Label("Roster not loaded", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    SettingsLink { Text("Open Settings") }
                    Button("Reload") { manage.loadRoster() }
                }
            } else if manage.isLoadingRoster {
                ProgressView("Loading roster…")
            } else {
                ContentUnavailableView {
                    Label("Select a room or group", systemImage: "desktopcomputer.and.macbook")
                } description: {
                    Text("Rooms come from the enrollment roster. Command-click to combine rooms and groups, or search to build a target set.")
                }
            }
        }
    }
}
