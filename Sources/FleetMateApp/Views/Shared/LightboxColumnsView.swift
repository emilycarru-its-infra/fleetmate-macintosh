import SwiftUI
import FleetMateCore

/// Lays a lightbox detail view out across the width it has, following
/// `LightboxColumns`: stacked when narrow, reading beside fields at a laptop
/// size, and reading, discussion and fields as three independently scrolling
/// columns on a large display. The fields column always sits directly beside
/// the content; spare width becomes an even margin around the whole group.
struct LightboxColumnsView<Reading: View, Discussion: View, Composer: View, Side: View>: View {
    /// False when the view has no discussion worth its own column.
    var hasDiscussion: Bool = true
    @ViewBuilder var reading: () -> Reading
    @ViewBuilder var discussion: () -> Discussion
    /// The new-comment field. Pinned under the discussion column when it has
    /// one, so it stays in reach however long the thread is.
    @ViewBuilder var composer: () -> Composer
    @ViewBuilder var side: () -> Side

    var body: some View {
        GeometryReader { geo in
            let plan = LightboxColumns.plan(width: geo.size.width, hasDiscussion: hasDiscussion)
            arranged(plan)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    @ViewBuilder
    private func arranged(_ plan: LightboxColumns) -> some View {
        switch plan.arrangement {
        case .stacked:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    readingColumn
                    sectionDivider
                    discussionColumn
                    sectionDivider
                    composer()
                    sectionDivider
                    side()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .readingAndSide:
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        readingColumn
                        sectionDivider
                        discussionColumn
                        sectionDivider
                        composer()
                    }
                    .modifier(ColumnPadding())
                }
                .frame(width: plan.readingWidth)

                Divider()

                sideColumn
                    .frame(width: plan.sideWidth)
            }
            .padding(.horizontal, plan.margin)

        case .readingDiscussionAndSide:
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    readingColumn
                        .modifier(ColumnPadding())
                }
                .frame(width: plan.readingWidth)

                Divider()

                VStack(spacing: 0) {
                    ScrollView {
                        discussionColumn
                            .modifier(ColumnPadding())
                    }
                    Divider()
                    composer()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .frame(width: plan.discussionWidth)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Discussion")

                Divider()

                sideColumn
                    .frame(width: plan.sideWidth)
            }
            .padding(.horizontal, plan.margin)
        }
    }

    private var readingColumn: some View {
        reading()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var discussionColumn: some View {
        discussion()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sideColumn: some View {
        ScrollView {
            side()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 10)
    }
}

private struct ColumnPadding: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
private struct LightboxColumnsPreviewBody: View {
    var body: some View {
        LightboxColumnsView {
            VStack(alignment: .leading, spacing: 8) {
                Text("A work item title long enough to wrap at narrow widths").font(.title2.weight(.semibold))
                Text(String(repeating: "Description prose that should read at a comfortable line length. ", count: 12))
            }
        } discussion: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Comments (3)").font(.headline)
                MarkdownTextView(content: "A comment with code:\n\n```\nlet columns = LightboxColumns.plan(width: geo.size.width, hasDiscussion: true) // a long line that must scroll or wrap, not clip\n```")
            }
        } composer: {
            TextField("Add a comment", text: .constant(""))
        } side: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fields").font(.headline)
                Text("State: Active")
                Text("Assigned to: Someone")
            }
        }
    }
}

#Preview("Lightbox 1280 window") {
    LightboxColumnsPreviewBody().frame(width: 1152, height: 700)
}

#Preview("Lightbox 1920 window") {
    LightboxColumnsPreviewBody().frame(width: 1728, height: 900)
}

#Preview("Lightbox 2560 window") {
    LightboxColumnsPreviewBody().frame(width: 2304, height: 1200)
}
#endif
