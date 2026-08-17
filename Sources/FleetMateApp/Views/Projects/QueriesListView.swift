import SwiftUI
import FleetMateCore

// MARK: - Display Models

/// One work item row inside a stored query's expanded results.
struct QueryDisplayRow: Identifiable {
    let task: UnifiedTask
    let depth: Int
    let hasChildren: Bool
    let queryId: String

    var id: String { "\(queryId):\(task.id)" }
}

/// A stored query with its materialized rows, ready to render.
struct QueryRunDisplay: Identifiable {
    let query: AdoSharedQuery
    let rows: [QueryDisplayRow]
    let truncated: Bool
    /// Grouping key derived from the rows' dominant area path
    /// (e.g. "Devices", "Systems"), falling back to the query's name prefix.
    let areaBucket: String

    var id: String { query.id }

    /// Dominant area-path bucket: the second path component when present
    /// ("Projects\Devices\Macintosh" → "Devices"), else the project itself.
    /// Empty queries fall back to the "Bucket - Query name" convention.
    static func areaBucket(rows: [QueryDisplayRow], queryName: String) -> String {
        var counts: [String: Int] = [:]
        for row in rows {
            guard let area = row.task.metadata["areaPath"], !area.isEmpty else { continue }
            let comps = area.split(separator: "\\")
            let bucket = comps.count >= 2 ? String(comps[1]) : String(comps[0])
            counts[bucket, default: 0] += 1
        }
        if let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            return best
        }
        for separator in [" - ", " — "] {
            if let range = queryName.range(of: separator) {
                return String(queryName[..<range.lowerBound])
            }
        }
        return "General"
    }
}

// MARK: - Columns

/// The grid's columns, mirroring the Azure DevOps query results grid.
/// Title is the flexible column; the rest carry user-resizable widths.
enum QueriesColumn: String, CaseIterable {
    case id, title, state, tags, assignee, changed

    var header: String {
        switch self {
        case .id: return "ID"
        case .title: return "Title"
        case .state: return "State"
        case .tags: return "Tags"
        case .assignee: return "Assigned To"
        case .changed: return "Changed"
        }
    }

    var minWidth: Double {
        switch self {
        case .id: return 36
        case .title: return 120
        default: return 56
        }
    }
}

/// Current column widths as a plain value, passed into each row so rows and
/// header stay in lockstep. Title is the flexible remainder and carries no
/// stored width.
struct QueriesColumnWidths {
    var id: Double = 44
    var state: Double = 90
    var tags: Double = 140
    var assignee: Double = 130
    var changed: Double = 80

    func width(_ column: QueriesColumn) -> Double {
        switch column {
        case .id: return id
        case .title: return 0
        case .state: return state
        case .tags: return tags
        case .assignee: return assignee
        case .changed: return changed
        }
    }
}

/// Active sort. `nil` means the query's own order (tree order for tree
/// queries) — the default, and the only mode that keeps indentation.
struct QueriesSort: Equatable {
    var column: QueriesColumn
    var ascending: Bool
}

// MARK: - Queries List View

/// The Projects List view: every Shared Query rendered like the Azure DevOps
/// query results grid — expanded rows with tree indentation — sectioned by
/// area path, with search and category filters narrowing rows in place.
struct QueriesListView<MenuContent: View>: View {
    let sections: [(bucket: String, runs: [QueryRunDisplay])]
    let isLoading: Bool
    let hasLoadedOnce: Bool
    let searchText: String
    let filterMatch: (UnifiedTask) -> Bool
    let filtersActive: Bool
    let showClosed: Bool
    @Binding var collapsedQueryIds: Set<String>
    @Binding var selectedTask: UnifiedTask?
    let onOpenQuery: (AdoSharedQuery) -> Void
    @ViewBuilder var contextMenuBuilder: (UnifiedTask) -> MenuContent

    // Persisted, user-resizable widths. Stored flat on the view so writes
    // re-render; bundled into QueriesColumnWidths for the rows.
    @AppStorage("queriesList.width.id") private var idWidth: Double = 44
    @AppStorage("queriesList.width.state") private var stateWidth: Double = 90
    @AppStorage("queriesList.width.tags") private var tagsWidth: Double = 140
    @AppStorage("queriesList.width.assignee") private var assigneeWidth: Double = 130
    @AppStorage("queriesList.width.changed") private var changedWidth: Double = 80

    @State private var sort: QueriesSort? = nil
    /// Width of the column being dragged, captured at drag start so the
    /// translation applies to a stable baseline.
    @State private var dragBaseWidth: Double? = nil

    private var columnWidths: QueriesColumnWidths {
        QueriesColumnWidths(
            id: idWidth, state: stateWidth, tags: tagsWidth,
            assignee: assigneeWidth, changed: changedWidth
        )
    }

