import AppKit

/// Settings ▸ Appearance ▸ Theme — Light, Dark, or follow the system.
///
/// Applied through `NSApp.appearance` rather than `.preferredColorScheme`, so
/// it reaches every window at once: the main window, Settings, sheets and the
/// hidden SSO windows alike.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "ui.theme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Use system setting"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }

    static var stored: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = appearance
    }
}
