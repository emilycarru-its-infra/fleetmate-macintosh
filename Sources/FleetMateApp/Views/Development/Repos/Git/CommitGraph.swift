import SwiftUI
import FleetMateCore

// Ported from MunkiStudio (Apache-2.0),
// Sources/App/Features/Git/CommitGraph.swift. The lane builder is in
// FleetMateCore (GitPaneSupport.swift) so it is unit-tested; red is out of
// the palette.

/// Stable palette for graph lanes and ref badges — cycled by index.
enum GraphPalette {
    static let colors: [Color] = [.blue, .purple, .green, .orange, .teal, .indigo, .mint, .brown]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// Leading graph column drawn for one commit row.
struct GraphCell: View {
    let row: GraphRow
    let laneCount: Int
    let rowHeight: CGFloat

    private let laneWidth: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            func x(_ column: Int) -> CGFloat {
                CGFloat(column) * laneWidth + laneWidth / 2
            }
            let mid = size.height / 2
            for segment in row.segments {
                var path = Path()
                if segment.upperHalf {
                    path.move(to: CGPoint(x: x(segment.fromColumn), y: 0))
                    path.addLine(to: CGPoint(x: x(segment.toColumn), y: mid))
                } else {
                    path.move(to: CGPoint(x: x(segment.fromColumn), y: mid))
                    path.addLine(to: CGPoint(x: x(segment.toColumn), y: size.height))
                }
                context.stroke(path, with: .color(GraphPalette.color(segment.colorIndex)), lineWidth: 2)
            }
            let center = CGPoint(x: x(row.dotColumn), y: mid)
            let radius: CGFloat = 4.5
            let dotRect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(GraphPalette.color(row.dotColorIndex)))
        }
        .frame(width: max(CGFloat(laneCount) * laneWidth, laneWidth), height: rowHeight)
    }
}
