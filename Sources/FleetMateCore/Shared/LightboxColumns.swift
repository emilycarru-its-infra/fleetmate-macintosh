import Foundation

/// How a detail view shown in the lightbox divides its width.
///
/// The lightbox is 90% of the window, so it runs from under 500 pt on a small
/// window to well over 2,000 pt on a large display. One narrow reading column
/// with the fields pinned at the far edge wastes most of that. The plan grows
/// the reading column up to a comfortable line length, keeps the fields
/// column directly beside it, and once there is room for two readable columns
/// moves the discussion (comments) into a column of its own. Width left over
/// after every column reaches its maximum becomes an even margin on both
/// sides, so the columns stay together rather than drifting apart.
public struct LightboxColumns: Equatable, Sendable {
    public enum Arrangement: Equatable, Sendable {
        /// One scrolling column: reading, discussion, then fields.
        case stacked
        /// Reading and discussion in one column, fields beside it.
        case readingAndSide
        /// Reading, discussion and fields side by side, each scrolling on its own.
        case readingDiscussionAndSide
    }

    public var arrangement: Arrangement
    public var readingWidth: Double
    /// Zero unless the discussion has its own column.
    public var discussionWidth: Double
    /// Zero when stacked.
    public var sideWidth: Double
    /// Left over on each side once every column is at its maximum.
    public var margin: Double

    // Prose reads best between roughly 60 and 110 characters a line; at the
    // body size that is about 520 to 960 pt.
    public static let readingMin = 520.0
    public static let readingMax = 960.0
    public static let discussionMin = 440.0
    public static let discussionMax = 840.0
    public static let sideMin = 300.0
    public static let sideMax = 400.0
    /// The hairline between columns.
    public static let divider = 1.0

    /// Below this the fields column would squeeze the reading column under
    /// its minimum, so everything stacks.
    public static var sideBySideWidth: Double { readingMin + divider + sideMin }

    /// From here reading and discussion each get a readable column of their own.
    public static var threeColumnWidth: Double {
        readingMin + discussionMin + sideMax + 2 * divider
    }

    public init(arrangement: Arrangement, readingWidth: Double, discussionWidth: Double, sideWidth: Double, margin: Double) {
        self.arrangement = arrangement
        self.readingWidth = readingWidth
        self.discussionWidth = discussionWidth
        self.sideWidth = sideWidth
        self.margin = margin
    }

    /// The plan for a content area `width` points wide. A view without a
    /// discussion (nothing to put in a second column) never goes to three columns.
    public static func plan(width rawWidth: Double, hasDiscussion: Bool = true) -> LightboxColumns {
        let width = max(rawWidth.isFinite ? rawWidth : 0, 0)

        if width < sideBySideWidth {
            return LightboxColumns(arrangement: .stacked, readingWidth: width, discussionWidth: 0, sideWidth: 0, margin: 0)
        }

        // The fields column takes about a fifth of the width, within its bounds.
        let side = min(max((width * 0.22).rounded(.down), sideMin), sideMax)

        if hasDiscussion, width >= threeColumnWidth {
            let available = width - side - 2 * divider
            // Reading gets the larger share; the description usually carries
            // the most prose, and comments are shorter paragraphs.
            var reading = min(max((available * 0.54).rounded(.down), readingMin), readingMax)
            var discussion = min(max(available - reading, discussionMin), discussionMax)
            // When discussion hit its maximum first, hand the rest back to reading.
            reading = min(available - discussion, readingMax)
            discussion = min(available - reading, discussionMax)
            let leftover = max(available - reading - discussion, 0)
            return LightboxColumns(
                arrangement: .readingDiscussionAndSide,
                readingWidth: reading,
                discussionWidth: discussion,
                sideWidth: side,
                margin: (leftover / 2).rounded(.down)
            )
        }

        let available = width - side - divider
        let reading = min(available, readingMax)
        let leftover = max(available - reading, 0)
        return LightboxColumns(
            arrangement: .readingAndSide,
            readingWidth: reading,
            discussionWidth: 0,
            sideWidth: side,
            margin: (leftover / 2).rounded(.down)
        )
    }

    /// The total width the columns take, margins excluded.
    public var contentWidth: Double {
        switch arrangement {
        case .stacked: return readingWidth
        case .readingAndSide: return readingWidth + Self.divider + sideWidth
        case .readingDiscussionAndSide: return readingWidth + discussionWidth + sideWidth + 2 * Self.divider
        }
    }
}
