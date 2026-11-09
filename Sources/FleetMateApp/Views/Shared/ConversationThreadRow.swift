import SwiftUI

// MARK: - Thread Rail

/// What the rail below a comment's avatar has to reach.
enum ThreadConnectorKind {
    /// Nothing follows at this level — draw no line.
    case none
    /// The next comment sits at the same indent: straight down.
    case straight
    /// The next comment is indented further right: down, then a rounded turn.
    case elbow
}

private struct ThreadConnectorShape: Shape {
    let kind: ThreadConnectorKind
    let elbowRun: CGFloat

    /// Radius of the turn. Large enough to read as a curve at 2pt, small
    /// enough not to eat the whole horizontal run.
    private let radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard kind != .none else { return path }

        let x = rect.midX
        path.move(to: CGPoint(x: x, y: rect.minY))

        switch kind {
        case .straight:
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        case .elbow:
            path.addLine(to: CGPoint(x: x, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: x + radius, y: rect.maxY),
                control: CGPoint(x: x, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: x + elbowRun, y: rect.maxY))
        case .none:
            break
        }
        return path
    }
}

/// Initials on a neutral disc for conversations whose author has no supplied photo.
struct ThreadAvatar: View {
    let name: String?
    let size: CGFloat

    private var initials: String {
        let parts = (name ?? "")
            .split(separator: " ")
            .filter { $0.first?.isLetter == true }
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .appFont(fixed: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            )
    }
}

enum ConversationThreadGeometry {
    static let avatarSize: CGFloat = 26
    static let railSpacing: CGFloat = 10
    static let replyIndent: CGFloat = 34
    static let rowGap: CGFloat = 10
    static var elbowRun: CGFloat { replyIndent - avatarSize / 2 }
}

/// Shared reading-order rail used by Tickets and Teams.
struct ConversationThreadRow<Content: View>: View {
    let author: String?
    let isReply: Bool
    let connector: ThreadConnectorKind
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: ConversationThreadGeometry.railSpacing) {
            if isReply {
                Color.clear.frame(width: ConversationThreadGeometry.replyIndent - ConversationThreadGeometry.railSpacing, height: 0)
            }
            VStack(spacing: 0) {
                ThreadAvatar(name: author, size: ConversationThreadGeometry.avatarSize)
                    .accessibilityHidden(true)
                ThreadConnectorShape(kind: connector, elbowRun: ConversationThreadGeometry.elbowRun)
                    .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, connector == .elbow ? -ConversationThreadGeometry.avatarSize / 2 : 0)
            }
            .frame(width: ConversationThreadGeometry.avatarSize)
            content().padding(.bottom, ConversationThreadGeometry.rowGap)
        }
    }
}

struct ConversationCardStyle: ViewModifier {
    let isReply: Bool
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isReply ? Color.secondary.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.16), lineWidth: 1))
    }
}
