import SwiftUI
import FleetMateCore

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var deviceCount: Int = 0
    @State private var nonCompliantCount: Int = 0
    @State private var assetCount: Int = 0
    @State private var ticketCount: Int = 0
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("Dashboard")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Fleet overview and quick stats")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: refreshData) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                .padding(.bottom)

                // Stats Cards
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(title: "Managed Devices", value: "\(deviceCount)", icon: "laptopcomputer", color: .blue)
                    StatCard(title: "Non-Compliant", value: "\(nonCompliantCount)", icon: "exclamationmark.triangle", color: nonCompliantCount > 0 ? .red : .green)
                    StatCard(title: "Assets", value: "\(assetCount)", icon: "shippingbox", color: .orange)
                    StatCard(title: "Open Tickets", value: "\(ticketCount)", icon: "ticket", color: .purple)
                }

                // Configuration Status
                GroupBox("Configuration Status") {
                    VStack(alignment: .leading, spacing: 12) {
                        ConfigStatusRow(name: "Microsoft Graph", isConfigured: appState.config.isGraphConfigured)
                        ConfigStatusRow(name: "Azure DevOps", isConfigured: appState.config.isDevOpsConfigured)
                        ConfigStatusRow(name: "TeamDynamix", isConfigured: appState.config.isTdxConfigured)
                        ConfigStatusRow(name: "Snipe-IT", isConfigured: appState.config.snipeUrl != nil && appState.config.snipeApiKey != nil)
                    }
                    .padding(.vertical, 8)
                }

                // Error Message
                if let error = appState.errorMessage {
                    GroupBox {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text(error)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Dismiss") {
                                appState.errorMessage = nil
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding()
        }
        .task {
            await loadInitialData()
        }
    }

    private func refreshData() {
        Task {
            await loadInitialData()
        }
    }

    private func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        // Load device count from Intune
        if appState.config.isGraphConfigured {
            do {
                let devices = try await appState.graphService.getManagedDevices(limit: 1000)
                deviceCount = devices.count
                nonCompliantCount = devices.filter { $0.complianceState?.lowercased() == "noncompliant" }.count
            } catch {
                print("Failed to load devices: \(error)")
            }
        }

        // Load asset count from Snipe-IT
        if appState.config.snipeUrl != nil {
            do {
                let assets = try await appState.snipeService.getAssets()
                assetCount = assets.count
            } catch {
                print("Failed to load assets: \(error)")
            }
        }

        // Load ticket count from TDX
        if appState.config.isTdxConfigured {
            do {
                let tickets = try await appState.tdxService.searchTickets(maxResults: 100)
                ticketCount = tickets.count
            } catch {
                print("Failed to load tickets: \(error)")
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

struct ConfigStatusRow: View {
    let name: String
    let isConfigured: Bool

    var body: some View {
        HStack {
            Image(systemName: isConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isConfigured ? .green : .red)
            Text(name)
            Spacer()
            Text(isConfigured ? "Configured" : "Not Configured")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
