import SwiftUI
import Charts
import FleetMateCore

// MARK: - Development

/// The Development tab's Graphs strip, one set per segment: each charts the
/// list below it from what that segment has already loaded — no requests of
/// its own, so the graphs cost nothing against the GitHub budget. A click on
/// a bar, wedge or figure filters the list in place. Repos carries the
/// repository statistics that used to be its Insights panel.
struct DevelopmentWidgetsSection: View {
    @ObservedObject var model: DevelopmentModel
    @ObservedObject var knowledge: KnowledgeStore

    var body: some View {
        switch model.segment {
        case .repos: RepoInsightsWidgets(model: model.repos)
        case .pullRequests: PullsWidgets(model: model)
        case .commits: CommitsWidgets(model: model)
        case .pipelines: PipelinesWidgets(model: model)
        case .skills: SkillsWidgets(knowledge: knowledge, model: model)
        }
    }
}

/// Repository identity colours in a fixed order, never cycled and never red;
/// anything past the last slot is grey.
private enum DevelopmentPalette {
    static let categorical: [Color] = [.blue, .purple, .orange, .teal, .green, .indigo, .brown, .mint]

    static func bars(_ counts: [DevelopmentStats.Count], limit: Int = 8, color: Color? = nil) -> [ChartBar] {
        counts.prefix(limit).enumerated().map { i, c in
            ChartBar(label: c.label, value: c.value, color: color ?? categorical[min(i, categorical.count - 1)])
        }
    }

    static func ageColor(_ bucket: String) -> Color {
        ["Today": .green, "1–7 days": .blue, "8–30 days": .orange, "Over 30 days": .purple][bucket] ?? .gray
    }

    static func review(_ status: DevelopmentStats.ReviewStatus) -> Color {
        switch status {
        case .draft: .gray
        case .conflicts: .orange
        case .changesRequested: .yellow
        case .approved: .green
        case .awaitingReview: .blue
        }
    }

    static func outcome(_ outcome: DevelopmentStats.Outcome) -> Color {
        switch outcome {
        case .succeeded: .green
        case .failed: .orange
        case .partial: .yellow
        case .cancelled: .gray
        case .running: .teal
        }
    }
}

// MARK: - Pulls

private struct PullsWidgets: View {
    @ObservedObject var model: DevelopmentModel

    /// What the list shows before a repository is picked: the source chip
    /// applies, so the graphs and the list agree.
    private var scoped: [UnifiedPullRequest] {
        let rows = model.queue.pullRequests
        return model.selectedSource.map { s in rows.filter { $0.source == s } } ?? rows
    }

    var body: some View {
        let loading = model.isLoadingPullRequests && model.queue.isEmpty
        let rows = scoped
        WidgetsSection(tab: .development) {
            WidgetKPIColumn(kpis: [
                KPI(title: "Review Requested",
                    value: model.queue.failed() ? "--" : "\(model.queue.section(.assignedToMe).count)",
                    icon: "person.crop.circle.badge.checkmark", color: .purple, loading: loading, tab: .development),
                KPI(title: "Created by Me",
                    value: model.queue.failed() ? "--" : "\(model.queue.section(.createdByMe).count)",
                    icon: "person.crop.circle", color: .blue, loading: loading, tab: .development),
            ]) { _ in
                model.selectedRepo = nil
                model.onlyMine = true
            }

            WidgetKPIColumn(kpis: PullRequestSource.allCases.map { source in
                KPI(title: "\(source.shortName) Pull Requests",
                    value: model.queue.failed(source) ? "--" : "\(model.count(for: source))",
                    icon: source.symbolName, color: source == .gitHub ? .indigo : .blue,
                    loading: loading, tab: .development)
            }) { kpi in
                if let source = PullRequestSource.allCases.first(where: { kpi.title.hasPrefix($0.shortName) }) {
                    model.toggleSource(source)
                }
            }

            WidgetCard(title: "By Repository", isLoading: model.isLoadingPullRequests) {
                let bars = DevelopmentPalette.bars(DevelopmentStats.ranked(rows) { $0.repository })
                if bars.isEmpty {
                    empty(loading, "No open pull requests")
                } else {
                    HorizontalBarList(bars: bars) { model.toggleRepo($0) }
                }
            }

            WidgetCard(title: "By Age", isLoading: model.isLoadingPullRequests) {
                if rows.isEmpty {
                    empty(loading, "No open pull requests")
                } else {
                    HorizontalBarList(bars: DevelopmentStats.pullRequestAges(rows).map {
                        ChartBar(label: $0.label, value: $0.value, color: DevelopmentPalette.ageColor($0.label))
                    })
                }
            }

            WidgetCard(title: "Review Status", isLoading: model.isLoadingPullRequests) {
                let statuses = DevelopmentStats.reviewStatuses(rows)
                if statuses.isEmpty {
                    empty(loading, "No open pull requests")
                } else {
                    DonutWidget(slices: statuses.map {
                        ChartSlice(label: $0.status.rawValue, value: $0.count, color: DevelopmentPalette.review($0.status))
                    }, size: 110, adaptsToWidth: true)
                }
            }
        }
    }
}

