import SwiftUI
import FleetMateCore

/// Top-level tab identity shared between ContentView and AppState for type-safe programmatic navigation.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    // Declaration order is display order and the ⌘1…⌘8 order. Development
    // leads and is the launch tab; Tickets goes last. There is no Dashboard:
    // each tab carries its own widgets, and Recent Activity is a toolbar
    // popover.
    case development = "Development"
    case projects = "Projects"
    case devices = "Devices"
    case reporting = "Reporting"
    case manage = "Manage"
    case inventory = "Inventory"
    case identity = "Identity"
    case tickets = "Tickets"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .devices: "laptopcomputer"
        case .reporting: "chart.bar.doc.horizontal"
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
        case .devices:   config.isGraphConfigured
        // ReportMate falls back to its own saved settings, so the tab is always on.
        case .reporting: true
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
