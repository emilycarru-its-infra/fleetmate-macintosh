import SwiftUI

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
}
