import SwiftUI
import FleetMateCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .dashboard

    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case management = "Management"
        case assets = "Assets"
        case tickets = "Tickets"
        case tasks = "Tasks"
        case boards = "Boards"
        case users = "Users"
        case groups = "Groups"

        var icon: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .management: return "laptopcomputer"
            case .assets: return "shippingbox"
            case .tickets: return "ticket"
            case .tasks: return "list.bullet.clipboard"
            case .boards: return "rectangle.split.3x1"
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
                case .management:
                    DevicesView()
                case .assets:
                    AssetsView()
                case .tickets:
                    TicketsView()
                case .tasks:
                    WorkItemsView()
                case .boards:
                    BoardsView()
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
