import SwiftUI
import FleetMateCore

/// Top-level tab identity shared between ContentView and AppState for type-safe programmatic navigation.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case devices = "Devices"
    case inventory = "Inventory"
    case tickets = "Tickets"
    case projects = "Projects"
    case identity = "Identity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .devices: "laptopcomputer"
        case .inventory: "shippingbox"
        case .tickets: "ticket"
        case .projects: "list.clipboard"
        case .identity: "person.2"
        }
    }

    func isEnabled(config: FleetMateConfig) -> Bool {
        switch self {
        case .dashboard: true
        case .devices:   config.isGraphConfigured
        case .inventory: config.isSnipeConfigured
        case .tickets:   config.isTdxConfigured
        case .projects:  config.isDevOpsConfigured
        case .identity:  config.isGraphConfigured
        }
    }

    static func enabledTabs(config: FleetMateConfig) -> [AppTab] {
        allCases.filter { $0.isEnabled(config: config) }
    }
}
