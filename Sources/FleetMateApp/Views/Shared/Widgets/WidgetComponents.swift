import SwiftUI
import Charts
import FleetMateCore

// MARK: - Widgets Section

extension AppTab {
    /// Tabs that carry a Widgets strip; the toolbar's Graphs button is
    /// offered only on these.
    var hasWidgets: Bool {
        switch self {
        case .development, .projects, .devices, .inventory, .tickets: true
        case .reporting, .manage, .identity: false
        }
    }

    /// Per-tab persistence key for whether the widgets are hidden.
    /// Development moved to collapsed-by-default and Projects to shown, so
    /// their keys moved too: a choice stored before the change does not
    /// override the new default; the next one is kept as before.
    var widgetsCollapsedKey: String {
        switch self {
        case .development, .projects: "widgets.collapsed.\(rawValue).v2"
        default: "widgets.collapsed.\(rawValue)"
        }
    }

    /// Development opens on the work itself — changes, diffs, commits — so
    /// its graphs start hidden until the Graphs button shows them. Every
    /// other tab opens with its graphs shown. Either way the choice is kept.
    var widgetsCollapsedByDefault: Bool { self == .development }
}

/// A tab's widgets as an invisible accordion: no header of its own, shown or
/// hidden from the toolbar's Graphs button. Hidden, the tab is exactly its
/// own layout. State is kept per tab.
///
/// Every row is one band: cards share the row's height and stretch across
/// its width (see `WidgetRowLayout`). With `maxHeight`, a strip taller than
/// that scrolls inside itself rather than pushing the tab's own content off
/// the screen.
struct WidgetsSection<Content: View>: View {
    let tab: AppTab
    var singleRow = false
    var maxHeight: CGFloat?
    @ViewBuilder var content: Content

    @AppStorage private var collapsed: Bool
    @State private var contentHeight: CGFloat = 0

