import Foundation

/// A part of FleetMate that can be switched on or off in Settings ▸ General.
///
/// Every top-level tab is a module, plus Enrollment, which feeds Mac and
/// Windows enrollment records into the Devices tab. Titles and summaries describe what
/// the module does, never which product backs it: FleetMate is agnostic about
/// the systems behind each function, and the connector in use is named only
/// where it is configured (Settings ▸ Authentication).
public enum FleetModule: String, CaseIterable, Codable, Sendable, Identifiable {
    // Declaration order is the order Settings and the setup wizard list them,
    // matching the tab bar.
    case development
    case projects
    case devices
    case reporting
    case manage
    case inventory
    case identity
    case tickets
    case enrollment

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .development: "Development"
        case .projects: "Projects"
        case .devices: "Devices"
        case .reporting: "Reporting"
        case .manage: "Manage"
        case .inventory: "Inventory"
        case .identity: "Identity"
        case .tickets: "Tickets"
        case .enrollment: "Enrollment"
        }
    }

    /// One line on what the module is for.
    public var summary: String {
        switch self {
        case .development: "Repositories, pull requests, pipelines and the coding agent"
        case .projects: "Boards, work items and issues"
        case .devices: "Managed devices, compliance and remote actions"
        case .reporting: "Fleet reporting and device telemetry"
        case .manage: "Lab operations over SSH and Screen Sharing"
        case .inventory: "Asset inventory and lifecycle"
        case .identity: "Users, groups and directory roles"
        case .tickets: "Service desk tickets"
        case .enrollment: "Mac and Windows enrollment records, joined to Devices"
        }
    }

    public var icon: String {
        switch self {
        case .development: "chevron.left.forwardslash.chevron.right"
        case .projects: "list.clipboard"
        case .devices: "laptopcomputer"
        case .reporting: "chart.bar.doc.horizontal"
        case .manage: "wrench.and.screwdriver"
        case .inventory: "shippingbox"
        case .identity: "person.2"
        case .tickets: "ticket"
        case .enrollment: "laptopcomputer.and.arrow.down"
        }
    }

    /// Whether the module has what it needs to load anything. Modules that
    /// need nothing beyond a CLI sign-in (Development) or carry their own saved
    /// settings (Reporting) are always ready.
    public func isConfigured(_ config: FleetMateConfig) -> Bool {
        switch self {
        case .development, .reporting: true
        case .projects: config.isDevOpsConfigured
        case .devices, .identity: config.isGraphConfigured
        case .manage: config.isManageConfigured
        case .inventory: config.isSnipeConfigured
        case .tickets: config.isTdxConfigured
        // Windows records come through the Devices connection, Mac records
        // from the enrollment organizations configured in Settings.
        case .enrollment: !config.appleOrgSources.isEmpty || config.isGraphConfigured
        }
    }
}

/// Which modules the person has switched off.
///
/// Stored as the *disabled* set, so a module added in a later release starts
/// on, and a settings domain written before modules could be switched off
/// (no value at all) reads as everything on. Before this, switching a module
/// off in Settings cleared its credentials; those modules still read as off
/// because they are unconfigured, so nothing a person turned off reappears.
public struct ModuleEnablement: Equatable, Sendable {
    public private(set) var disabled: Set<FleetModule>

    /// UserDefaults key holding the comma-separated disabled list.
    public static let defaultsKey = "modules.disabled"

    /// Names earlier builds or hand-edited defaults may use for a module.
    static let aliases: [String: FleetModule] = [
        "apple": .enrollment,
        "appleorg": .enrollment,
        "apple_org": .enrollment,
        "graph": .devices,
        "intune": .devices,
        "entra": .identity,
        "assets": .inventory,
        "snipe": .inventory,
        "tdx": .tickets,
        "devops": .projects,
        "repos": .development,
    ]

    public init(disabled: Set<FleetModule> = []) {
        self.disabled = disabled
    }

    /// Parse the stored value. Unknown names are ignored rather than failing,
    /// so a value written by a newer build never switches modules back on or
    /// off by surprise.
    public init(storedValue: String?) {
        var set = Set<FleetModule>()
        for token in (storedValue ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace || $0.isNewline }) {
            let name = token.lowercased()
            if let module = FleetModule(rawValue: name) ?? Self.aliases[name] {
                set.insert(module)
            }
        }
        self.disabled = set
    }

    /// The value to store: disabled modules in declaration order.
    public var storedValue: String {
        FleetModule.allCases.filter(disabled.contains).map(\.rawValue).joined(separator: ",")
    }

    public func isOn(_ module: FleetModule) -> Bool { !disabled.contains(module) }

    public mutating func set(_ module: FleetModule, on: Bool) {
        if on { disabled.remove(module) } else { disabled.insert(module) }
    }

    /// Switched on and able to load: what decides whether its tab shows.
    public func isActive(_ module: FleetModule, config: FleetMateConfig) -> Bool {
        isOn(module) && module.isConfigured(config)
    }

    public static func load(from defaults: UserDefaults = .standard) -> ModuleEnablement {
        ModuleEnablement(storedValue: defaults.string(forKey: defaultsKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        if disabled.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(storedValue, forKey: Self.defaultsKey)
        }
    }
}