// MARK: - Commits

private struct CommitsWidgets: View {
    @ObservedObject var model: DevelopmentModel

    private var scoped: [RepositoryCommits] {
        let rows = model.repositoryCommits
        return model.selectedSource.map { s in rows.filter { $0.source == s } } ?? rows
    }

    private var windowDays: Int { Int(DevelopmentModel.commitsWindow / 86_400) }

    var body: some View {
        let repos = scoped
        let commits = repos.flatMap(\.commits)
        let loading = model.isLoadingCommits && model.repositoryCommits.isEmpty
        let authors = DevelopmentStats.ranked(commits) { $0.authorName }
        WidgetsSection(tab: .development) {
            WidgetKPIColumn(kpis: [
                KPI(title: "Commits, \(windowDays) Days", value: "\(commits.count)", icon: "point.3.connected.trianglepath.dotted",
                    color: .blue, loading: loading, tab: .development),
                KPI(title: "Repositories", value: "\(repos.filter { !$0.commits.isEmpty }.count)", icon: "folder",
                    color: .purple, loading: loading, tab: .development),
                KPI(title: "Authors", value: "\(authors.count)", icon: "person.2",
                    color: .teal, loading: loading, tab: .development),
            ]) { kpi in
                if kpi.title == "Repositories" { model.selectedCommitRepo = nil }
            }

            WidgetCard(title: "Commits per Day", isLoading: model.isLoadingCommits) {
                if commits.isEmpty {
                    empty(loading, "No commits in the last \(windowDays) days")
                } else {
                    CommitsPerDayChart(days: DevelopmentStats.commitsPerDay(commits, days: windowDays))
                }
            }
            .widgetSpan(2)

            WidgetCard(title: "By Repository", isLoading: model.isLoadingCommits) {
                let bars = DevelopmentPalette.bars(repos.map { DevelopmentStats.Count(label: $0.displayName, value: $0.commits.count) }
                    .filter { $0.value > 0 }
                    .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value })
                if bars.isEmpty {
                    empty(loading, "No commits")
                } else {
                    HorizontalBarList(bars: bars) { label in
                        model.selectedCommitRepo = model.selectedCommitRepo == label ? nil : label
                    }
                }
            }

            WidgetCard(title: "By Author", isLoading: model.isLoadingCommits) {
                if authors.isEmpty {
                    empty(loading, "No commits")
                } else {
                    HorizontalBarList(bars: DevelopmentPalette.bars(authors, color: .blue)) { model.searchText = $0 }
                }
            }
        }
    }
}

/// One series, so no legend: the card title names it. Hover shows the day.
private struct CommitsPerDayChart: View {
    let days: [DevelopmentStats.DayCount]
    @State private var hovered: Date?

