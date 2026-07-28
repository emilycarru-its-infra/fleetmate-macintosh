import SwiftUI

/// App-wide text sizing.
///
/// macOS has no Dynamic Type. SwiftUI's `dynamicTypeSize` modifier compiles and
/// runs here but is inert — `.body`, `.caption` and friends resolve to the same
/// point size at every step from `.xSmall` to `.accessibility5`, because there is
/// no system text-size setting for AppKit to report. So the app carries its own
/// scale instead: one stored multiplier, applied to the macOS text-style point
/// sizes, exposed as a slider in Settings.
///
/// Use `.appFont(_:)` everywhere in place of `.font(_:)`. Views read the scale
/// from the environment, so changing the slider restyles the whole app live.
enum AppTextStyle: String, CaseIterable {
    case largeTitle
    case title
    case title2
    case title3
    case headline
    case body
    case callout
    case subheadline
    case footnote
    case caption
    case caption2

    /// Unscaled point size for the style.
    ///
    /// These deliberately depart from `NSFont.preferredFont(forTextStyle:)` at the
    /// small end. macOS collapses `footnote`, `caption` and `caption2` onto the
    /// same 10 pt, which is fine for an occasional label but not for FleetMate:
    /// `.caption` is the single most-used style in the app (184 call sites, more
    /// than body/callout/subheadline combined) and carries a lot of primary row
    /// content. Sharing a size with tertiary text left the UI both hard to read
    /// and hierarchy-less at the bottom of the ramp.
    ///
    /// The small end is opened up by a point so each rung is distinguishable —
    /// caption2 10 < caption 11 < subheadline 12 < body/callout 13 < headline 14 —
    /// and the rest is left on the macOS values. The user's scale multiplies all
    /// of it.
    ///
    /// | style       | macOS | FleetMate |
    /// |-------------|-------|-----------|
    /// | caption2    | 10    | 10        |
    /// | caption     | 10    | **11**    |
    /// | footnote    | 10    | **11**    |
    /// | subheadline | 11    | **12**    |
    /// | callout     | 12    | **13**    |
    /// | body        | 13    | 13        |
    /// | headline    | 13    | **14**    |
    /// | title3      | 15    | **16**    |
    var basePointSize: CGFloat {
        switch self {
        case .largeTitle:  return 26
        case .title:       return 22
        case .title2:      return 17
        case .title3:      return 16
        case .headline:    return 14
        case .body:        return 13
        case .callout:     return 13
        case .subheadline: return 12
        case .footnote:    return 11
        case .caption:     return 11
        case .caption2:    return 10
        }
    }

    /// Headline is body-sized but semibold on macOS; preserve that.
    var baseWeight: Font.Weight? {
        self == .headline ? .semibold : nil
    }
}

// MARK: - Scale

enum AppFontScale {
    static let storageKey = "ui.fontScale"
    static let range: ClosedRange<Double> = 0.9...1.6
    static let step: Double = 0.05
    static let `default`: Double = 1.0

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Label for the slider readout, e.g. "115%".
    static func label(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = AppFontScale.default
}

extension EnvironmentValues {
    /// Multiplier applied to every `.appFont(_:)` in the subtree.
    var appFontScale: Double {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

// MARK: - Font resolution

extension AppTextStyle {
    /// Resolve to a concrete `Font` at the given scale.
    ///
    /// Sizes are rounded to whole points: macOS renders text on a whole-pixel
    /// grid and fractional sizes make small text look muddy.
    func font(scale: Double, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        let size = (basePointSize * CGFloat(AppFontScale.clamp(scale))).rounded()
        return .system(size: size, weight: weight ?? baseWeight ?? .regular, design: design)
    }
}

// MARK: - View modifier

private struct AppFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale

    let style: AppTextStyle
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(style.font(scale: scale, weight: weight, design: design))
    }
}

/// Scales a point size that doesn't correspond to a macOS text style. Used where
/// the design deliberately picked an in-between size (a 14pt section header, an
/// 11pt sidebar label) and rounding it to the nearest style would change how the
/// app looks at 100%.
private struct AppFixedFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale

    let base: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        let size = (base * CGFloat(AppFontScale.clamp(scale))).rounded()
        return content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Scale-aware replacement for `.font(_:)`.
    ///
    ///     Text(pr.title).appFont(.body, weight: .semibold)
    func appFont(_ style: AppTextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, design: design))
    }

    /// Scale-aware replacement for `.font(.system(size:))` on **text**. Prefer a
    /// named style; reach for this only when the exact point size matters.
    ///
    /// Decorative glyphs (the 48pt symbol in an empty state) stay on plain
    /// `.font(.system(size:))` — scaling those blows up the layout around them
    /// without making anything more readable.
    func appFont(fixed base: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AppFixedFontModifier(base: base, weight: weight, design: design))
    }

    /// Applies the stored scale to a subtree. Attach once at the app root.
    func appFontScale(_ scale: Double) -> some View {
        environment(\.appFontScale, AppFontScale.clamp(scale))
    }
}

// MARK: - Text convenience

extension Text {
    /// For the cases where a `Font` value is needed rather than a modifier —
    /// concatenated `Text`, `.textStyle` on attributed strings, and so on.
    static func appFont(_ style: AppTextStyle, scale: Double, weight: Font.Weight? = nil) -> Font {
        style.font(scale: scale, weight: weight)
    }
}
