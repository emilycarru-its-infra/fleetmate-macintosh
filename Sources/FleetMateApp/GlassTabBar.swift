import SwiftUI


/// Glass button modifier for action buttons — interactive glass on macOS 26+
struct GlassButtonModifier: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .padding(8)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func glassButton(cornerRadius: CGFloat = 8) -> some View {
        modifier(GlassButtonModifier(cornerRadius: cornerRadius))
    }
}
