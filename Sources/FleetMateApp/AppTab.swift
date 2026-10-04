import SwiftUI
import FleetMateCore

/// Top-level tab identity shared between ContentView and AppState for type-safe programmatic navigation.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    // Declaration order is display order and the ⌘1…⌘8 order. Development
    // sits in the centre; Tickets goes last.
    case dashboard = "Dashboard"
    case devices = "Devices"
    case manage = "Manage"
    case inventory = "Inventory"
    case development = "Development"
    case projects = "Projects"
    case identity = "Identity"
    case tickets = "Tickets"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .devices: "laptopcomputer"
        case .manage: "wrench.and.screwdriver"
        case .inventory: "shippingbox"
        case .tickets: "ticket"
        case .projects: "list.clipboard"
        case .development: "chevron.left.forwardslash.chevron.right"
        case .identity: "person.2"
        }
    }

    func isEnabled(config: FleetMateConfig) -> Bool {
        switch self {
        case .dashboard: true
        case .devices:   config.isGraphConfigured
        case .manage:    config.isManageConfigured
        case .inventory: config.isSnipeConfigured
        case .tickets:   config.isTdxConfigured
        case .projects:  config.isDevOpsConfigured
        // GitHub needs no config beyond a gh login, so the tab is always on.
        case .development: true
        case .identity:  config.isGraphConfigured
        }
    }

    static func enabledTabs(config: FleetMateConfig) -> [AppTab] {
        allCases.filter { $0.isEnabled(config: config) }
    }
}
