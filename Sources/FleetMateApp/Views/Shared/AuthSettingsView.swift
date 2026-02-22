import SwiftUI
import FleetMateCore

/// Authentication settings tab — PSSO-style per-system cards with full credential detail.
struct AuthSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // SP Warning Banner
                if appState.authManager.hasServicePrincipalWarning {
                    spWarningBanner
                }

                // Group systems by category
                ForEach(AuthCategory.allCases, id: \.self) { category in
                    let categorySystems = appState.authManager.systems(for: category)
                    if !categorySystems.isEmpty {
                        authCategorySection(category: category, systems: categorySystems)
                    }
                }

                // Refresh All
                HStack {
                    Spacer()
                    Button(action: refreshAll) {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    // MARK: - SP Warning Banner

    private var spWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Service Principal Detected")
                    .font(.headline)
                Text("One or more systems are authenticated as a Service Principal. Actions will appear as the app identity, not your user account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
        .cornerRadius(8)
    }

    // MARK: - Category Section

    private func authCategorySection(category: AuthCategory, systems: [AuthSystemStatus]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .foregroundColor(.secondary)
                Text(category.displayName)
                    .font(.headline)
            }
            ForEach(systems, id: \.systemId) { system in
                authSystemCard(system)
            }
        }
    }

    // MARK: - System Card

    private func authSystemCard(_ system: AuthSystemStatus) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon
            Image(systemName: system.systemId.icon)
                .font(.title2)
                .foregroundColor(colorForState(system.state))
                .frame(width: 32)
                .padding(.top, 2)

            // Main content
            VStack(alignment: .leading, spacing: 6) {
                // Header row: name + status badge + action buttons
                HStack(spacing: 8) {
                    Text(system.systemId.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    statusBadge(system.state)
                    Spacer()
                    actionButtons(for: system)
                }

                // System-specific detail rows
                systemDetail(for: system)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColorForState(system.state), lineWidth: 1))
    }

    // MARK: - Per-System Detail

    @ViewBuilder
    private func systemDetail(for system: AuthSystemStatus) -> some View {
        let cfg = appState.config
        switch system.systemId {

        case .intune:
            detailGrid {
                detailRow("Auth method", "Service Principal (client credentials)")
                if let t  = cfg.graphTenantId   { detailRow("Tenant ID",  shortId(t)) }
                if let id = cfg.devicesGraphId  { detailRow("App (client) ID", shortId(id)) }
                detailRow("Client secret", cfg.devicesGraphSecret != nil ? "● configured" : "✗ missing",
                          cfg.devicesGraphSecret != nil ? .green : .red)
                if let user = system.user { detailRow("Probed as", user) }
                checkedRow(system.lastChecked)
            }

        case .graph:
            detailGrid {
                detailRow("Auth method", "Service Principal (client credentials)")
                if let t  = cfg.graphTenantId    { detailRow("Tenant ID",    shortId(t)) }
                if let id = cfg.devicesGraphId   { detailRow("Devices app",  shortId(id)) }
                if let id = cfg.systemsGraphId   { detailRow("Identity app", shortId(id)) }
                checkedRow(system.lastChecked)
            }

        case .entra:
            detailGrid {
                detailRow("Auth method", "Service Principal (client credentials)")
                if let t  = cfg.graphTenantId   { detailRow("Tenant ID",  shortId(t)) }
                if let id = cfg.systemsGraphId  { detailRow("App (client) ID", shortId(id)) }
                detailRow("Client secret", cfg.systemsGraphSecret != nil ? "● configured" : "✗ missing",
                          cfg.systemsGraphSecret != nil ? .green : .red)
                if let user = system.user { detailRow("Probed as", user) }
                checkedRow(system.lastChecked)
            }

        case .snipe:
            detailGrid {
                detailRow("Auth method", "API key (Bearer token)")
                if let url = cfg.snipeUrl {
                    detailRow("Instance URL", url)
                }
                if let key = cfg.snipeApiKey {
                    detailRow("API key", maskedToken(key))
                } else {
                    detailRow("API key", "✗ missing", .red)
                }
                checkedRow(system.lastChecked)
            }

        case .tdx:
            detailGrid {
                detailRow("Auth method", tdxAuthDescription())
                if let url = cfg.tdxBaseUrl { detailRow("Base URL", url) }
                let tApp = cfg.tdxTicketingAppId ?? cfg.tdxAppId
                let aApp = cfg.tdxAssetsAppId ?? cfg.tdxAppId
                if let a = tApp { detailRow("Ticketing app ID", String(a)) }
                if let a = aApp, a != tApp { detailRow("Assets app ID", String(a)) }
                if let user = appState.tdxSsoAuthenticated ? appState.tdxAuthenticatedUserName : system.user {
                    detailRow("SSO signed in as", user, .green)
                }
                if cfg.tdxBeid != nil {
                    detailRow("Service account", cfg.tdxUsername ?? "configured", .secondary)
                    detailRow("BEID", cfg.tdxBeid.map { shortId($0) } ?? "")
                }
                checkedRow(system.lastChecked)
            }

        case .devops:
            detailGrid {
                detailRow("Auth method", "Platform SSO (OAuth2 PKCE)")
                if let org  = cfg.devopsOrganization { detailRow("Organization", org) }
                if let proj = cfg.devopsProject      { detailRow("Project",      proj) }
                if let user = appState.devOpsSsoAuthenticated ? appState.devOpsSsoUserName : system.user {
                    detailRow("Signed in as", user, .green)
                }
                if case .failed(let msg) = system.state {
                    detailRow("Error", msg, .red)
                }
                checkedRow(system.lastChecked)
            }

        case .github:
            detailGrid {
                detailRow("Auth method", "gh CLI (device/browser flow)")
                if let org  = cfg.tasks?.providers.github?.organization { detailRow("Organization", org) }
                if let num  = cfg.tasks?.providers.github?.projectNumber { detailRow("Project #",  String(num)) }
                if let user = system.user {
                    detailRow("Signed in as", user, .green)
                } else {
                    detailRow("Status", "not logged in — run: gh auth login", .secondary)
                }
                checkedRow(system.lastChecked)
            }

        case .gitea:
            detailGrid {
                detailRow("Auth method", "API token")
                if let url   = cfg.tasks?.providers.gitea?.url   { detailRow("Instance URL", url) }
                if let owner = cfg.tasks?.providers.gitea?.owner { detailRow("Owner",        owner) }
                if let tok   = cfg.tasks?.providers.gitea?.token {
                    detailRow("Token", maskedToken(tok))
                } else {
                    detailRow("Token", "✗ missing", .red)
                }
                checkedRow(system.lastChecked)
            }
        }
    }

    // MARK: - Detail Grid Helpers

    @ViewBuilder
    private func detailGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String, _ valueColor: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func checkedRow(_ date: Date?) -> some View {
        Group {
            if let d = date {
                HStack(alignment: .top, spacing: 0) {
                    Text("Last verified")
                        .font(.caption)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .frame(width: 130, alignment: .leading)
                    Text("\(d, style: .relative) ago  (\(d, formatter: timeFormatter))")
                        .font(.caption)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
        }
    }

    // MARK: - Helpers

    private func tdxAuthDescription() -> String {
        switch appState.config.tdxAuthMethod {
        case .browserSSO:     return "Browser SSO (Entra ID / Shibboleth)"
        case .serviceAccount: return "Service account (BEID + WebServicesKey)"
        case .userPassword:   return "Username / password"
        case .auto:
            if appState.tdxSsoAuthenticated { return "Auto → SSO (active)" }
            if appState.config.tdxBeid != nil { return "Auto → Service account + SSO available" }
            return "Auto"
        }
    }

    /// Show first 6 + "…" + last 6 characters of a token/key
    private func maskedToken(_ s: String) -> String {
        guard s.count > 16 else { return String(repeating: "●", count: min(s.count, 8)) }
        return "\(s.prefix(6))…\(s.suffix(6))"
    }

    /// Abbreviate a GUID: show first two segments then "…"
    private func shortId(_ s: String) -> String {
        let parts = s.split(separator: "-")
        guard parts.count >= 2 else {
            return s.count > 14 ? "\(s.prefix(14))…" : s
        }
        return "\(parts[0])-\(parts[1])…"
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }

    // MARK: - Status Badge

    private func statusBadge(_ state: AuthTokenState) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForState(state))
                .frame(width: 7, height: 7)
            Text(state.statusLabel)
                .font(.caption)
                .foregroundColor(colorForState(state))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(colorForState(state).opacity(0.1))
        .cornerRadius(4)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for system: AuthSystemStatus) -> some View {
        switch system.systemId {
        case .tdx:
            if case .valid = system.state {
                Button("Sign Out") { appState.signOutTdxSso() }
                    .controlSize(.small)
            } else {
                Button("Sign In") { appState.triggerTdxSsoLogin() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

        case .devops:
            if case .valid = system.state {
                Button("Sign Out") { appState.signOutDevOpsSso() }
                    .controlSize(.small)
            } else {
                Button("Sign In") {
                    appState.triggerDevOpsSsoLogin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .github:
            if case .valid = system.state {
                EmptyView()
            } else {
                Text("gh auth login")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontDesign(.monospaced)
            }

        case .graph, .intune, .entra, .snipe, .gitea:
            EmptyView()
        }
    }

    // MARK: - Colors

    private func colorForState(_ state: AuthTokenState) -> Color {
        switch state {
        case .valid:             return .green
        case .configured:        return .yellow
        case .authenticating:    return .blue
        case .expired:           return .orange
        case .failed:            return .red
        case .servicePrincipal:  return .orange
        case .notConfigured:     return .gray
        }
    }

    private func borderColorForState(_ state: AuthTokenState) -> Color {
        colorForState(state).opacity(0.3)
    }

    // MARK: - Refresh All

    private func refreshAll() {
        Task {
            await appState.authManager.probeAll(
                graphService: appState.graphService,
                tdxService: appState.tdxService,
                snipeService: appState.snipeService,
                devOpsService: appState.devOpsService
            )
        }
    }
}
