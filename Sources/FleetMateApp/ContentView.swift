import SwiftUI
import FleetMateCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .dashboard
    /// Tracks whether we've already auto-prompted Phase 2 SSO for this session
    @State private var hasAutoPromptedSso = false
    @State private var hasAutoPromptedDevOpsSso = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: AppTab.dashboard.icon, value: .dashboard) {
                DashboardView()
            }
            Tab("Devices", systemImage: AppTab.devices.icon, value: .devices) {
                DevicesView()
            }
            Tab("Inventory", systemImage: AppTab.inventory.icon, value: .inventory) {
                AssetsView()
            }
            Tab("Tickets", systemImage: AppTab.tickets.icon, value: .tickets) {
                TicketsView()
            }
            Tab("Projects", systemImage: AppTab.projects.icon, value: .projects) {
                BoardsView()
            }
            Tab("Identity", systemImage: AppTab.identity.icon, value: .identity) {
                IdentityView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 1000, minHeight: 600)
        .toolbar {
            if appState.authManager.hasServicePrincipalWarning {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 11))
                        Text("SP")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 4))
                    .help("One or more systems are logged in as a Service Principal")
                }
            }
        }
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
            if let tab = newTab {
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
