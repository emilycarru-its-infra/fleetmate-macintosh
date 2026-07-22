import SwiftUI
import FleetMateCore

/// Authentication settings tab — PSSO-style per-system cards with full credential detail.
struct AuthSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingSystem: AuthSystemId?

    // Editable fields (populated when editing starts)
    @State private var editGraphTenantId = ""
    @State private var editDevicesGraphId = ""
    @State private var editDevicesGraphSecret = ""
    @State private var editSystemsGraphId = ""
    @State private var editSystemsGraphSecret = ""
    @State private var editSnipeUrl = ""
    @State private var editSnipeApiKey = ""
    @State private var editTdxBaseUrl = ""
    @State private var editTdxAppId = ""
    @State private var editTdxBeid = ""
    @State private var editTdxWebServicesKey = ""
    @State private var editDevopsOrg = ""
    @State private var editDevopsProject = ""
    @State private var editDevopsClientId = ""
    @State private var editDevopsTenantId = ""

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
        .onReceive(NotificationCenter.default.publisher(for: .editAuthSystem)) { notification in
            if let systemId = notification.object as? AuthSystemId {
                startEditing(systemId)
            }
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

                // Inline edit form
                if editingSystem == system.systemId {
                    Divider().padding(.vertical, 4)
                    inlineEditForm(for: system.systemId)
                }
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
                detailRow("Client secret", cfg.devicesGraphSecret != nil ? "● configured" : "missing",
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
                detailRow("Client secret", cfg.systemsGraphSecret != nil ? "● configured" : "missing",
                          cfg.systemsGraphSecret != nil ? .green : .red)
                if let user = system.user { detailRow("Probed as", user) }
                checkedRow(system.lastChecked)
            }

        case .snipe:
            detailGrid {
                let isSso = cfg.snipeSsoEnabled || cfg.snipeAuthMethod == .browserSSO
                detailRow("Auth method", isSso ? "Platform SSO (Browser)" : "API key (Bearer token)")
                if let url = cfg.snipeUrl {
                    detailRow("Instance URL", url)
                }
                if isSso {
                    if let user = appState.snipeSsoAuthenticated ? appState.snipeAuthenticatedUserName : system.user {
                        detailRow("SSO signed in as", user, .green)
                    }
                } else {
                    if let key = cfg.snipeApiKey {
                        detailRow("API key", maskedToken(key))
                    } else {
                        detailRow("API key", "missing", .red)
                    }
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
                    detailRow("Token", "missing", .red)
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
            // `.auto` uses the service-account loginadmin path; the WKWebView SSO
            // token is not a valid API credential and is no longer preferred.
            if appState.config.tdxBeid != nil { return "Auto → Service account (BEID)" }
            return "Auto → needs BEID + WebServicesKey"
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
        HStack(spacing: 6) {
            // Edit button for systems with editable credentials
            if [.graph, .intune, .snipe, .tdx, .devops].contains(system.systemId) {
                Button {
                    if editingSystem == system.systemId {
                        editingSystem = nil
                    } else {
                        startEditing(system.systemId)
                    }
                } label: {
                    Image(systemName: editingSystem == system.systemId ? "xmark" : "pencil")
                }
                .controlSize(.small)
                .help(editingSystem == system.systemId ? "Cancel editing" : "Edit credentials")
            }

            // SSO / auth action buttons
            switch system.systemId {
            case .snipe:
                if case .valid = system.state {
                    Button("Sign Out") { appState.signOutSnipeSso() }
                        .controlSize(.small)
                } else if case .authenticating = system.state {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry SSO") { appState.attemptSilentSnipeSso() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

            case .tdx:
                if case .valid = system.state {
                    Button("Sign Out") { appState.signOutTdxSso() }
                        .controlSize(.small)
                } else if case .authenticating = system.state {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry SSO") { appState.attemptSilentTdxSso() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

            case .devops:
                if case .valid = system.state {
                    Button("Sign Out") { appState.signOutDevOpsSso() }
                        .controlSize(.small)
                } else if case .authenticating = system.state {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry SSO") { appState.attemptSilentDevOpsSso() }
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

            default:
                EmptyView()
            }
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

    // MARK: - Inline Edit

    private func startEditing(_ systemId: AuthSystemId) {
        let c = appState.config
        switch systemId {
        case .graph:
            editGraphTenantId = c.graphTenantId ?? ""
            editDevicesGraphId = c.devicesGraphId ?? ""
            editDevicesGraphSecret = c.devicesGraphSecret ?? ""
            editSystemsGraphId = c.systemsGraphId ?? ""
            editSystemsGraphSecret = c.systemsGraphSecret ?? ""
        case .snipe:
            editSnipeUrl = c.snipeUrl ?? ""
            editSnipeApiKey = c.snipeApiKey ?? ""
        case .tdx:
            editTdxBaseUrl = c.tdxBaseUrl ?? ""
            editTdxAppId = (c.tdxTicketingAppId ?? c.tdxAppId).map(String.init) ?? ""
            editTdxBeid = c.tdxBeid ?? ""
            editTdxWebServicesKey = c.tdxWebServicesKey ?? ""
        case .devops:
            editDevopsOrg = c.devopsOrganization ?? ""
            editDevopsProject = c.devopsProject ?? ""
            editDevopsClientId = c.devopsClientId ?? ""
            editDevopsTenantId = c.devopsTenantId ?? ""
        default: break
        }
        editingSystem = systemId
    }

    @ViewBuilder
    private func inlineEditForm(for systemId: AuthSystemId) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch systemId {
            case .graph:
                editField("Tenant ID", text: $editGraphTenantId)
                editField("Devices Client ID", text: $editDevicesGraphId)
                editSecureField("Devices Client Secret", text: $editDevicesGraphSecret)
                editField("Systems Client ID", text: $editSystemsGraphId)
                editSecureField("Systems Client Secret", text: $editSystemsGraphSecret)

            case .snipe:
                editField("Instance URL", text: $editSnipeUrl)
                editSecureField("API Key", text: $editSnipeApiKey)

            case .tdx:
                editField("Base URL", text: $editTdxBaseUrl)
                editField("Ticketing App ID", text: $editTdxAppId)
                editSecureField("BEID", text: $editTdxBeid)
                editSecureField("Web Services Key", text: $editTdxWebServicesKey)

            case .devops:
                editField("Organization", text: $editDevopsOrg)
                editField("Project", text: $editDevopsProject)
                editField("OAuth Client ID", text: $editDevopsClientId)
                editField("Tenant ID", text: $editDevopsTenantId)

            default:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel") { editingSystem = nil }
                    .controlSize(.small)
                Button("Save") { saveEdit(systemId) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private func editField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .frame(width: 130, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func editSecureField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .frame(width: 130, alignment: .leading)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func saveEdit(_ systemId: AuthSystemId) {
        var c = appState.config
        switch systemId {
        case .graph:
            c.graphTenantId = editGraphTenantId.nilIfEmpty
            c.devicesGraphId = editDevicesGraphId.nilIfEmpty
            c.devicesGraphSecret = editDevicesGraphSecret.nilIfEmpty
            c.systemsGraphId = editSystemsGraphId.nilIfEmpty
            c.systemsGraphSecret = editSystemsGraphSecret.nilIfEmpty
        case .snipe:
            c.snipeUrl = editSnipeUrl.nilIfEmpty?.ensureHttps
            c.snipeApiKey = editSnipeApiKey.nilIfEmpty
        case .tdx:
            c.tdxBaseUrl = editTdxBaseUrl.nilIfEmpty?.ensureHttps
            c.tdxAppId = Int(editTdxAppId)
            c.tdxTicketingAppId = Int(editTdxAppId)
            c.tdxBeid = editTdxBeid.nilIfEmpty
            c.tdxWebServicesKey = editTdxWebServicesKey.nilIfEmpty
        case .devops:
            c.devopsOrganization = editDevopsOrg.nilIfEmpty
            c.devopsProject = editDevopsProject.nilIfEmpty
            c.devopsClientId = editDevopsClientId.nilIfEmpty
            c.devopsTenantId = editDevopsTenantId.nilIfEmpty
        default: break
        }
        appState.saveConfig(c)
        editingSystem = nil
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    var ensureHttps: String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
        return "https://\(trimmed)"
    }
}
