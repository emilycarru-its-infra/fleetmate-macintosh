import Foundation

/// Which app this build is. TicketsMate is FleetMate limited to the Tickets
/// tab: the same binary, bundled under its own name, bundle id and icon, with
/// `FleetMateEdition` set to `TicketsMate` in its Info.plist. Each edition
/// keeps its own settings, so the two install and run side by side.
public enum AppEdition: String, Sendable {
    case fleetMate = "FleetMate"
    case ticketsMate = "TicketsMate"

    /// Info.plist key the app bundle declares its edition under. The CLI has no
    /// bundle, so it is always FleetMate.
    public static let infoKey = "FleetMateEdition"

    public static let current = AppEdition(infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    /// An unknown or missing value is FleetMate, so a bundle that predates the
    /// key keeps working.
    public init(infoValue: String?) {
        self = infoValue.flatMap(AppEdition.init(rawValue:)) ?? .fleetMate
    }

    /// The name shown in the window, About box and onboarding.
    public var displayName: String { rawValue }

    /// True when the app shows only the Tickets tab.
    public var isTicketsOnly: Bool { self == .ticketsMate }

    /// Per-user folder for config.yaml, credentials.json and debug.log.
    public var supportDirectory: String {
        switch self {
        case .fleetMate: "~/.fleetmate"
        case .ticketsMate: "~/.ticketsmate"
        }
    }

    /// Preference domain a configuration profile configures this edition
    /// through, and the Keychain service its secrets are stored under. FleetMate
    /// keeps its long-standing domain whatever bundle it runs from, so the CLI
    /// and the app share one. TicketsMate uses its own bundle id.
    public func preferencesDomain(bundleIdentifier: String?) -> String {
        switch self {
        case .fleetMate: Self.fleetMateDomain
        case .ticketsMate: bundleIdentifier ?? Self.fleetMateDomain
        }
    }

    public var preferencesDomain: String {
        preferencesDomain(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static let fleetMateDomain = "ca.ecuad.macadmin.fleetmate"

    /// Expands `name` inside this edition's support folder.
    public func supportPath(_ name: String) -> String {
        NSString(string: "\(supportDirectory)/\(name)").expandingTildeInPath
    }
}
