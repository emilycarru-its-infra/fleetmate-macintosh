import SwiftUI
import FleetMateCore

struct DevicesView: View {
    @EnvironmentObject var appState: AppState
    @State private var devices: [IntuneDevice] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var selectedDeviceId: String?
    @State private var showOnlyNonCompliant = false

    var filteredDevices: [IntuneDevice] {
        var result = devices

        if showOnlyNonCompliant {
            result = result.filter { $0.complianceState?.lowercased() == "noncompliant" }
        }

        if !searchText.isEmpty {
            result = result.filter {
                ($0.deviceName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.serialNumber?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.userPrincipalName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Intune Devices")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Managed devices from Microsoft Intune")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Non-Compliant Only", isOn: $showOnlyNonCompliant)
                    .toggleStyle(.switch)
                Button(action: loadDevices) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search devices...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            // Content
            if !appState.config.isGraphConfigured {
                ContentUnavailableView(
                    "Not Configured",
                    systemImage: "gear.badge.xmark",
                    description: Text("Microsoft Graph is not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID in your config.")
                )
            } else if isLoading {
                ProgressView("Loading devices...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDevices.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Table(filteredDevices, selection: $selectedDeviceId) {
                    TableColumn("Serial") { device in
                        Text(device.serialNumber ?? "-")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Name") { device in
                        Text(device.deviceName ?? "-")
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Compliance") { device in
                        ComplianceBadge(state: device.complianceState)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("OS") { device in
                        Text("\(device.operatingSystem ?? "-") \(device.osVersion ?? "")")
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("User") { device in
                        Text(device.userDisplayName ?? device.userPrincipalName ?? "-")
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Last Sync") { device in
                        Text(formatDate(device.lastSyncDateTime))
                    }
                    .width(min: 100, ideal: 150)
                }
            }
        }
        .task {
            if devices.isEmpty {
                loadDevices()
            }
        }
    }

    private func loadDevices() {
        guard appState.config.isGraphConfigured else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                devices = try await appState.graphService.getManagedDevices(limit: 500)
            } catch {
                appState.errorMessage = "Failed to load devices: \(error.localizedDescription)"
            }
        }
    }

    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "-" }
        // Simple date formatting - just show first 16 chars
        return String(dateString.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

struct ComplianceBadge: View {
    let state: String?

    var body: some View {
        let (color, icon): (Color, String) = {
            switch state?.lowercased() {
            case "compliant": return (.green, "checkmark.circle.fill")
            case "noncompliant": return (.red, "xmark.circle.fill")
            case "ingraceperiod": return (.yellow, "clock.fill")
            default: return (.gray, "questionmark.circle.fill")
            }
        }()

        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(state ?? "Unknown")
                .font(.caption)
        }
    }
}

#Preview {
    DevicesView()
        .environmentObject(AppState())
}
