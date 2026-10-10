import SwiftUI
import AppKit
import Charts
import FleetMateCore

// MARK: - Model

/// What the Insights panel shows and the statistics behind it. The numbers
/// come from `RepoManager.stats` / `statsSummary` — the same code behind
/// `fleetmate repos stats` — so the app and agents always agree.
@MainActor
final class RepoInsightsModel: ObservableObject {
    enum Scope: String, CaseIterable {
        case repository, all

        var title: String {
            switch self {
            case .repository: "This Repository"
            case .all: "All Tracked"
            }
        }
    }

    enum Period: String, CaseIterable {
        case month = "30d", quarter = "90d", half = "6m", year = "1y", all

        var title: String {
            switch self {
            case .month: "30 Days"
            case .quarter: "90 Days"
            case .half: "6 Months"
            case .year: "1 Year"
            case .all: "All Time"
            }
        }

        var since: Date? { self == .all ? nil : RepoStatsRange.parseSince(rawValue) }
    }

    enum Granularity: String, CaseIterable {
        case automatic, day, week, month

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .day: "Daily"
            case .week: "Weekly"
            case .month: "Monthly"
            }
        }

        var bucket: RepoStatsBucket? { RepoStatsBucket(rawValue: rawValue) }
    }

    @Published var scope: Scope = .init(rawValue: UserDefaults.standard.string(forKey: "repos.insights.scope") ?? "") ?? .repository {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "repos.insights.scope") }
    }
    @Published var period: Period = .init(rawValue: UserDefaults.standard.string(forKey: "repos.insights.period") ?? "") ?? .quarter {
        didSet { UserDefaults.standard.set(period.rawValue, forKey: "repos.insights.period") }
    }
    @Published var granularity: Granularity = .init(rawValue: UserDefaults.standard.string(forKey: "repos.insights.granularity") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(granularity.rawValue, forKey: "repos.insights.granularity") }
    }

    @Published private(set) var report: RepoStatsReport?
    @Published private(set) var summary: RepoStatsSummary?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// The request the shown numbers answer, so a refresh of the same view
    /// keeps them on screen until new ones arrive.
    @Published private(set) var shownKey: String?

    func key(selected: RepoRecord?, tracked: [RepoRecord]) -> String {
        let target = scope == .all ? tracked.map(\.id).joined(separator: ",") : (selected?.id ?? "")
        return [scope.rawValue, period.rawValue, granularity.rawValue, target].joined(separator: "|")
    }

    func load(manager: RepoManager, selected: RepoRecord?, tracked: [RepoRecord]) async {
        let key = key(selected: selected, tracked: tracked)
        isLoading = true
        defer { isLoading = false }
        let since = period.since
        let bucket = granularity.bucket
        switch scope {
        case .repository:
            guard let selected else { report = nil; shownKey = key; return }
            do {
                let result = try await manager.stats(for: selected, since: since, bucket: bucket, top: 12)
                guard key == self.key(selected: selected, tracked: tracked) else { return }
                report = result
                error = nil
            } catch {
                report = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .all:
            let result = await manager.statsSummary(for: tracked, since: since, bucket: bucket, top: 12)
            guard key == self.key(selected: selected, tracked: tracked) else { return }
            summary = result
            error = nil
        }
        shownKey = key
    }
}

// MARK: - View

/// Charts of a repository's history, or of every tracked repository: commits
/// and lines changed over time, who commits, where the changes land, and when.
struct RepoInsightsView: View {
    @ObservedObject var model: RepoWorkspaceModel
    @ObservedObject private var insights: RepoInsightsModel
    @State private var refreshToken = 0

    init(model: RepoWorkspaceModel) {
        self.model = model
        self.insights = model.insights
    }