    var body: some View {
        let selected = hovered.flatMap { h in days.last { $0.day <= h } }
        Chart {
            ForEach(days, id: \.day) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Commits", day.value))
                    .foregroundStyle(Color.accentColor.opacity(selected == nil || selected?.day == day.day ? 1 : 0.45))
                    .cornerRadius(2)
            }
            if let selected {
                RuleMark(x: .value("Day", selected.day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .zIndex(-1)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartHoverLabel(title: selected.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                        detail: "\(selected.value) commit\(selected.value == 1 ? "" : "s")")
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Commits per day")
    }
}

// MARK: - Pipelines

private struct PipelinesWidgets: View {
    @ObservedObject var model: DevelopmentModel

    private var scoped: [PipelineRun] {
        let rows = model.pipelineRuns
        return model.selectedSource.map { s in rows.filter { $0.source == s } } ?? rows
    }

    private var windowDays: Int { Int(DevelopmentModel.pipelinesWindow / 86_400) }

    var body: some View {
        let runs = scoped
        let loading = model.isLoadingPipelines && model.pipelineRuns.isEmpty
        let rate = DevelopmentStats.successRate(runs)
        WidgetsSection(tab: .development) {
            WidgetKPIColumn(kpis: [
                KPI(title: "Failing Pipelines", value: "\(model.pipelineCount(for: .failed))", icon: "xmark.octagon",
                    color: .orange, loading: loading, tab: .development),
                KPI(title: "Running", value: "\(model.pipelineCount(for: .running))", icon: "play.circle",
                    color: .teal, loading: loading, tab: .development),
                KPI(title: "Success Rate, \(windowDays) Days",
                    value: rate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "--",
                    icon: "checkmark.seal", color: .green, loading: loading, tab: .development),
            ]) { kpi in
                if kpi.title.hasPrefix("Failing") { model.togglePipelineStatus(.failed) }
                else if kpi.title == "Running" { model.togglePipelineStatus(.running) }
                else { model.pipelineStatusFilter = nil }
            }

            WidgetCard(title: "Outcomes", isLoading: model.isLoadingPipelines) {
                let outcomes = DevelopmentStats.outcomes(runs)
                if outcomes.isEmpty {
                    empty(loading, "No runs in the last \(windowDays) days")
                } else {
                    DonutWidget(slices: outcomes.map {
                        ChartSlice(label: $0.outcome.rawValue, value: $0.count, color: DevelopmentPalette.outcome($0.outcome))
                    }, size: 110, adaptsToWidth: true) { label in
                        if let outcome = DevelopmentStats.Outcome(rawValue: label) {
                            model.togglePipelineStatus(outcome.filterStatus)
                        }
                    }
                }
            }

            WidgetCard(title: "Runs per Day", isLoading: model.isLoadingPipelines) {
                let days = DevelopmentStats.runsPerDay(runs, days: windowDays)
                if days.isEmpty {
                    empty(loading, "No runs in the last \(windowDays) days")
                } else {
                    RunsPerDayChart(days: days)
                }
            }
            .widgetSpan(2)

            WidgetCard(title: "By Repository", isLoading: model.isLoadingPipelines) {
                let bars = DevelopmentPalette.bars(DevelopmentStats.ranked(runs) { DevelopmentModel.pipelineRepoKey($0) })
                if bars.isEmpty {
                    empty(loading, "No runs in the last \(windowDays) days")
                } else {
                    HorizontalBarList(bars: bars) { label in
                        model.selectedPipelineRepo = model.selectedPipelineRepo == label ? nil : label
                    }
                }
            }

            WidgetCard(title: "Slowest Pipelines, Median Minutes", isLoading: model.isLoadingPipelines) {
                let medians = DevelopmentStats.medianDurations(runs).prefix(8)
                if medians.isEmpty {
                    empty(loading, "No finished runs")
                } else {
                    HorizontalBarList(bars: medians.map {
                        ChartBar(label: $0.pipeline, value: max(1, Int(($0.seconds / 60).rounded())), color: .indigo)
                    }) { model.searchText = $0 }
                }
            }
        }
    }
}

/// Stacked by outcome, in the outcome order the donut uses, with a legend.
private struct RunsPerDayChart: View {
    let days: [DevelopmentStats.DayOutcome]

    var body: some View {
        let present = DevelopmentStats.Outcome.allCases.filter { o in days.contains { $0.outcome == o } }
        Chart(days, id: \.self.key) { cell in
            BarMark(x: .value("Day", cell.day, unit: .day), y: .value("Runs", cell.value))
                .foregroundStyle(by: .value("Outcome", cell.outcome.rawValue))
        }
        .chartForegroundStyleScale(domain: present.map(\.rawValue), range: present.map(DevelopmentPalette.outcome))
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .frame(height: 170)
        .accessibilityLabel("Pipeline runs per day by outcome")
    }
}

private extension DevelopmentStats.DayOutcome {
    var key: String { "\(day.timeIntervalSince1970)|\(outcome.rawValue)" }
}

// MARK: - Skills

private struct SkillsWidgets: View {
    @ObservedObject var knowledge: KnowledgeStore
    @ObservedObject var model: DevelopmentModel

    var body: some View {
        let entries = knowledge.skills.entries
        let loading = knowledge.isSyncing && entries.isEmpty
        WidgetsSection(tab: .development) {
            WidgetKPIColumn(kpis: SkillCatalog.Entry.Kind.allCases.map { kind in
                KPI(title: kind.rawValue, value: "\(entries.filter { $0.kind == kind }.count)",
                    icon: Self.icon(kind), color: Self.color(kind), loading: loading, tab: .development)
            }) { _ in }

            WidgetCard(title: "By Origin", isLoading: knowledge.isSyncing) {
                let counts = originBars(entries)
                if counts.isEmpty {
                    empty(loading, "No skills or hooks")
                } else {
                    HorizontalBarList(bars: counts)
                }
            }

            WidgetCard(title: "Most Bundled Files", isLoading: knowledge.isSyncing) {
                let bars = fileBars(entries)
                if bars.isEmpty {
                    empty(loading, "No bundled files")
                } else {
                    HorizontalBarList(bars: bars) { name in
                        model.selectedSkill = entries.first { $0.name == name }
                    }
                }
            }

            WidgetCard(title: "Longest, in Lines", isLoading: knowledge.isSyncing) {
                let bars = lengthBars(entries)
                if bars.isEmpty {
                    empty(loading, "No skills or hooks")
                } else {
                    HorizontalBarList(bars: bars) { name in
                        model.selectedSkill = entries.first { $0.name == name }
                    }
                }
            }
        }
    }

    private func originBars(_ entries: [SkillCatalog.Entry]) -> [ChartBar] {
        var bars: [ChartBar] = []
        for origin in SkillCatalog.Entry.Origin.allCases {
            for kind in SkillCatalog.Entry.Kind.allCases {
                let n = entries.filter { $0.origin == origin && $0.kind == kind }.count
                if n > 0 { bars.append(ChartBar(label: "\(kind.rawValue) · \(origin.rawValue)", value: n, color: Self.color(kind))) }
            }
        }
        return bars
    }

    private func fileBars(_ entries: [SkillCatalog.Entry]) -> [ChartBar] {
        let rows: [SkillCatalog.Entry] = entries.filter { !$0.files.isEmpty }
            .sorted { $0.files.count == $1.files.count ? $0.name < $1.name : $0.files.count > $1.files.count }
        return rows.prefix(8).map { ChartBar(label: $0.name, value: $0.files.count, color: .teal) }
    }

    private func lengthBars(_ entries: [SkillCatalog.Entry]) -> [ChartBar] {
        let counted: [(entry: SkillCatalog.Entry, lines: Int)] = entries.map { entry in
            (entry, entry.body.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
        let sorted = counted.sorted { $0.lines == $1.lines ? $0.entry.name < $1.entry.name : $0.lines > $1.lines }
        return sorted.prefix(8).map { ChartBar(label: $0.entry.name, value: $0.lines, color: Self.color($0.entry.kind)) }
    }

    private static func icon(_ kind: SkillCatalog.Entry.Kind) -> String {
        switch kind {
        case .skill: "wand.and.stars"
        case .hook: "link"
        case .standard: "doc.text"
        }
    }

    private static func color(_ kind: SkillCatalog.Entry.Kind) -> Color {
        switch kind {
        case .skill: .blue
        case .hook: .purple
        case .standard: .teal
        }
    }
}

// MARK: - Pieces

@ViewBuilder
private func empty(_ loading: Bool, _ message: String) -> some View {
    if loading { SkeletonChartCard() } else { WidgetEmptyState(message) }
}

private struct ChartHoverLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(.caption, weight: .semibold)
            Text(detail).appFont(.caption).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}
