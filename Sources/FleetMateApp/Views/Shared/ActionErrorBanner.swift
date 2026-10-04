import SwiftUI

/// A failed action reported as a quiet banner along the top of the view it
/// came from, rather than a modal alert that blocks the whole window. It
/// dismisses itself after a few seconds, or with its close button.
struct ActionErrorBanner: ViewModifier {
    @Binding var message: String?
    var title: String = "Action failed"
    var duration: Duration = .seconds(8)

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).appFont(.callout).fontWeight(.semibold)
                        Text(message)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        self.message = nil
                    } label: {
                        Image(systemName: "xmark").appFont(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 460)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    withAnimation { self.message = nil }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: message)
    }
}

extension View {
    /// Shows `message` as a dismissible, self-clearing banner over this view.
    func actionErrorBanner(_ message: Binding<String?>, title: String = "Action failed") -> some View {
        modifier(ActionErrorBanner(message: message, title: title))
    }
}
