import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Lightbox

/// In-app pull-request viewer: description, commits, red/green diffs and the
/// conversation — no browser round trip. Works for both providers; the diff
/// renderer is ported from MunkiStudio's DiffView with dark-mode-aware colors.
struct PullRequestDetailView: View {
    let pullRequest: UnifiedPullRequest
    /// Called after Complete/Abandon so the queue behind the sheet refreshes.
    var onActionCompleted: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var detail: PullRequestDetail?
    @State private var loadError: String?
    @State private var pendingAction: PullRequestRow.PullRequestAction?
    @State private var runningAction: PullRequestRow.PullRequestAction?
    @State private var actionError: String?

    /// ~80% of the hosting window, measured at presentation time — sheets
    /// can't observe their parent window, so the size is captured up front.
    private let sheetSize: CGSize = {
        let host = NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
            .max(by: { $0.frame.width < $1.frame.width })
        let size = host?.frame.size ?? CGSize(width: 1400, height: 900)
        return CGSize(width: max(860, size.width * 0.8), height: max(560, size.height * 0.8))
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandIcon(mark: pullRequest.source.brandMark, size: 16)
                .foregroundStyle(pullRequest.source.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(pullRequest.title)
                    .appFont(.title3, weight: .semibold)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(pullRequest.container)/\(pullRequest.repository)")
                        .appFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.triangle.branch")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(pullRequest.sourceBranch) → \(pullRequest.targetBranch)")
                        .appFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()

            // Same at-a-glance cluster the queue row shows.
            reviewerBubbles
            HStack(spacing: 3) {
                Image(systemName: "bubble.left").appFont(fixed: 10)
                Text("\(pullRequest.commentCount)").appFont(.caption).monospacedDigit()
            }
            .foregroundStyle(pullRequest.commentCount > 0 ? .secondary : .tertiary)
            Text(timestampLabel)
                .appFont(.caption)
                .foregroundStyle(.secondary)

            if showsActions {
                actionButton(.complete)
                actionButton(.abandon)
            }

            Button {
                if let url = URL(string: pullRequest.webUrl) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "globe")
            }
            .help("Open in browser")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .appFont(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
        .confirmationDialog(
            pendingAction.map { "\($0.title) !\(pullRequest.number)?" } ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            presenting: pendingAction
        ) { action in
            Button(action.title, role: action == .abandon ? .destructive : nil) {
                perform(action)
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
        .alert(
            "Action failed",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var showsActions: Bool {
        guard pullRequest.source == .azureDevOps else { return false }
        return pullRequest.state == .open || pullRequest.state == .draft
    }

    @ViewBuilder
    private var reviewerBubbles: some View {
        let shown = Array(pullRequest.reviewers.prefix(4))
        let overflow = pullRequest.reviewers.count - shown.count
        if !shown.isEmpty {
            HStack(spacing: -4) {
                ForEach(shown) { reviewer in
                    Text(reviewer.initials)
                        .appFont(fixed: 8, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(reviewer.vote.tint))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .help("\(reviewer.displayName) — \(reviewer.vote.label)")
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .appFont(fixed: 8, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.secondary.opacity(0.2)))
                }
            }
        }
    }

    private var timestampLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let updated = pullRequest.updatedAt, updated != pullRequest.createdAt {
            return "Updated \(formatter.localizedString(for: updated, relativeTo: Date()))"
        }
        if let created = pullRequest.createdAt {
            return "Created \(formatter.localizedString(for: created, relativeTo: Date()))"
        }
        return ""
    }

    private func actionButton(_ action: PullRequestRow.PullRequestAction) -> some View {
        Button {
            pendingAction = action
        } label: {
            HStack(spacing: 3) {
                if runningAction == action {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: action.icon).appFont(fixed: 9, weight: .bold)
                }
                Text(action.title).appFont(fixed: 11, weight: .medium)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(action.tint.opacity(0.15))
            .foregroundStyle(action.tint)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(runningAction != nil)
    }

    private func perform(_ action: PullRequestRow.PullRequestAction) {
        pendingAction = nil
        runningAction = action
        Task {
            defer { runningAction = nil }
            do {
                switch action {
                case .complete:
                    try await appState.devOpsService.completePullRequest(
                        repository: pullRequest.repository,
                        pullRequestId: pullRequest.number,
                        project: pullRequest.container
                    )
                case .abandon:
                    try await appState.devOpsService.abandonPullRequest(
                        repository: pullRequest.repository,
                        pullRequestId: pullRequest.number,
                        project: pullRequest.container
                    )
                }
                onActionCompleted?()
                dismiss()
            } catch {
                actionError = "Could not \(action.title.lowercased()) !\(pullRequest.number): "
                    + error.localizedDescription
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't load pull request",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            // One vertical read: Overview, then Commits, then Changes.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overviewSection(detail)
                    commitsSection(detail)
                    changesSection(detail)
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading pull request…")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).appFont(.headline)
            if let count {
                Text("\(count)")
                    .appFont(.caption2).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func overviewSection(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Overview")
            if let body = detail.body, !body.isEmpty {
                GroupBox {
                    MarkdownTextView(content: body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            } else {
                Text("No description.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            }

            let conversation = detail.comments.filter { !$0.isSystem }
            let system = detail.comments.filter(\.isSystem)

            if !conversation.isEmpty {
                sectionHeader("Comments", count: conversation.count)
                ForEach(conversation) { comment in
                    commentCard(comment)
                }
            }
            if !system.isEmpty {
                DisclosureGroup("\(system.count) status updates") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(system) { comment in
                            Text(comment.body.strippedOfHtml)
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .appFont(.caption)
            }
        }
    }

    private func commentCard(_ comment: PullRequestComment) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(comment.authorName)
                        .appFont(.callout, weight: .semibold)
                    Spacer()
                    if let date = comment.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                MarkdownTextView(content: comment.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
        }
    }

    private func commitsSection(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Commits", count: detail.commits.count)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(detail.commits.enumerated()), id: \.element.id) { index, commit in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(commit.shortSha)
                                .appFont(.caption, design: .monospaced)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject)
                                    .appFont(.callout, weight: .medium)
                                HStack(spacing: 6) {
                                    if let author = commit.authorName {
                                        Text(author).appFont(.caption).foregroundStyle(.secondary)
                                    }
                                    if let date = commit.date {
                                        Text(date.formatted(date: .abbreviated, time: .shortened))
                                            .appFont(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        if index < detail.commits.count - 1 { Divider() }
                    }
                    if detail.commits.isEmpty {
                        Text("No commits found.")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func changesSection(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader("Changes", count: detail.files.count)
                if detail.truncated {
                    Text("Large PR — showing a capped set of files")
                        .appFont(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if detail.files.isEmpty {
                Text("The diff couldn't be produced for this pull request.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detail.files) { file in
                    DiffFileCard(file: file)
                }
            }
        }
    }

    // MARK: Load

    private func load() async {
        do {
            switch pullRequest.source {
            case .azureDevOps:
                detail = try await appState.devOpsService.getPullRequestDetail(
                    repository: pullRequest.repository,
                    pullRequestId: pullRequest.number,
                    project: pullRequest.container
                )
            case .gitHub:
                let config = appState.config.tasks?.providers.github ?? GitHubProviderConfig()
                detail = try await GitHubPullRequestService(config: config).getPullRequestDetail(
                    owner: pullRequest.container,
                    repo: pullRequest.repository,
                    number: pullRequest.number
                )
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Diff rendering (ported from MunkiStudio's DiffView)

struct DiffFileCard: View {
    let file: DiffFile
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                collapsed.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .appFont(.caption2)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .foregroundStyle(.secondary)
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(file.displayPath)
                        .appFont(.callout, weight: .semibold, design: .monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.newPath == "/dev/null" {
                        Text("deleted")
                            .appFont(.caption2, weight: .medium)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    if file.insertions > 0 {
                        Text("+\(file.insertions)").appFont(.caption, weight: .semibold).foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)").appFont(.caption, weight: .semibold).foregroundStyle(.red)
                    }
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                if file.hunks.isEmpty {
                    Text("Binary or oversized file — no text diff.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                } else {
                    ForEach(file.hunks) { hunk in
                        DiffHunkCard(hunk: hunk)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

struct DiffHunkCard: View {
    let hunk: DiffHunk

    /// Visible width of the hunk, so short lines' tints still run edge to
    /// edge — the scroll content is only as wide as the longest line.
    @State private var visibleWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .appFont(.caption2, design: .monospaced)
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))

            // Wide code scrolls inside the hunk, not the page.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        DiffLineRow(line: line)
                    }
                }
                .frame(minWidth: visibleWidth, alignment: .leading)
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { visibleWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in visibleWidth = width }
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.top, 6)
    }
}

/// One diff line: old/new number cells, a colored gutter strip, then the
/// monospaced content on a tinted background. Semantic red/green so both
/// appearances read correctly.
struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            numberCell(line.oldLine)
            numberCell(line.newLine)
            Rectangle().fill(gutterColor).frame(width: 3)
            Text(prefix + line.content)
                .appFont(fixed: 12, design: .monospaced)
                .foregroundStyle(textColor)
                .padding(.horizontal, 6)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                .background(rowBackground)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func numberCell(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .appFont(fixed: 11, design: .monospaced)
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .background(Color.secondary.opacity(0.05))
    }

    private var prefix: String {
        switch line.kind {
        case .addition: return "+ "
        case .deletion: return "- "
        case .context: return "  "
        case .noNewline: return "\\ "
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.14)
        case .deletion: return Color.red.opacity(0.14)
        case .context, .noNewline: return Color.clear
        }
    }

    private var gutterColor: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.65)
        case .deletion: return Color.red.opacity(0.65)
        case .context, .noNewline: return Color.clear
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .noNewline: return .secondary
        default: return .primary
        }
    }
}

private extension String {
    /// Quick tag strip for one-line system messages (DevOps sends HTML).
    var strippedOfHtml: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
