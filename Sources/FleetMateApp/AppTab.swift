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

    /// The tabs this edition carries at all. TicketsMate is the Tickets tab
    /// alone.
    static func editionTabs(_ edition: AppEdition = .current) -> [AppTab] {
        edition.isTicketsOnly ? [.tickets] : allCases
    }

    /// Where the app opens, and where it falls back when the open tab loses
    /// its configuration.
    static func launchTab(_ edition: AppEdition = .current) -> AppTab {
        edition.isTicketsOnly ? .tickets : .development
    }

    /// The Settings ▸ General module behind this tab.
    var module: FleetModule {
        switch self {
        case .development: .development
        case .projects: .projects
        case .devices: .devices
        case .reporting: .reporting
        case .manage: .manage
        case .inventory: .inventory
        case .identity: .identity
        case .tickets: .tickets
        }
    }

    /// Shown when this edition carries the tab, its module is switched on, and
    /// the module has the configuration it needs.
    func isEnabled(config: FleetMateConfig, modules: ModuleEnablement) -> Bool {
        guard Self.editionTabs().contains(self) else { return false }
        // TicketsMate's one tab cannot be switched off.
        if AppEdition.current.isTicketsOnly { return module.isConfigured(config) }
        return modules.isActive(module, config: config)
    }

    static func enabledTabs(config: FleetMateConfig, modules: ModuleEnablement) -> [AppTab] {
        editionTabs().filter { $0.isEnabled(config: config, modules: modules) }
    }
}
