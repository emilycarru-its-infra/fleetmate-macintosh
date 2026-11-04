import SwiftUI

/// Gives a set of push buttons one common width — the natural width of the
/// widest label — so buttons in separate rows line up in a column, the way a
/// dialog's buttons do.
///
/// Each label reports the width its text needs before any widening, so the
/// shared width follows the real labels: it grows with `appFontScale` or
/// Dynamic Type and shrinks when a label gets shorter, instead of resting on
/// a guessed point value.
///
///     VStack { rowA; rowB }.sharedButtonWidthGroup()
///     Button { … } label: { Text("Add Task…").sharedButtonWidth() }
extension View {
    /// Collect the widths of every `.sharedButtonWidth()` label inside this
    /// view and hand the widest back to all of them.
    func sharedButtonWidthGroup() -> some View {
        modifier(SharedButtonWidthGroup())
    }

    /// Size this button label to the group's shared width. Outside a group it
    /// keeps its natural width.
    func sharedButtonWidth() -> some View {
        modifier(SharedButtonWidthMember())
    }
}

private struct SharedButtonWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SharedButtonWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    var sharedButtonWidth: CGFloat? {
        get { self[SharedButtonWidthEnvironmentKey.self] }
        set { self[SharedButtonWidthEnvironmentKey.self] = newValue }
    }
}

private struct SharedButtonWidthGroup: ViewModifier {
    @State private var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .environment(\.sharedButtonWidth, width)
            .onPreferenceChange(SharedButtonWidthKey.self) { newWidth in
                let rounded = newWidth > 0 ? newWidth.rounded(.up) : nil
                if rounded != width { width = rounded }
            }
    }
}

private struct SharedButtonWidthMember: ViewModifier {
    @Environment(\.sharedButtonWidth) private var sharedWidth

    func body(content: Content) -> some View {
        content
            .fixedSize()
            // Measured before the frame below widens it, so the reported
            // width is always the label's own and can't feed back on itself.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SharedButtonWidthKey.self, value: proxy.size.width)
                }
            }
            .frame(minWidth: sharedWidth)
    }
}
