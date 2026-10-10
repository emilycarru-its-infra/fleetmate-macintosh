import Foundation

/// How a widget click becomes a filter on the list beside it. The widgets
/// show friendlier labels than the filters hold ("Macintosh" for Intune's
/// "macOS"), so a click is matched back through the same labelling rather
/// than compared as text. FleetMate for Windows follows the same rules.
public enum WidgetFilterMatch {
    /// The platform name the widgets show for an Intune operating system.
    public static func platformLabel(_ operatingSystem: String?) -> String {
        switch operatingSystem {
        case "macOS": return "Macintosh"
        case "iOS", "iPadOS": return "iOS/iPadOS"
        default: return operatingSystem ?? ""
        }
    }

    /// A slice or bar label without its " (count)" suffix.
    public static func filterValue(_ label: String) -> String {
        label.components(separatedBy: " (").first ?? label
    }

    /// The filter values a widget click selects: every value in `available`
    /// whose label (through `display`, when given) matches `incoming`,
    /// ignoring case and punctuation. "Non-Compliant" finds "Noncompliant",
    /// "Macintosh" finds "macOS", and "iOS/iPadOS" finds both "iOS" and
    /// "iPadOS". With no match the incoming value is used as it is.
    public static func matchingValues(
        _ incoming: String, in available: [String]?, display: ((String) -> String)? = nil
    ) -> [String] {
        let want = normalize(incoming)
        let matches = (available ?? []).filter { normalize(display?($0) ?? $0) == want }
        return matches.isEmpty ? [incoming] : matches
    }

    /// The status type an asset is counted under by the Asset Status widget
    /// and filtered by in the Inventory Status filter: Snipe-IT's status
    /// meta (deployed, deployable, pending, archived…), else the status
    /// name, else "Unknown". Both read this, so a wedge always finds its
    /// assets.
    public static func assetStatusType(meta: String?, name: String?) -> String {
        if let meta, !meta.isEmpty { return meta }
        if let name, !name.isEmpty { return name }
        return "Unknown"
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