    private func setWidth(_ column: QueriesColumn, to value: Double) {
        let clamped = max(column.minWidth, min(value, 400))
        switch column {
        case .id: idWidth = clamped
        case .title: break
        case .state: stateWidth = clamped
        case .tags: tagsWidth = clamped
        case .assignee: assigneeWidth = clamped
        case .changed: changedWidth = clamped
        }
    }

    init(
        sections: [(bucket: String, runs: [QueryRunDisplay])],
        isLoading: Bool,
        hasLoadedOnce: Bool,
        searchText: String,
        filterMatch: @escaping (UnifiedTask) -> Bool,
        filtersActive: Bool,
        showClosed: Bool,
        collapsedQueryIds: Binding<Set<String>>,
        selectedTask: Binding<UnifiedTask?>,
        onOpenQuery: @escaping (AdoSharedQuery) -> Void,
        @ViewBuilder contextMenuBuilder: @escaping (UnifiedTask) -> MenuContent
    ) {
        self.sections = sections
        self.isLoading = isLoading
        self.hasLoadedOnce = hasLoadedOnce
        self.searchText = searchText
        self.filterMatch = filterMatch
        self.filtersActive = filtersActive
        self.showClosed = showClosed
        self._collapsedQueryIds = collapsedQueryIds
        self._selectedTask = selectedTask
        self.onOpenQuery = onOpenQuery
        self.contextMenuBuilder = contextMenuBuilder
    }

