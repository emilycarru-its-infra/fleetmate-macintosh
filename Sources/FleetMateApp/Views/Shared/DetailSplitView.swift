import SwiftUI
import AppKit

/// A list beside a detail pane, with a draggable divider. The detail opens at
/// `fraction` of the width (half by default); HSplitView ignored its pane's
/// ideal width and opened the detail at whatever it last had. Each pane is
/// clipped, so neither can spill past the divider.
struct DetailSplitView<Leading: View, Trailing: View>: View {
    @Binding var fraction: Double
    let showsDetail: Bool
    var minLeading: CGFloat = 380
    var minTrailing: CGFloat = 440
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let detail = showsDetail ? detailWidth(total) : 0
            HStack(spacing: 0) {
                leading()
                    .frame(width: max(total - detail - (showsDetail ? 1 : 0), 0))
                    .clipped()
                if showsDetail {
                    divider(total: total)
                    trailing()
                        .frame(width: detail)
                        .clipped()
                }
            }
        }
    }

    private func detailWidth(_ total: CGFloat) -> CGFloat {
        let upper = max(total - minLeading, minTrailing)
        return min(max(total * fraction, minTrailing), upper)
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? fraction
                        dragStart = start
                        guard total > 0 else { return }
                        fraction = min(max(start - value.translation.width / total, 0.1), 0.9)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