    /// `equalHeights` is kept for existing call sites; rows are always level.
    init(tab: AppTab, equalHeights: Bool = true, singleRow: Bool = false, maxHeight: CGFloat? = nil,
         @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.singleRow = singleRow
        self.maxHeight = maxHeight
        self.content = content()
        _collapsed = AppStorage(wrappedValue: tab.widgetsCollapsedByDefault, tab.widgetsCollapsedKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                Group {
                    if let maxHeight {
                        ScrollView(.vertical) {
                            rows.background {
                                GeometryReader { geo in
                                    Color.clear.preference(key: WidgetStripHeight.self, value: geo.size.height)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: max(1, min(contentHeight, maxHeight)))
                        .onPreferenceChange(WidgetStripHeight.self) { contentHeight = $0 }
                    } else {
                        rows
                    }
                }
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    private var rows: some View {
        WidgetRowLayout(spacing: 12, minUnitWidth: 240, wraps: !singleRow) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct WidgetStripHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Toolbar toggle for the current tab's widgets. Rebuilt per tab (`.id`) so
/// its storage key follows the tab.
struct GraphsToolbarButton: View {
    let tab: AppTab
    @AppStorage private var collapsed: Bool

    init(tab: AppTab) {
        self.tab = tab
        _collapsed = AppStorage(wrappedValue: tab.widgetsCollapsedByDefault, tab.widgetsCollapsedKey)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
        } label: {
            Label {
                Text("Graphs")
            } icon: {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(collapsed ? Color.secondary : Color.accentColor)
            }
        }
        .keyboardShortcut("g", modifiers: [.command, .option])
        .help(collapsed ? "Show Graphs (⌥⌘G)" : "Hide Graphs (⌥⌘G)")
        .accessibilityValue(collapsed ? "Hidden" : "Shown")
    }
}

/// How many width units a card takes in `WidgetRowLayout` (default 1).
struct WidgetSpan: LayoutValueKey {
    static let defaultValue = 1
}

extension View {
    func widgetSpan(_ units: Int) -> some View { layoutValue(key: WidgetSpan.self, value: units) }
    /// The card takes a row of its own, whatever the width.
    func widgetFullRow() -> some View { layoutValue(key: WidgetSpan.self, value: WidgetRowLayout.fullRow) }
}

/// A responsive grid for a tab's cards.
///
/// The width is cut into units of at least `minUnitWidth`; a card takes its
/// span of them. Cards keep their order and are split into the fewest rows
/// that hold them, then balanced so every row carries about the same number
/// of units — never a full row followed by one stretched leftover. Each row
/// spans the full width, and every card in a row is offered the row's
/// tallest height, so a row reads as one level band with no holes beside or
/// below its cards.
struct WidgetRowLayout: Layout {
    static let fullRow = 1_000

    var spacing: CGFloat = 12
    var minUnitWidth: CGFloat = 240
    var wraps = true

    private struct Placement { var index: Int; var x: CGFloat; var y: CGFloat; var width: CGFloat; var rowHeight: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> (placements: [Placement], height: CGFloat) {
        guard !subviews.isEmpty else { return ([], 0) }
        let rawSpans = subviews.map { max(1, $0[WidgetSpan.self]) }
        let unitsPerRow = wraps
            ? max(1, Int((width + spacing) / (minUnitWidth + spacing)))
            : rawSpans.filter { $0 < Self.fullRow }.reduce(0, +)
        let rows = WidgetRowPacking.rows(spans: rawSpans, unitsPerRow: max(1, unitsPerRow), fullRow: Self.fullRow)
        let spans = rawSpans.map { min($0, max(1, unitsPerRow)) }

        var placements: [Placement] = []
        var y: CGFloat = 0
        for row in rows {
            let units = row.reduce(0) { $0 + spans[$1] }
            let unitWidth = (width - spacing * CGFloat(row.count - 1)) / CGFloat(max(units, 1))
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            let rowStart = placements.count
            for i in row {
                let w = unitWidth * CGFloat(spans[i])
                let h = subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                placements.append(Placement(index: i, x: x, y: y, width: w))
                rowHeight = max(rowHeight, h)
                x += w + spacing
            }
            for k in rowStart..<placements.count { placements[k].rowHeight = rowHeight }
            y += rowHeight + spacing
        }
        return (placements, max(0, y - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(subviews.count) * (minUnitWidth + spacing)
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for p in arrange(width: bounds.width, subviews: subviews).placements {
            subviews[p.index].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                                    anchor: .topLeading,
                                    proposal: ProposedViewSize(width: p.width, height: p.rowHeight))
        }
    }
}

// MARK: - Chart text

/// Axis and legend text for widget charts: the app's caption size, scaled
/// with its text-size setting. Swift Charts' own default is smaller and does
/// not follow that setting, so every widget chart sets its labels with this.
extension AppTextStyle {
    static func chartLabel(_ scale: Double) -> Font { AppTextStyle.caption.font(scale: scale) }
}

/// A chart legend in the same caption text as the axes, flowing onto more
/// lines rather than shrinking. Entries keep the series order.
struct WidgetChartLegend: View {
    let items: [(label: String, color: Color)]

    var body: some View {
        WidgetFlowLayout(spacing: 10) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.label).appFont(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widget Card

/// A titled card in a Widgets row, sized to its content and capped so a long
/// chart never turns the strip into the page.
struct WidgetCard<Content: View>: View {
    let title: String
    var isLoading = false
    var maxHeight: CGFloat = 240
    var onTitle: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let onTitle {
                    Button(action: onTitle) {
                        HStack(spacing: 4) {
                            Text(title).appFont(.subheadline, weight: .bold)
                            Image(systemName: "chevron.right")
                                .appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title).appFont(.subheadline, weight: .bold)
                }
                if isLoading { ProgressView().controlSize(.mini).padding(.leading, 2) }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .clipped()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }
}

/// KPI tiles stacked in one cell of the row.
/// With `fillsHeight`, the tiles share whatever height the row offers (a
/// `WidgetsSection(equalHeights:)` row), so the column ends level with the
/// chart cards beside it instead of leaving a gap below.
struct WidgetKPIColumn: View {
    let kpis: [KPI]
    var fillsHeight = true
    var onTap: (KPI) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(kpis) { kpi in
                KPICard(kpi: kpi, fillsHeight: fillsHeight) { onTap(kpi) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
    }
}

struct WidgetEmptyState: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Text(message)
            .appFont(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }
}

// MARK: - Deep links

extension AppState {
    /// Bar/wedge deep-link: strip any "(count)" suffix from the label, stash
    /// the filter for the destination tab, and go. Works within the current
    /// tab too: the tab's onChange of `navigateToModuleFilter` picks it up.
    func openWidgetFilter(tab: AppTab, category: String?, label: String) {
        let value = WidgetFilterMatch.filterValue(label)
        if let category {
            navigateToModuleFilter = ModuleFilterLink(tab: tab, category: category, value: value)
        }
        navigateToTab = tab
    }
}

// MARK: - Donut

/// Donut on the left, a legend carrying every count on the right. The legend
/// is ours rather than Swift Charts': its trailing legend took its width out
/// of the plot and ellipsized the labels.
///
/// Wedge click opens the tab with that value filtered. Deliberately a real
/// tap gesture, NOT `.chartAngleSelection`: angle selection tracks the
/// pointer continuously, so merely resting the cursor on a donut navigated
/// tabs.
struct DonutWidget: View {
    let slices: [ChartSlice]
    var size: CGFloat = 130
    var adaptsToWidth = false
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        let diameter = min(size, 150)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                plot.frame(width: diameter, height: diameter)
                ChartLegendList(slices: slices, onSelect: onSelect)
                    .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: diameter)
            if adaptsToWidth {
                VStack(alignment: .center, spacing: 8) {
                    plot.frame(width: min(diameter, 90), height: min(diameter, 90))
                    ChartLegendList(slices: slices, onSelect: onSelect)
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private static func wedgeFraction(_ slice: ChartSlice, of slices: [ChartSlice]) -> Double {
        let total = slices.reduce(0) { $0 + $1.value }
        return total > 0 ? Double(slice.value) / Double(total) : 0
    }

    private var plot: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Count", slice.value),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Category", slice.label))
            .annotation(position: .overlay) {
                // Only wedges wide enough to hold a number get one, at its
                // natural width; every count is in the legend regardless.
                if Self.wedgeFraction(slice, of: slices) >= 0.12 {
                    Text(slice.value, format: .number)
                        .appFont(.caption, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .fixedSize()
                }
            }
        }
        .chartForegroundStyleScale(domain: slices.map(\.label), range: slices.map(\.color))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let onSelect, let plotAnchor = proxy.plotFrame else { return }
                        let plot = geo[plotAnchor]
                        let dx = location.x - plot.midX
                        let dy = location.y - plot.midY
                        let radius = (dx * dx + dy * dy).squareRoot()
                        let outer = min(plot.width, plot.height) / 2
                        guard radius <= outer, radius >= outer * 0.4 else { return }
                        // SectorMarks start at 12 o'clock and run clockwise.
                        var angle = atan2(dy, dx) + .pi / 2
                        if angle < 0 { angle += 2 * .pi }
                        let fraction = angle / (2 * .pi)
                        let total = slices.reduce(0) { $0 + $1.value }
                        guard total > 0 else { return }
                        var cumulative = 0.0
                        for slice in slices {
                            cumulative += Double(slice.value) / Double(total)
                            if fraction <= cumulative {
                                onSelect(slice.label)
                                break
                            }
                        }
                    }
            }
        }
    }
}

// MARK: - Horizontal Bar List

/// Label | bar | count rows. The label column sizes to the longest label (up to
/// a cap, past which the label truncates); the count column sizes to the
/// widest count and never truncates; the bar takes whatever is left.
struct HorizontalBarList: View {
    let bars: [ChartBar]
    var compact = false
    var onSelect: ((String) -> Void)? = nil

    @State private var hovered: UUID?

    var body: some View {
        let maxValue = max(bars.map(\.value).max() ?? 0, 1)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            ForEach(bars) { bar in
                GridRow {
                    Text(bar.label)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: compact ? 110 : 180, alignment: .leading)
                        .help(bar.label)
                        .modifier(BarRowInteraction(id: bar.id, label: bar.label, hovered: $hovered, onSelect: onSelect))
                    GeometryReader { geo in
                        let fraction = CGFloat(bar.value) / CGFloat(maxValue)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bar.color.opacity(hovered == bar.id ? 0.72 : 1))
                            .frame(width: bar.value > 0 ? max(geo.size.width * fraction, 3) : 0)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(minWidth: 40, maxWidth: .infinity)
                    .frame(height: 14)
                    .modifier(BarRowInteraction(id: bar.id, label: bar.label, hovered: $hovered, onSelect: onSelect))
                    Text(bar.value, format: .number)
                        .appFont(.caption, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                        .modifier(BarRowInteraction(id: bar.id, label: bar.label, hovered: $hovered, onSelect: onSelect))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Hover highlight and click-through shared by every cell of a bar row (a
/// GridRow takes no gestures of its own).
private struct BarRowInteraction: ViewModifier {
    let id: UUID
    let label: String
    @Binding var hovered: UUID?
    let onSelect: ((String) -> Void)?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = id } else if hovered == id { hovered = nil }
            }
            .onTapGesture { onSelect?(label) }
    }
}

// MARK: - Chart Legend

/// Swatch, label and count per slice. Labels wrap onto a second line rather
/// than truncate; the count sits in its own trailing column at natural width.
struct ChartLegendList: View {
    let slices: [ChartSlice]
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(slices) { slice in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(slice.color).frame(width: 8, height: 8)
                    Text(Self.displayLabel(slice))
                        .appFont(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(slice.value, format: .number)
                        .appFont(.caption, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(slice.label) }
            }
        }
    }

    /// Some slice labels already end in "(count)"; the legend shows the count
    /// in its own column, so drop the duplicate.
    static func displayLabel(_ slice: ChartSlice) -> String {
        let suffix = " (\(slice.value))"
        return slice.label.hasSuffix(suffix) ? String(slice.label.dropLast(suffix.count)) : slice.label
    }
}

// MARK: - Treemap Chart

struct TreemapChart: View {
    let slices: [ChartSlice]
    let height: CGFloat
    /// Block click → deep-link into the owning tab, filtered to that value.
    var onSelect: ((String) -> Void)? = nil

    @State private var hoveredSlice: ChartSlice? = nil
    @State private var hoveredRect: CGRect = .zero

    var body: some View {
        let total = slices.reduce(0) { $0 + $1.value }
        VStack(spacing: 4) {
            GeometryReader { geo in
                let rects = treemapLayout(slices: slices, total: total, bounds: CGRect(origin: .zero, size: geo.size))
                ZStack {
                    ForEach(Array(zip(slices, rects)), id: \.0.id) { slice, rect in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(slice.color.opacity(hoveredSlice?.id == slice.id ? 0.72 : 1.0))
                            .frame(width: max(rect.width - 2, 0), height: max(rect.height - 2, 0))
                            .overlay {
                                if rect.width > 48 && rect.height > 30 {
                                    VStack(spacing: 1) {
                                        Text(slice.label)
                                            .appFont(.caption, weight: .bold)
                                            .lineLimit(1)
                                        Text(slice.value, format: .number)
                                            .appFont(.caption)
                                            .monospacedDigit()
                                            .fixedSize()
                                    }
                                    .foregroundStyle(.white)
                                }
                            }
                            .position(x: rect.midX, y: rect.midY)
                            .onHover { isHovering in
                                hoveredSlice = isHovering ? slice : nil
                                hoveredRect = isHovering ? rect : .zero
                            }
                            .onTapGesture { onSelect?(slice.label) }
                    }
                    // Hover tooltip
                    if let slice = hoveredSlice {
                        let pct = total > 0 ? Int(Double(slice.value) / Double(total) * 100) : 0
                        let tx = min(max(hoveredRect.midX, 55), geo.size.width - 55)
                        let ty = hoveredRect.minY > 44 ? hoveredRect.minY - 28 : hoveredRect.maxY + 28
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slice.label).appFont(.caption, weight: .bold)
                            Text("\(slice.value)  ·  \(pct)%").appFont(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .position(x: tx, y: ty)
                        .zIndex(100)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: height)
            // Legend: whole entries flow onto the next line; an entry never
            // breaks inside itself.
            WidgetFlowLayout(spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 4) {
                        Circle().fill(slice.color).frame(width: 7, height: 7)
                        Text(slice.label)
                            .appFont(.caption).foregroundStyle(.secondary)
                        Text(slice.value, format: .number)
                            .appFont(.caption, weight: .medium).monospacedDigit()
                    }
                    .fixedSize()
                    .onTapGesture { onSelect?(slice.label) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func treemapLayout(slices: [ChartSlice], total: Int, bounds: CGRect) -> [CGRect] {
        guard !slices.isEmpty, total > 0 else { return [] }
        let areas = slices.map { CGFloat($0.value) / CGFloat(total) * bounds.width * bounds.height }
        var rects = Array(repeating: CGRect.zero, count: slices.count)
        var remaining = bounds
        var i = 0
        while i < slices.count {
            let isWide = remaining.width >= remaining.height
            let sideLen = isWide ? remaining.height : remaining.width
            var rowIndices: [Int] = []
            var rowArea: CGFloat = 0
            var bestWorst: CGFloat = .infinity
            for j in i..<slices.count {
                let candidate = rowArea + areas[j]
                let strip = candidate / sideLen
                let aspectWorst = (rowIndices + [j]).map { idx -> CGFloat in
                    let w = areas[idx] / strip
                    let h = strip
                    return max(w / h, h / w)
                }.max() ?? .infinity
                if aspectWorst <= bestWorst || rowIndices.isEmpty {
                    rowIndices.append(j)
                    rowArea = candidate
                    bestWorst = aspectWorst
                } else {
                    break
                }
            }
            let stripSize = rowArea / sideLen
            var offset: CGFloat = 0
            for idx in rowIndices {
                let itemLen = areas[idx] / stripSize
                if isWide {
                    rects[idx] = CGRect(x: remaining.minX, y: remaining.minY + offset, width: stripSize, height: itemLen)
                } else {
                    rects[idx] = CGRect(x: remaining.minX + offset, y: remaining.minY, width: itemLen, height: stripSize)
                }
                offset += itemLen
            }
            if isWide {
                remaining = CGRect(x: remaining.minX + stripSize, y: remaining.minY,
                                   width: remaining.width - stripSize, height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + stripSize,
                                   width: remaining.width, height: remaining.height - stripSize)
            }
            i += rowIndices.count
        }
        return rects
    }
}

// MARK: - KPI Card

struct KPICard: View {
    let kpi: KPI
    var fillsHeight = true
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 10) {
                Image(systemName: kpi.icon)
                    .appFont(.title3)
                    .foregroundStyle(kpi.color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    if kpi.loading {
                        SkeletonView(width: 60, height: 22, cornerRadius: 4)
                    } else {
                        Text(kpi.value)
                            .appFont(.title2, weight: .bold).monospacedDigit()
                    }
                    Text(kpi.title)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxHeight: fillsHeight ? .infinity : nil)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout

struct WidgetFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
