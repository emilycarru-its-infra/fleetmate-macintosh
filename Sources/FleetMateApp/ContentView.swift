import SwiftUI
import FleetMateCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .dashboard

    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case devices = "Devices"
        case assets = "Assets"
        case tickets = "Tickets"
        case workItems = "Work Items"
        case users = "Users"
        case groups = "Groups"

        var icon: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .devices: return "laptopcomputer"
            case .assets: return "shippingbox"
            case .tickets: return "ticket"
            case .workItems: return "list.bullet.clipboard"
            case .users: return "person"
            case .groups: return "person.3"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .navigationTitle("FleetMate")
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedTab {
                case .dashboard:
                    DashboardView()
                case .devices:
                    DevicesView()
                case .assets:
                    AssetsView()
                case .tickets:
                    TicketsView()
                case .workItems:
                    WorkItemsView()
                case .users:
                    UsersView()
                case .groups:
                    GroupsView()
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
