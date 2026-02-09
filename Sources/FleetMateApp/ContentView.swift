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
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                            Text(tab.rawValue)
                                .font(.system(size: 13))
                                .fontWeight(selectedTab == tab ? .semibold : .regular)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        .onAppear {
            // Auto-trigger TDX SSO if not authenticated and SSO is available
            if !appState.tdxSsoAuthenticated && appState.tdxService.shouldAttemptSso {
                appState.triggerTdxSsoLogin()
            }
        }
        .sheet(isPresented: $appState.showTdxSsoLogin) {
            TdxSsoLoginView(config: appState.config) { result in
                if result.success, let token = result.token {
                    let expiry = Date().addingTimeInterval(23 * 60 * 60)
                    appState.handleTdxSsoSuccess(
                        token: token,
                        expiry: expiry,
                        userId: result.userEmail,
                        userName: result.userName
                    )
                } else {
                    appState.handleTdxSsoFailure(result.error)
                }
            }
        }
        .sheet(isPresented: $appState.showDevOpsSsoLogin) {
            DevOpsSsoLoginView(config: appState.config) { result in
                if result.success, let token = result.token {
                    let expiry = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600))
                    appState.handleDevOpsSsoSuccess(token: token, expiry: expiry, userName: result.userName)
                } else {
                    appState.handleDevOpsSsoFailure(result.error)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
