import SwiftUI
import FleetMateCore

struct OnboardingSummaryStep: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: OnboardingWizardState
    @Environment(\.dismiss) private var dismiss
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review & Save")
                    .font(.title2.bold())
                Text("Review your configuration before saving.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if wizardState.enableGraph {
                        summaryCard(
                            icon: "shield.checkered",
                            title: "Microsoft Graph",
                            rows: graphSummaryRows
                        )
                    }
                    if wizardState.enableSnipe {
                        summaryCard(
                            icon: "tag",
                            title: "Snipe-IT",
                            rows: snipeSummaryRows
                        )
                    }
                    if wizardState.enableTdx {
                        summaryCard(
                            icon: "ticket",
                            title: "TeamDynamix",
                            rows: tdxSummaryRows
                        )
                    }
                    if wizardState.enableDevOps {
                        summaryCard(
                            icon: "square.stack.3d.up",
                            title: "Azure DevOps",
                            rows: devOpsSummaryRows
                        )
                    }

                    // Test results
                    if !wizardState.testResults.isEmpty {
                        GroupBox("Connection Tests") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(wizardState.testResults) { result in
                                    HStack(spacing: 8) {
                                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(result.success ? .green : .red)
                                        Text(result.service).font(.body.weight(.medium))
                                        Spacer()
                                        Text(result.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            // Action buttons
            HStack {
                Button("Back") { wizardState.goBack() }

                Spacer()

                if wizardState.isTesting {
                    ProgressView().controlSize(.small)
                    Text("Testing...").font(.caption).foregroundStyle(.secondary)
                }

                Button("Save & Finish", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizardState.isTesting)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .task {
            await runTests()
        }
    }

    // MARK: - Summary Row Data

    private var snipeSummaryRows: [(String, String)] {
        let url = ensureHttps(wizardState.snipeUrl)
        var rows: [(String, String)] = [("URL", url)]
        rows.append(("Auth", wizardState.snipeAuthMode.rawValue))
        if wizardState.snipeAuthMode == .apiKey {
            rows.append(("API Key", maskSecret(wizardState.snipeApiKey)))
        }
        return rows
    }

    private var graphSummaryRows: [(String, String)] {
        var rows: [(String, String)] = [("Tenant ID", abbreviateGuid(wizardState.graphTenantId))]
        rows.append(("Auth", wizardState.graphAuthMode.rawValue))
        if wizardState.graphAuthMode == .servicePrincipal {
            if !wizardState.devicesGraphId.isEmpty {
                rows.append(("Devices SP", abbreviateGuid(wizardState.devicesGraphId)))
            }
            if !wizardState.systemsGraphId.isEmpty {
                rows.append(("Systems SP", abbreviateGuid(wizardState.systemsGraphId)))
            }
        }
        return rows
    }

    private var tdxSummaryRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Base URL", wizardState.tdxBaseUrl),
            ("App ID", wizardState.tdxTicketingAppId),
            ("Auth", wizardState.tdxAuthMode.rawValue),
        ]
        if wizardState.tdxAuthMode == .serviceAccount {
            rows.append(("BEID", maskSecret(wizardState.tdxBeid)))
        }
        return rows
    }

    private var devOpsSummaryRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Organization", wizardState.devopsOrganization),
        ]
        if !wizardState.devopsProject.isEmpty {
            rows.append(("Project", wizardState.devopsProject))
        }
        if !wizardState.devopsClientId.isEmpty {
            rows.append(("OAuth Client ID", abbreviateGuid(wizardState.devopsClientId)))
        }
        return rows
    }

    // MARK: - Summary Card

    private func summaryCard(icon: String, title: String, rows: [(String, String)]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(.tint)
                    Text(title).font(.body.weight(.semibold))
                    testResultBadge(for: title)
                    Spacer()
                }
                .padding(.bottom, 2)
                ForEach(rows, id: \.0) { label, value in
                    HStack {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(value)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func testResultBadge(for service: String) -> some View {
        if let result = wizardState.testResults.first(where: { $0.service == service }) {
            Spacer()
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
                .font(.caption)
        }
    }

    // MARK: - Connection Tests

    private func runTests() async {
        wizardState.isTesting = true
        wizardState.testResults = []

        let tempConfig = wizardState.buildConfig(base: appState.config)

        await withTaskGroup(of: ConnectionTestResult.self) { group in
            if wizardState.enableGraph {
                group.addTask { await testGraph(config: tempConfig) }
            }
            if wizardState.enableSnipe {
                group.addTask { await testSnipe(config: tempConfig) }
            }
            if wizardState.enableTdx {
                group.addTask { await testTdx(config: tempConfig) }
            }
            if wizardState.enableDevOps {
                group.addTask { await testDevOps(config: tempConfig) }
            }

            for await result in group {
                wizardState.testResults.append(result)
            }
        }

        wizardState.isTesting = false
    }

    private func testGraph(config: FleetMateConfig) async -> ConnectionTestResult {
        if wizardState.graphAuthMode == .sso {
            // Check if az CLI is available and logged in to the right tenant
            let process = Process()
            let azPath = FileManager.default.fileExists(atPath: "/usr/local/bin/az")
                ? "/usr/local/bin/az"
                : "/opt/homebrew/bin/az"
            process.executableURL = URL(fileURLWithPath: azPath)
            process.arguments = ["account", "show", "--query", "tenantId", "-o", "tsv"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if output.lowercased() == wizardState.graphTenantId.lowercased() {
                        return ConnectionTestResult(service: "Microsoft Graph", success: true, message: "Azure CLI authenticated to correct tenant")
                    } else {
                        return ConnectionTestResult(service: "Microsoft Graph", success: false, message: "CLI tenant (\(output.prefix(8))...) doesn't match")
                    }
                } else {
                    return ConnectionTestResult(service: "Microsoft Graph", success: false, message: "Azure CLI not logged in. Run: az login")
                }
            } catch {
                return ConnectionTestResult(service: "Microsoft Graph", success: false, message: "Azure CLI not found")
            }
        } else {
            // SP mode: try fetching a device
            do {
                let service = GraphService(config: config)
                _ = try await service.getManagedDevices(limit: 1)
                return ConnectionTestResult(service: "Microsoft Graph", success: true, message: "SP authenticated successfully")
            } catch {
                return ConnectionTestResult(service: "Microsoft Graph", success: false, message: error.localizedDescription)
            }
        }
    }

    private func testSnipe(config: FleetMateConfig) async -> ConnectionTestResult {
        if wizardState.snipeAuthMode == .sso {
            // SSO mode: run headless WKWebView SSO and verify API access with cookies
            let urlString = ensureHttps(wizardState.snipeUrl)
            let ssoService = SnipeSsoService(snipeUrl: urlString)

            // First try silent (existing cookies)
            let silentResult = await ssoService.attemptSilentAuth()
            if silentResult.success {
                return ConnectionTestResult(service: "Snipe-IT", success: true, message: "SSO authenticated as \(silentResult.userName ?? "user")")
            }

            // Headless WKWebView SSO
            let webView = ssoService.createWebView()
            // Attach to a hidden window so Platform SSO Extension can intercept
            let hiddenWindow = NSWindow(
                contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                styleMask: [], backing: .buffered, defer: true
            )
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.orderOut(nil)
            hiddenWindow.contentView = webView
            webView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

            ssoService.startAuthentication()

            // Wait up to 30 seconds for SSO to complete
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let result = ssoService.authResult {
                    hiddenWindow.close()
                    if result.success {
                        return ConnectionTestResult(service: "Snipe-IT", success: true, message: "SSO authenticated as \(result.userName ?? "user")")
                    } else {
                        return ConnectionTestResult(service: "Snipe-IT", success: false, message: result.error ?? "SSO failed")
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            hiddenWindow.close()
            return ConnectionTestResult(service: "Snipe-IT", success: false, message: "SSO timed out")
        } else {
            do {
                let service = SnipeService(config: config)
                _ = try await service.getAllAssets()
                return ConnectionTestResult(service: "Snipe-IT", success: true, message: "Connected")
            } catch {
                return ConnectionTestResult(service: "Snipe-IT", success: false, message: error.localizedDescription)
            }
        }
    }

    private func testTdx(config: FleetMateConfig) async -> ConnectionTestResult {
        if wizardState.tdxAuthMode == .sso {
            // SSO mode: run headless WKWebView SSO via the existing TDX SSO flow
            var ssoConfig = config
            ssoConfig.tdxAuthMethod = .browserSSO
            ssoConfig.tdxSsoEnabled = true
            let viewModel = TdxSsoLoginViewModel(config: ssoConfig)

            let hiddenWindow = NSWindow(
                contentRect: NSRect(x: -9999, y: -9999, width: 1, height: 1),
                styleMask: [], backing: .buffered, defer: true
            )
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.orderOut(nil)

            let webView = viewModel.webView
            hiddenWindow.contentView = webView
            webView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)

            viewModel.startAuthentication()

            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                if let result = viewModel.authResult {
                    hiddenWindow.close()
                    if result.success {
                        return ConnectionTestResult(service: "TeamDynamix", success: true, message: "SSO authenticated as \(result.userName ?? "user")")
                    } else {
                        return ConnectionTestResult(service: "TeamDynamix", success: false, message: result.error ?? "SSO failed")
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            hiddenWindow.close()
            return ConnectionTestResult(service: "TeamDynamix", success: false, message: "SSO timed out")
        } else {
            do {
                let service = TdxService(config: config)
                _ = try await service.searchTickets(search: TicketSearchRequest(maxResults: 1), maxResults: 1)
                return ConnectionTestResult(service: "TeamDynamix", success: true, message: "Service account authenticated")
            } catch {
                return ConnectionTestResult(service: "TeamDynamix", success: false, message: error.localizedDescription)
            }
        }
    }

    private func testDevOps(config: FleetMateConfig) async -> ConnectionTestResult {
        // Verify the organization URL is reachable
        guard let org = config.devopsOrganization else {
            return ConnectionTestResult(service: "Azure DevOps", success: false, message: "No organization")
        }
        let urlString = "https://dev.azure.com/\(org)"
        guard let url = URL(string: urlString) else {
            return ConnectionTestResult(service: "Azure DevOps", success: false, message: "Invalid org name")
        }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                return ConnectionTestResult(service: "Azure DevOps", success: true, message: "Organization reachable (SSO login deferred)")
            } else {
                return ConnectionTestResult(service: "Azure DevOps", success: false, message: "Organization not found")
            }
        } catch {
            return ConnectionTestResult(service: "Azure DevOps", success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func maskSecret(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "*", count: value.count) }
        return String(value.prefix(4)) + "..." + String(value.suffix(4))
    }

    private func ensureHttps(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
        return "https://\(trimmed)"
    }

    private func abbreviateGuid(_ value: String) -> String {
        let parts = value.split(separator: "-")
        guard parts.count >= 2 else { return value }
        return parts[0] + "-" + parts[1] + "-..."
    }
}
