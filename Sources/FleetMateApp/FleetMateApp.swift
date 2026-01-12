import SwiftUI
import FleetMateCore

@main
struct FleetMateApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        #endif
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var config: FleetMateConfig
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Services (lazy initialization)
    lazy var graphService: GraphService = GraphService(config: config)
    lazy var devOpsService: AzureDevOpsService = AzureDevOpsService(config: config)
    lazy var tdxService: TdxService = TdxService(config: config)
    lazy var snipeService: SnipeService = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)

    init() {
        do {
            self.config = try FleetMateConfig.load()
        } catch {
            self.config = FleetMateConfig()
            self.errorMessage = "Failed to load config: \(error.localizedDescription)"
        }
    }

    func reloadConfig() {
        do {
            config = try FleetMateConfig.load()
            // Reinitialize services
            graphService = GraphService(config: config)
            devOpsService = AzureDevOpsService(config: config)
            tdxService = TdxService(config: config)
            snipeService = SnipeService(baseUrl: config.snipeUrl, apiKey: config.snipeApiKey)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to reload config: \(error.localizedDescription)"
        }
    }
}
