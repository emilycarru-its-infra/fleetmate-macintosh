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
    @Binding var collapsedQueryIds: Set<String>
    @Binding var selectedTask: UnifiedTask?
    let onOpenQuery: (AdoSharedQuery) -> Void
    @ViewBuilder var contextMenuBuilder: (UnifiedTask) -> MenuContent

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
                queryList
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

    // MARK: Filtering

    /// Sections after search/filter narrowing. A query whose own name matches
    /// the search shows all its rows; otherwise rows must match, and matching
    /// rows keep their ancestors so tree context survives filtering.
    private var visibleSections: [(bucket: String, runs: [(QueryRunDisplay, [QueryDisplayRow])])] {
        let narrowing = !searchText.isEmpty || filtersActive
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
        guard searchNarrows || filtersActive else { return run.rows }

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
                collapsedQueryIds.contains(run.id) ? [] : rows.map(\.task)
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
                    ForEach(rows) { row in
                        QueryWorkItemRow(
                            row: row,
                            isSelected: selectedTask?.compositeKey == row.task.compositeKey
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
/// assignee · changed date.
struct QueryWorkItemRow: View {
    let row: QueryDisplayRow
    let isSelected: Bool

    private var task: UnifiedTask { row.task }

    var body: some View {
        HStack(spacing: 8) {
            Text(task.id)
                .appFont(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            HStack(spacing: 6) {
                Color.clear
                    .frame(width: CGFloat(row.depth) * 18, height: 1)
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
            .frame(width: 90, alignment: .leading)

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
            .frame(width: 140, alignment: .leading)

            Text(task.assignees.first ?? "")
                .appFont(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            Text(changedDateText)
                .appFont(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
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