    var body: some View {
        Group {
            if isLoading && !hasLoadedOnce {
                VStack {
                    ProgressView("Loading shared queries...")
                        .padding(.top, 60)
                    Spacer()
                }
            } else if sections.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "No Shared Queries",
                        systemImage: "rectangle.stack.badge.questionmark",
                        description: Text("No Shared Queries found in the DevOps project, or they are still loading.")
                    )
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    columnHeaderRow
                    Divider()
                    queryList
                }
            }
        }
    }

    private var queryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(visibleSections, id: \.bucket) { section in
                    Section {
                        ForEach(section.runs, id: \.0.id) { pair in
                            querySection(pair)
                        }
                    } header: {
                        bucketHeader(section.bucket, count: section.runs.count)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
    }

    // MARK: Column header

    private var columnHeaderRow: some View {
        HStack(spacing: 8) {
            headerCell(.id)
                .frame(width: columnWidths.id, alignment: .trailing)
            resizeHandle(.id)
            headerCell(.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell(.state)
                .frame(width: columnWidths.state, alignment: .leading)
            resizeHandle(.state)
            headerCell(.tags)
                .frame(width: columnWidths.tags, alignment: .leading)
            resizeHandle(.tags)
            headerCell(.assignee)
                .frame(width: columnWidths.assignee, alignment: .leading)
            resizeHandle(.assignee)
            headerCell(.changed)
                .frame(width: columnWidths.changed, alignment: .trailing)
            resizeHandle(.changed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func headerCell(_ column: QueriesColumn) -> some View {
        Button {
            cycleSort(column)
        } label: {
            HStack(spacing: 3) {
                Text(column.header)
                    .appFont(.caption, weight: .semibold)
                    .foregroundColor(sort?.column == column ? .primary : .secondary)
                if let sort, sort.column == column {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .appFont(fixed: 8, weight: .bold)
                        .foregroundColor(.secondary)
                }
            }
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Sort by \(column.header)")
    }

    /// Click cycles ascending → descending → back to query order.
    private func cycleSort(_ column: QueriesColumn) {
        if let current = sort, current.column == column {
            sort = current.ascending ? QueriesSort(column: column, ascending: false) : nil
        } else {
            sort = QueriesSort(column: column, ascending: true)
        }
    }

    /// Slim draggable divider to the right of a fixed-width column.
    private func resizeHandle(_ column: QueriesColumn) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
            .contentShape(Rectangle().inset(by: -3))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragBaseWidth == nil {
                            dragBaseWidth = columnWidths.width(column)
                        }
                        if let base = dragBaseWidth {
                            setWidth(column, to: base + value.translation.width)
                        }
                    }
                    .onEnded { _ in dragBaseWidth = nil }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    // MARK: Sorting

    /// Rows in display order for one query: the query's own order by default,
    /// or flat-sorted by the active column. Sorting breaks tree hierarchy, so
    /// sorted rows drop their indentation, matching the ADO grid.
    private func displayRows(_ rows: [QueryDisplayRow]) -> [QueryDisplayRow] {
        guard let sort else { return rows }
        let sorted = rows.sorted { a, b in
            let ordered: Bool
            switch sort.column {
            case .id:
                ordered = (Int(a.task.id) ?? 0) < (Int(b.task.id) ?? 0)
            case .title:
                ordered = a.task.title.localizedCaseInsensitiveCompare(b.task.title) == .orderedAscending
            case .state:
                let sa = a.task.metadata["state"] ?? ""
                let sb = b.task.metadata["state"] ?? ""
                ordered = sa.localizedCaseInsensitiveCompare(sb) == .orderedAscending
            case .tags:
                let ta = a.task.labels.first ?? ""
                let tb = b.task.labels.first ?? ""
                ordered = ta.localizedCaseInsensitiveCompare(tb) == .orderedAscending
            case .assignee:
                let aa = a.task.assignees.first ?? ""
                let ab = b.task.assignees.first ?? ""
                ordered = aa.localizedCaseInsensitiveCompare(ab) == .orderedAscending
            case .changed:
                ordered = a.task.updatedAt < b.task.updatedAt
            }
            return sort.ascending ? ordered : !ordered
        }
        return sorted
    }

    // MARK: Filtering

    /// Sections after search/filter narrowing. A query whose own name matches
    /// the search shows all its rows; otherwise rows must match, and matching
    /// rows keep their ancestors so tree context survives filtering.
    private var visibleSections: [(bucket: String, runs: [(QueryRunDisplay, [QueryDisplayRow])])] {
        let narrowing = !searchText.isEmpty || filtersActive || !showClosed
        var result: [(String, [(QueryRunDisplay, [QueryDisplayRow])])] = []
        for section in sections {
            var visible: [(QueryRunDisplay, [QueryDisplayRow])] = []
            for run in section.runs {
                let rows = visibleRows(run)
                if !narrowing || !rows.isEmpty || queryNameMatches(run) {
                    visible.append((run, rows))
                }
            }
            if !visible.isEmpty {
                result.append((section.bucket, visible))
            }
        }
        return result
    }

    private func queryNameMatches(_ run: QueryRunDisplay) -> Bool {
        guard !searchText.isEmpty else { return false }
        return run.query.name.localizedCaseInsensitiveContains(searchText)
    }

    private func visibleRows(_ run: QueryRunDisplay) -> [QueryDisplayRow] {
        let nameMatch = queryNameMatches(run)
        let searchNarrows = !searchText.isEmpty && !nameMatch
        guard searchNarrows || filtersActive || !showClosed else { return run.rows }

        var include = Set<Int>()
        var ancestorStack: [Int] = []
        for (index, row) in run.rows.enumerated() {
            while ancestorStack.count > row.depth { ancestorStack.removeLast() }
            ancestorStack.append(index)
            if rowMatches(row, applySearch: searchNarrows) {
                include.formUnion(ancestorStack)
            }
        }
        return run.rows.enumerated()
            .filter { include.contains($0.offset) }
            .map(\.element)
    }

    private func rowMatches(_ row: QueryDisplayRow, applySearch: Bool) -> Bool {
        // Closed rows hide when the toggle is off; a closed ancestor of an
        // open child still shows via the ancestor-retention pass above.
        if !showClosed && row.task.state == .closed { return false }
        if filtersActive && !filterMatch(row.task) { return false }
        guard applySearch else { return true }
        let q = searchText
        if row.task.title.localizedCaseInsensitiveContains(q) { return true }
        if row.task.id.contains(q) { return true }
        if row.task.assignees.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        if row.task.labels.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        if (row.task.metadata["workItemType"] ?? "").localizedCaseInsensitiveContains(q) { return true }
        if (row.task.metadata["state"] ?? "").localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    // MARK: Keyboard navigation

    private var flatVisibleTasks: [UnifiedTask] {
        visibleSections.flatMap { section in
            section.runs.flatMap { run, rows in
                collapsedQueryIds.contains(run.id) ? [] : displayRows(rows).map(\.task)
            }
        }
    }

    private func moveSelection(by offset: Int) {
        let list = flatVisibleTasks
        guard !list.isEmpty else { return }
        guard let current = selectedTask,
              let index = list.firstIndex(where: { $0.compositeKey == current.compositeKey }) else {
            selectedTask = list.first
            return
        }
        selectedTask = list[min(max(index + offset, 0), list.count - 1)]
    }

    // MARK: Section pieces

    private func bucketHeader(_ bucket: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(bucket)
                .appFont(.headline)
            Text("\(count) \(count == 1 ? "query" : "queries")")
                .appFont(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func querySection(_ pair: (QueryRunDisplay, [QueryDisplayRow])) -> some View {
        let (run, rows) = pair
        let collapsed = collapsedQueryIds.contains(run.id)

        VStack(alignment: .leading, spacing: 0) {
            queryHeader(run, visibleCount: rows.count, collapsed: collapsed)
            if !collapsed {
                if rows.isEmpty {
                    Text("No items")
                        .appFont(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 44)
                        .padding(.vertical, 6)
                } else {
                    ForEach(displayRows(rows)) { row in
                        QueryWorkItemRow(
                            row: row,
                            isSelected: selectedTask?.compositeKey == row.task.compositeKey,
                            widths: columnWidths,
                            flattened: sort != nil
                        )
                        .contentShape(Rectangle())
                        .contextMenu { contextMenuBuilder(row.task) }
                        .onTapGesture { selectedTask = row.task }
                    }
                    if run.truncated {
                        Text("Showing the first \(run.rows.count) items — open in Azure DevOps for the full result.")
                            .appFont(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 44)
                            .padding(.vertical, 6)
                    }
                }
            }
            Divider()
        }
    }

    private func queryHeader(_ run: QueryRunDisplay, visibleCount: Int, collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .appFont(fixed: 11, weight: .semibold)
                .foregroundColor(.secondary)
                .frame(width: 14)
            Image(systemName: run.query.queryType == "flat" ? "tablecells" : "list.bullet.indent")
                .foregroundColor(.accentColor)
            Text(run.query.name)
                .fontWeight(.semibold)
            if !run.query.folderPath.isEmpty {
                Text(run.query.folderPath)
                    .appFont(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
                    .foregroundColor(.secondary)
            }
            Text("\(visibleCount)")
                .appFont(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(8)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                onOpenQuery(run.query)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open query in Azure DevOps")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed {
                collapsedQueryIds.remove(run.id)
            } else {
                collapsedQueryIds.insert(run.id)
            }
        }
    }
}

// MARK: - Work Item Row

/// One result row, echoing the Azure DevOps query grid columns:
/// ID · type icon · title (indented by tree depth) · state · tags ·
/// assignee · changed date. Column widths come from the shared resizable
/// set; `flattened` drops the tree indent while a sort is active.
struct QueryWorkItemRow: View {
    let row: QueryDisplayRow
    let isSelected: Bool
    var widths = QueriesColumnWidths()
    var flattened = false

    private var task: UnifiedTask { row.task }

    var body: some View {
        HStack(spacing: 8) {
            Text(task.id)
                .appFont(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: widths.id, alignment: .trailing)
            spacer(.id)

            HStack(spacing: 6) {
                Color.clear
                    .frame(width: flattened ? 0 : CGFloat(row.depth) * 18, height: 1)
                Image(systemName: typeIcon.symbol)
                    .appFont(fixed: 12)
                    .foregroundColor(typeIcon.color)
                Text(task.title)
                    .lineLimit(1)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(task.metadata["state"] ?? task.state.displayName)
                    .appFont(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: widths.state, alignment: .leading)
            spacer(.state)

            HStack(spacing: 4) {
                ForEach(task.labels.prefix(2), id: \.self) { label in
                    Text(label)
                        .appFont(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .frame(width: widths.tags, alignment: .leading)
            spacer(.tags)

            Text(task.assignees.first ?? "")
                .appFont(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: widths.assignee, alignment: .leading)
            spacer(.assignee)

            Text(changedDateText)
                .appFont(.caption)
                .foregroundColor(.secondary)
                .frame(width: widths.changed, alignment: .trailing)
            spacer(.changed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    /// Mirrors the header's resize-handle footprint so row columns line up
    /// with header columns exactly.
    private func spacer(_ column: QueriesColumn) -> some View {
        Color.clear.frame(width: 5, height: 1)
    }

    private var changedDateText: String {
        guard task.updatedAt != .distantPast else { return "" }
        return task.updatedAt.formatted(.relative(presentation: .named))
    }

    private var typeIcon: (symbol: String, color: Color) {
        switch (task.metadata["workItemType"] ?? "").lowercased() {
        case "initiative", "epic":
            return ("crown.fill", .orange)
        case "workstream", "feature":
            return ("trophy.fill", .purple)
        case "deliverable", "user story", "product backlog item":
            return ("checkmark.square.fill", .green)
        case "task":
            return ("list.clipboard.fill", .yellow)
        case "bug":
            return ("ladybug.fill", .red)
        case "issue", "impediment":
            return ("exclamationmark.triangle.fill", .pink)
        default:
            return ("doc.fill", .gray)
        }
    }

    private var stateColor: Color {
        switch (task.metadata["state"] ?? "").lowercased() {
        case "new", "to do", "proposed":
            return .gray
        case "active", "in progress", "doing", "committed":
            return .blue
        case "resolved":
            return .orange
        case "closed", "done", "completed":
            return .green
        case "removed":
            return .red
        default:
            return .blue
        }
    }
}
