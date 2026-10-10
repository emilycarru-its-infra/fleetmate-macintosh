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

    /// Folder debug.log is written to. TicketsMate keeps its logs apart from
    /// FleetMate's, in the standard per-user Logs folder.
    public var logDirectory: String {
        switch self {
        case .fleetMate: supportDirectory
        case .ticketsMate: "~/Library/Logs/TicketsMate"
        }
    }

    /// Expands `name` inside this edition's support folder.
    public func supportPath(_ name: String) -> String {
        NSString(string: "\(supportDirectory)/\(name)").expandingTildeInPath
    }
}

/// The version string the About pane shows.
public enum AppVersionDisplay {
    /// Release builds stamp CFBundleShortVersionString with the date
    /// (YYYY.MM.DD) and CFBundleVersion with the time (HHMM); joined they are
    /// the same YYYY.MM.DD.HHMM `fleetmate --version` reports. An unstamped
    /// build reads "dev", with the commit it was built from when known.
    public static func string(short: String?, build: String?, commit: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        let isDate = short.split(separator: ".").count == 3 && short.count == 10 && short.allSatisfy { $0.isNumber || $0 == "." }
        if isDate {
            return build.count == 4 && build.allSatisfy(\.isNumber) ? "\(short).\(build)" : short
        }
        if short.split(separator: ".").count == 4 && short.hasPrefix("20") { return short }
        if let commit, !commit.isEmpty { return "dev (\(commit))" }
        return "dev"
    }
}
