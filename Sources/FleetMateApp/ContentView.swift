import SwiftUI
import FleetMateCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .tickets

    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case devices = "Devices"
        case inventory = "Inventory"
        case tickets = "Tickets"
        case boards = "Boards"
        case identity = "Identity"

        var icon: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .devices: return "laptopcomputer"
            case .inventory: return "shippingbox"
            case .tickets: return "ticket"
            case .boards: return "rectangle.split.3x1"
            case .identity: return "person.2"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.caption)
                            Text(tab.rawValue)
                                .font(.caption)
                                .fontWeight(selectedTab == tab ? .semibold : .regular)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .dashboard:
                    DashboardView()
                case .devices:
                    DevicesView()
                case .inventory:
                    AssetsView()
                case .tickets:
                    TicketsView()
                case .boards:
                    BoardsView()
                case .identity:
                    IdentityView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
