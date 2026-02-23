import SwiftUI
import FleetMateCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Tab = .dashboard
    /// All tabs are created eagerly so .task fires immediately and data preloads in background
    @State private var createdTabs: Set<Tab> = Set(Tab.allCases)
    /// Tracks whether we've already auto-prompted Phase 2 SSO for this session
    @State private var hasAutoPromptedSso = false
    @State private var hasAutoPromptedDevOpsSso = false

    /// Maps raw tab names (from AppState.navigateToTab) to Tab enum
    private static let tabMap: [String: Tab] = Dictionary(uniqueKeysWithValues: Tab.allCases.map { ($0.rawValue, $0) })

    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case devices = "Devices"
        case inventory = "Inventory"
        case tickets = "Tickets"
        case projects = "Projects"
        case identity = "Identity"

        var icon: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .devices: return "laptopcomputer"
            case .inventory: return "shippingbox"
            case .tickets: return "ticket"
            case .projects: return "list.clipboard"
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
                // SP Warning Badge
                if appState.authManager.hasServicePrincipalWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 11))
                        Text("SP")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(4)
                    .help("One or more systems are logged in as a Service Principal")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content — lazy keep-alive: views are created on first visit and kept alive
            ZStack {
                if createdTabs.contains(.dashboard) {
                    DashboardView()
                        .opacity(selectedTab == .dashboard ? 1 : 0)
                        .allowsHitTesting(selectedTab == .dashboard)
                }
                if createdTabs.contains(.devices) {
                    DevicesView()
                        .opacity(selectedTab == .devices ? 1 : 0)
                        .allowsHitTesting(selectedTab == .devices)
                }
                if createdTabs.contains(.inventory) {
                    AssetsView()
                        .opacity(selectedTab == .inventory ? 1 : 0)
                        .allowsHitTesting(selectedTab == .inventory)
                }
                if createdTabs.contains(.tickets) {
                    TicketsView()
                        .opacity(selectedTab == .tickets ? 1 : 0)
                        .allowsHitTesting(selectedTab == .tickets)
                }
                if createdTabs.contains(.projects) {
                    BoardsView()
                        .opacity(selectedTab == .projects ? 1 : 0)
                        .allowsHitTesting(selectedTab == .projects)
                }
                if createdTabs.contains(.identity) {
                    IdentityView()
                        .opacity(selectedTab == .identity ? 1 : 0)
                        .allowsHitTesting(selectedTab == .identity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear {
            // Phase 1: Attempt silent SSO in the background (no UI).
            // If it fails, Phase 2 interactive login is deferred until the
            // user navigates to a tab that actually needs auth.
            if !appState.tdxSsoAuthenticated && appState.tdxService.shouldAttemptSso {
                appState.attemptSilentTdxSso()
            }
            // DevOps: same 3-phase pattern
            if !appState.devOpsSsoAuthenticated && appState.isDevOpsSsoConfigured {
                appState.attemptSilentDevOpsSso()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Phase 2: Auto-trigger interactive SSO when user first navigates
            // to the Tickets tab and isn't authenticated yet.
            if newTab == .tickets,
               !appState.tdxSsoAuthenticated,
               !hasAutoPromptedSso,
               appState.tdxService.shouldAttemptSso {
                hasAutoPromptedSso = true
                appState.triggerTdxSsoLogin()
            }
            // DevOps: auto-trigger interactive SSO for Projects tab
            if newTab == .projects,
               !appState.devOpsSsoAuthenticated,
               !hasAutoPromptedDevOpsSso,
               appState.isDevOpsSsoConfigured {
                hasAutoPromptedDevOpsSso = true
                appState.triggerDevOpsSsoLogin()
            }
        }
        .onChange(of: appState.navigateToTab) { _, newTab in
            if let name = newTab, let tab = Self.tabMap[name] {
                selectedTab = tab
                appState.navigateToTab = nil
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
            DevOpsSsoLoginView(ssoService: appState.devOpsSsoService, config: appState.config) { result in
                if result.success, let token = result.accessToken {
                    let expiry = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 3600))
                    appState.handleDevOpsSsoSuccess(
                        accessToken: token,
                        expiry: expiry,
                        userName: result.userName,
                        userEmail: result.userEmail
                    )
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