    private var loadKey: String {
        insights.key(selected: model.selected, tracked: model.tracked) + "#\(refreshToken)"
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = insights.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    switch insights.scope {
                    case .repository:
                        if let report = insights.report {
                            RepoReportCharts(report: report, openFile: openFile)
                        } else if !insights.isLoading {
                            ContentUnavailableView("No history", systemImage: "chart.bar", description: Text("Select a repository with commits."))
                        }
                    case .all:
                        if let summary = insights.summary {
                            RepoSummaryCharts(summary: summary) { id in
                                model.selectedId = id
                                insights.scope = .repository
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 1400, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if insights.isLoading, insights.shownKey == nil {
                    ProgressView("Reading history…")
                }
            }
        }
        .task(id: loadKey) {
            await insights.load(manager: model.manager, selected: model.selected, tracked: model.tracked)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $insights.scope) {
                ForEach(RepoInsightsModel.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Statistics for the selected repository, or for every tracked repository together")

            Picker("Period", selection: $insights.period) {
                ForEach(RepoInsightsModel.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker("Show", selection: $insights.granularity) {
                ForEach(RepoInsightsModel.Granularity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()

            if insights.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Text(caption)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                refreshToken += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Read the history again")
            .accessibilityLabel("Refresh Insights")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var caption: String {
        let cli = insights.scope == .all
            ? "fleetmate repos stats --since \(insights.period.rawValue)"
            : "fleetmate repos stats \(model.selected?.key.displayName ?? "<repo>") --since \(insights.period.rawValue)"
        return "Merge commits excluded · \(cli)"
    }

    private func openFile(_ path: String) {
        model.git.focusedPanel = .browse
        model.open(path)
    }
}

// MARK: - Palette

/// Series colours in a fixed order, never cycled and never red: identity
/// follows the repository, and anything past the last slot folds into Other.
enum InsightsPalette {
    static let categorical: [Color] = [.blue, .orange, .teal, .purple, .brown, .mint, .indigo]
    static let other = Color.gray
    static let added = Color.teal
    static let removed = Color.orange
    static let commits = Color.accentColor
}

// MARK: - One repository

private struct RepoReportCharts: View {
    let report: RepoStatsReport
    let openFile: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatTiles(totals: report.totals)
            InsightsCard(title: "Commits per \(report.bucket.rawValue)") {
                CommitsTimelineChart(points: report.timeline, bucket: report.bucket)
            }
            InsightsCard(title: "Lines changed per \(report.bucket.rawValue)") {
                ChurnChart(points: report.timeline, bucket: report.bucket)
            }
            HStack(alignment: .top, spacing: 14) {
                InsightsCard(title: "Authors") {
                    RankedBars(rows: report.contributors.prefix(10).map { .init(label: $0.name, value: $0.commits, detail: "+\($0.added) −\($0.removed)") }, unit: "commits")
                }
                InsightsCard(title: "Top-level folders") {
                    RankedBars(rows: report.areas.prefix(10).map { .init(label: $0.path, value: $0.commits, detail: "+\($0.added) −\($0.removed)") }, unit: "commits")
                }
            }
            InsightsCard(title: "Most-changed files") {
                FileActivityList(files: report.files, openFile: openFile)
            }
            InsightsCard(title: "When commits happen") {
                ActivityHeatmap(cells: report.activity)
            }
        }
    }
}

// MARK: - All repositories

private struct RepoSummaryCharts: View {
    let summary: RepoStatsSummary
    let select: (String) -> Void

    private struct StackPoint: Identifiable {
        let start: Date
        let series: String
        let commits: Int
        var id: String { "\(series)|\(start.timeIntervalSince1970)" }
    }

    /// The busiest repositories by name, the rest as Other.
    private var seriesNames: [String] {
        Array(summary.rows.filter { $0.commits > 0 }.prefix(InsightsPalette.categorical.count).map(\.displayName))
    }

    private var stacked: [StackPoint] {
        let named = Set(seriesNames)
        var points: [StackPoint] = []
        var other = Array(repeating: 0, count: summary.bucketStarts.count)
        for row in summary.rows {
            if named.contains(row.displayName) {
                for (i, count) in row.timeline.enumerated() where count > 0 {
                    points.append(StackPoint(start: summary.bucketStarts[i], series: row.displayName, commits: count))
                }
            } else {
                for (i, count) in row.timeline.enumerated() { other[i] += count }
            }
        }
        for (i, count) in other.enumerated() where count > 0 {
            points.append(StackPoint(start: summary.bucketStarts[i], series: "Other", commits: count))
        }
        return points
    }

    var body: some View {
        let names = seriesNames
        let hasOther = summary.rows.filter { $0.commits > 0 }.count > names.count
        let domain = names + (hasOther ? ["Other"] : [])
        let range = Array(InsightsPalette.categorical.prefix(names.count)) + (hasOther ? [InsightsPalette.other] : [])
        VStack(alignment: .leading, spacing: 14) {
            StatTiles(totals: summary.combined.totals)
            InsightsCard(title: "Commits per \(summary.bucket.rawValue) by repository") {
                Chart(stacked) { point in
                    BarMark(
                        x: .value("Period", point.start, unit: summary.bucket.calendarUnit),
                        y: .value("Commits", point.commits)
                    )
                    .foregroundStyle(by: .value("Repository", point.series))
                }
                .chartForegroundStyleScale(domain: domain, range: range)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 220)
                .accessibilityLabel("Commits per \(summary.bucket.rawValue), stacked by repository")
            }
            InsightsCard(title: "Lines changed per \(summary.bucket.rawValue)") {
                ChurnChart(points: summary.combined.timeline, bucket: summary.bucket)
            }
            InsightsCard(title: "Repositories") {
                RepoSummaryTable(rows: summary.rows, select: select)
            }
            HStack(alignment: .top, spacing: 14) {
                InsightsCard(title: "Authors") {
                    RankedBars(rows: summary.combined.contributors.prefix(10).map { .init(label: $0.name, value: $0.commits, detail: "+\($0.added) −\($0.removed)") }, unit: "commits")
                }
                InsightsCard(title: "Behind upstream") {
                    RankedBars(rows: summary.rows.filter { $0.behind > 0 }.sorted { $0.behind > $1.behind }.prefix(10).map { .init(label: $0.displayName, value: $0.behind, detail: $0.branch ?? "") }, unit: "commits behind")
                }
            }
            InsightsCard(title: "When commits happen") {
                ActivityHeatmap(cells: summary.combined.activity)
            }
        }
    }
}

private struct RepoSummaryTable: View {
    let rows: [RepoStatsSummaryRow]
    let select: (String) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Repository")
                Text("Commits").gridColumnAlignment(.trailing)
                Text("Added").gridColumnAlignment(.trailing)
                Text("Removed").gridColumnAlignment(.trailing)
                Text("Ahead").gridColumnAlignment(.trailing)
                Text("Behind").gridColumnAlignment(.trailing)
                Text("Open changes").gridColumnAlignment(.trailing)
                Text("Last commit")
            }
            .appFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    Button(row.displayName) { select(row.id) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help(row.error ?? "Show \(row.displayName)'s insights")
                    Text(row.commits, format: .number)
                    Text("+\(row.added)")
                    Text("−\(row.removed)")
                    Text(row.ahead, format: .number)
                    Text(row.behind, format: .number)
                    Text(row.openChanges, format: .number)
                    if let error = row.error, row.commits == 0 {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
                    } else {
                        Text(row.lastCommit.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
                .appFont(.callout)
                .monospacedDigit()
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Pieces

private struct InsightsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).appFont(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
    }
}

private struct StatTiles: View {
    let totals: RepoStatsReport.Totals

    var body: some View {
        HStack(spacing: 10) {
            tile("Commits", totals.commits.formatted(), "point.3.connected.trianglepath.dotted")
            tile("Authors", totals.authors.formatted(), "person.2")
            tile("Lines added", "+" + totals.added.formatted(), "plus.forwardslash.minus")
            tile("Lines removed", "−" + totals.removed.formatted(), "minus")
            tile("Files touched", totals.filesTouched.formatted(), "doc.on.doc")
            tile("Last commit", totals.lastCommit.map { $0.formatted(.relative(presentation: .named)) } ?? "—", "clock")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .appFont(.title2, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }
}

extension RepoStatsBucket {
    var calendarUnit: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    func label(_ date: Date) -> String {
        switch self {
        case .day: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: "Week of " + date.formatted(.dateTime.month(.abbreviated).day().year())
        case .month: date.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// The bucket a hovered date falls in.
private func point(at date: Date?, in points: [RepoStatsReport.TimelinePoint]) -> RepoStatsReport.TimelinePoint? {
    guard let date else { return nil }
    return points.last { $0.start <= date }
}

private struct CommitsTimelineChart: View {
    let points: [RepoStatsReport.TimelinePoint]
    let bucket: RepoStatsBucket
    @State private var hovered: Date?

    var body: some View {
        let selected = point(at: hovered, in: points)
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Period", point.start, unit: bucket.calendarUnit),
                    y: .value("Commits", point.commits)
                )
                .foregroundStyle(InsightsPalette.commits.opacity(selected == nil || selected?.start == point.start ? 1 : 0.45))
                .cornerRadius(2)
            }
            if let selected {
                RuleMark(x: .value("Period", selected.start, unit: bucket.calendarUnit))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .zIndex(-1)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HoverLabel(title: bucket.label(selected.start), lines: ["\(selected.commits) commit\(selected.commits == 1 ? "" : "s")"])
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartYAxisLabel("Commits")
        .frame(height: 200)
        .accessibilityLabel("Commits per \(bucket.rawValue)")
    }
}

private struct ChurnChart: View {
    let points: [RepoStatsReport.TimelinePoint]
    let bucket: RepoStatsBucket
    @State private var hovered: Date?

    var body: some View {
        let selected = point(at: hovered, in: points)
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Period", point.start, unit: bucket.calendarUnit),
                    y: .value("Lines", point.added)
                )
                .foregroundStyle(by: .value("Change", "Added"))
                BarMark(
                    x: .value("Period", point.start, unit: bucket.calendarUnit),
                    y: .value("Lines", -point.removed)
                )
                .foregroundStyle(by: .value("Change", "Removed"))
            }
            RuleMark(y: .value("Lines", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
            if let selected {
                RuleMark(x: .value("Period", selected.start, unit: bucket.calendarUnit))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .zIndex(-1)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HoverLabel(title: bucket.label(selected.start), lines: ["+\(selected.added) added", "−\(selected.removed) removed"])
                    }
            }
        }
        .chartForegroundStyleScale(["Added": InsightsPalette.added, "Removed": InsightsPalette.removed])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let lines = value.as(Int.self) { Text(abs(lines).formatted(.number.notation(.compactName))) }
                }
            }
        }
        .chartXSelection(value: $hovered)
        .chartYAxisLabel("Lines")
        .frame(height: 200)
        .accessibilityLabel("Lines added and removed per \(bucket.rawValue)")
    }
}

private struct HoverLabel: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(.caption, weight: .semibold)
            ForEach(lines, id: \.self) { Text($0).appFont(.caption).monospacedDigit() }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}

private struct RankedRow: Identifiable {
    let label: String
    let value: Int
    let detail: String
    var id: String { label }
}

/// Label, bar, count and a secondary detail per row. Labels and numbers
/// stay in text colours; only the bar carries the series colour.
private struct RankedBars: View {
    let rows: [RankedRow]
    let unit: String

    var body: some View {
        if rows.isEmpty {
            Text("Nothing in this period").appFont(.callout).foregroundStyle(.secondary)
        } else {
            let peak = max(rows.map(\.value).max() ?? 1, 1)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label)
                            .appFont(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                            .help(row.label)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(InsightsPalette.commits)
                                .frame(width: max(3, geo.size.width * CGFloat(row.value) / CGFloat(peak)))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(minWidth: 40, maxWidth: .infinity)
                        .frame(height: 12)
                        Text(row.value, format: .number)
                            .appFont(.callout, weight: .medium)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(row.detail)
                            .appFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.label): \(row.value) \(unit), \(row.detail)")
                }
            }
        }
    }
}

private struct FileActivityList: View {
    let files: [RepoStatsReport.PathActivity]
    let openFile: (String) -> Void

    var body: some View {
        if files.isEmpty {
            Text("Nothing in this period").appFont(.callout).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("File")
                    Text("Commits").gridColumnAlignment(.trailing)
                    Text("Added").gridColumnAlignment(.trailing)
                    Text("Removed").gridColumnAlignment(.trailing)
                }
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                ForEach(files) { file in
                    GridRow {
                        Button {
                            openFile(file.path)
                        } label: {
                            Text(file.path).lineLimit(1).truncationMode(.head)
                        }
                        .buttonStyle(.link)
                        .help("Open \(file.path) in Files")
                        .contextMenu {
                            Button("Open in Files") { openFile(file.path) }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path, forType: .string)
                            }
                        }
                        Text(file.commits, format: .number)
                        Text("+\(file.added)")
                        Text("−\(file.removed)")
                    }
                    .appFont(.callout)
                    .monospacedDigit()
                }
            }
        }
    }
}

/// Commits by weekday and hour, darker for more. One hue, light to dark.
private struct ActivityHeatmap: View {
    let cells: [RepoStatsReport.ActivityCell]

    private static let weekdays = Calendar.current.shortWeekdaySymbols

    var body: some View {
        let peak = max(cells.map(\.commits).max() ?? 1, 1)
        Chart(cells) { cell in
            RectangleMark(
                x: .value("Hour", cell.hour),
                y: .value("Day", Self.weekdays[(cell.weekday - 1 + 7) % 7]),
                width: .ratio(0.9),
                height: .ratio(0.85)
            )
            .foregroundStyle(InsightsPalette.commits.opacity(0.2 + 0.8 * Double(cell.commits) / Double(peak)))
            .cornerRadius(2)
            .accessibilityValue("\(cell.commits) commits")
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: Self.weekdays)
        .chartXAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) { Text(String(format: "%02d:00", hour)) }
                }
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Commits by weekday and hour")
    }
}
