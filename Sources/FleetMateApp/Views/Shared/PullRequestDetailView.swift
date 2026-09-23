import SwiftUI
import AppKit
import FleetMateCore

// MARK: - Verbs

/// Everything the viewer can do to a pull request, across both providers.
/// Azure DevOps "complete/abandon" and GitHub "merge/close" are kept as
/// separate cases so the wording and confirmation text stay honest.
enum PullRequestVerb: Identifiable, Hashable {
    case approve
    case requestChanges
    case comment
    case merge(PullRequestMergeMethod)
    case complete
    case close
    case abandon
    case markReady
    case convertToDraft

    var id: String {
        switch self {
        case .merge(let method): return "merge.\(method.rawValue)"
        default: return title
        }
    }

    var title: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .comment: return "Comment"
        case .merge(let method): return method.displayName
        case .complete: return "Complete"
        case .close: return "Close"
        case .abandon: return "Abandon"
        case .markReady: return "Mark ready"
        case .convertToDraft: return "Convert to draft"
        }
    }

    var icon: String {
        switch self {
        case .approve: return "checkmark.circle"
        case .requestChanges: return "arrow.uturn.backward.circle"
        case .comment: return "bubble.left"
        case .merge: return "arrow.triangle.merge"
        case .complete: return "checkmark"
        case .close, .abandon: return "xmark"
        case .markReady: return "eye"
        case .convertToDraft: return "pencil.line"
        }
    }

    var tint: Color {
        switch self {
        case .approve, .complete, .merge: return .green
        case .requestChanges, .close, .abandon: return .orange
        case .comment, .markReady, .convertToDraft: return .accentColor
        }
    }

    /// Verbs that irreversibly change the PR ask first.
    var needsConfirmation: Bool {
        switch self {
        case .merge, .complete, .close, .abandon: return true
        default: return false
        }
    }

    /// Verbs that take text before they run.
    var takesText: Bool {
        switch self {
        case .comment, .requestChanges: return true
        default: return false
        }
    }
}

// MARK: - Lightbox

/// In-app pull-request viewer: description, checks, commits, red/green diffs
/// and the conversation, plus the day-to-day verbs — no browser round trip.
/// Works for both providers; the diff renderer is ported from MunkiStudio's
/// DiffView with dark-mode-aware colors.
struct PullRequestDetailView: View {
    let pullRequest: UnifiedPullRequest
    /// Presented inside the Development tab's centre pane rather than as a
    /// sheet: no fixed frame, no close button, and actions don't dismiss.
    var isInline: Bool = false
    /// Called after the PR leaves the queue (merged, completed, closed or
    /// abandoned) so the list behind the viewer refreshes.
    var onActionCompleted: (() -> Void)?

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var detail: PullRequestDetail?
    @State private var checks: [PullRequestCheck] = []
    @State private var loadError: String?
    @State private var pendingVerb: PullRequestVerb?
    @State private var composingVerb: PullRequestVerb?
    @State private var composedText = ""
    @State private var runningVerb: PullRequestVerb?
    @State private var actionError: String?
    @State private var mergeMethod: PullRequestMergeMethod = .squash
    /// Draft state can flip in-app, so it is tracked apart from the row.
    @State private var isDraft: Bool

    init(pullRequest: UnifiedPullRequest, isInline: Bool = false, onActionCompleted: (() -> Void)? = nil) {
        self.pullRequest = pullRequest
        self.isInline = isInline
        self.onActionCompleted = onActionCompleted
        self._isDraft = State(initialValue: pullRequest.state == .draft)
    }

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
            actionBar
            Divider()
            content
        }
        .frame(
            width: isInline ? nil : sheetSize.width,
            height: isInline ? nil : sheetSize.height
        )
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandIcon(mark: pullRequest.source.brandMark, size: 16)
                .foregroundStyle(pullRequest.source.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pullRequest.title)
                        .appFont(.title3, weight: .semibold)
                        .lineLimit(2)
                    if isDraft { pill("Draft", color: .secondary) }
                    if pullRequest.hasConflicts { pill("Conflicts", color: .orange) }
                }
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
                    Text("·").foregroundStyle(.tertiary)
                    Text(pullRequest.authorName)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
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

            Button {
                if let url = URL(string: pullRequest.webUrl) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "globe")
            }
            .help("Open in browser")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.webUrl, forType: .string)
            } label: {
                Image(systemName: "link")
            }
            .help("Copy link")
            if !isInline {
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
        }
        .padding(14)
    }

    // MARK: Action bar

    private var isActionable: Bool {
        pullRequest.state == .open || pullRequest.state == .draft
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            checksSummary
            Spacer()
            if isActionable {
                verbButton(.approve)
                verbButton(.requestChanges)
                verbButton(.comment)
                verbButton(isDraft ? .markReady : .convertToDraft)
                Divider().frame(height: 16)
                switch pullRequest.source {
                case .gitHub:
                    mergeControl
                    verbButton(.close)
                case .azureDevOps:
                    verbButton(.complete)
                    verbButton(.abandon)
                }
            } else {
                Text(pullRequest.state.displayName)
                    .appFont(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .confirmationDialog(
            pendingVerb.map { "\($0.title) \(pullRequest.reference)?" } ?? "",
            isPresented: Binding(get: { pendingVerb != nil }, set: { if !$0 { pendingVerb = nil } }),
            presenting: pendingVerb
        ) { verb in
            Button(verb.title, role: verb.tint == .orange ? .destructive : nil) {
                perform(verb, text: nil)
            }
            Button("Cancel", role: .cancel) { pendingVerb = nil }
        } message: { verb in
            Text(confirmationMessage(for: verb))
        }
        .popover(
            isPresented: Binding(get: { composingVerb != nil }, set: { if !$0 { composingVerb = nil } }),
            arrowEdge: .top
        ) {
            composer
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

    /// GitHub merges need a method; the picker remembers the last choice for
    /// the session and the button performs it.
    private var mergeControl: some View {
        HStack(spacing: 0) {
            verbButton(.merge(mergeMethod), title: "Merge")
            Menu {
                ForEach(PullRequestMergeMethod.allCases, id: \.self) { method in
                    Button(method.displayName) { mergeMethod = method }
                }
            } label: {
                Image(systemName: "chevron.down").appFont(fixed: 9, weight: .bold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help("Merge method: \(mergeMethod.displayName)")
        }
    }

    private func verbButton(_ verb: PullRequestVerb, title: String? = nil) -> some View {
        Button {
            trigger(verb)
        } label: {
            HStack(spacing: 3) {
                if runningVerb == verb {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: verb.icon).appFont(fixed: 9, weight: .bold)
                }
                Text(title ?? verb.title).appFont(fixed: 11, weight: .medium)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(verb.tint.opacity(0.15))
            .foregroundStyle(verb.tint)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(runningVerb != nil)
        .help(helpText(for: verb))
    }

    private func helpText(for verb: PullRequestVerb) -> String {
        switch verb {
        case .approve: return pullRequest.source == .gitHub ? "Submit an approving review" : "Vote Approved"
        case .requestChanges: return pullRequest.source == .gitHub ? "Submit a request-changes review" : "Vote Waiting for author"
        case .comment: return "Add a comment to the conversation"
        case .merge(let method): return "\(method.displayName) into \(pullRequest.targetBranch)"
        case .complete: return "Complete this pull request, merging it into \(pullRequest.targetBranch)"
        case .close: return "Close without merging"
        case .abandon: return "Abandon this pull request"
        case .markReady: return "Take the pull request out of draft"
        case .convertToDraft: return "Put the pull request back into draft"
        }
    }

    private func trigger(_ verb: PullRequestVerb) {
        if verb.takesText {
            composedText = ""
            composingVerb = verb
        } else if verb.needsConfirmation {
            pendingVerb = verb
        } else {
            perform(verb, text: nil)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(composingVerb?.title ?? "")
                .appFont(.headline)
            TextEditor(text: $composedText)
                .appFont(.body)
                .frame(width: 420, height: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Text(composingVerb == .requestChanges
                     ? "Sent as a review requesting changes."
                     : "Markdown is rendered by the provider.")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { composingVerb = nil }
                    .keyboardShortcut(.cancelAction)
                Button(composingVerb?.title ?? "Send") {
                    guard let verb = composingVerb else { return }
                    let text = composedText
                    composingVerb = nil
                    perform(verb, text: text)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(composedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    private func confirmationMessage(for verb: PullRequestVerb) -> String {
        switch verb {
        case .merge(let method):
            return "\(pullRequest.title)\n\n\(method.displayName): \(pullRequest.sourceBranch) into "
                + "\(pullRequest.targetBranch) in \(pullRequest.repository)."
        case .complete:
            return "\(pullRequest.title)\n\nThis merges \(pullRequest.sourceBranch) into "
                + "\(pullRequest.targetBranch) in \(pullRequest.repository), using the merge "
                + "options already set on the pull request."
        case .close:
            return "\(pullRequest.title)\n\nThe branch stays; the pull request can be reopened on GitHub."
        case .abandon:
            return "\(pullRequest.title)\n\nThe pull request stays in \(pullRequest.repository) "
                + "and can be reactivated in Azure DevOps, but reviewers are notified."
        default:
            return pullRequest.title
        }
    }

    private func perform(_ verb: PullRequestVerb, text: String?) {
        pendingVerb = nil
        runningVerb = verb
        Task {
            defer { runningVerb = nil }
            do {
                try await run(verb, text: text)
                switch verb {
                case .merge, .complete, .close, .abandon:
                    onActionCompleted?()
                    if !isInline { dismiss() }
                case .markReady:
                    isDraft = false
                    refreshQueues()
                case .convertToDraft:
                    isDraft = true
                    refreshQueues()
                case .approve, .requestChanges, .comment:
                    await load()
                    refreshQueues()
                }
            } catch {
                actionError = "Could not \(verb.title.lowercased()) \(pullRequest.reference): "
                    + error.localizedDescription
                // The most common failure is stale state (the PR was already
                // merged or abandoned elsewhere). Reconcile so the row cannot
                // invite the same action again.
                refreshQueues()
            }
        }
    }

    private func refreshQueues() {
        appState.pullRequestQueue.load(appState: appState, force: true)
        appState.development.loadPullRequests(appState: appState, force: true)
    }

    private func run(_ verb: PullRequestVerb, text: String?) async throws {
        switch pullRequest.source {
        case .gitHub:
            let service = GitHubPullRequestService(config: appState.config.tasks?.providers.github ?? GitHubProviderConfig())
            let owner = pullRequest.container, repo = pullRequest.repository, number = pullRequest.number
            switch verb {
            case .approve:
                try await service.approve(owner: owner, repo: repo, number: number)
            case .requestChanges:
                try await service.requestChanges(owner: owner, repo: repo, number: number, body: text ?? "")
            case .comment:
                try await service.comment(owner: owner, repo: repo, number: number, body: text ?? "")
            case .merge(let method):
                try await service.merge(owner: owner, repo: repo, number: number, method: method)
            case .close:
                try await service.close(owner: owner, repo: repo, number: number)
            case .markReady:
                try await service.setReady(owner: owner, repo: repo, number: number, ready: true)
            case .convertToDraft:
                try await service.setReady(owner: owner, repo: repo, number: number, ready: false)
            case .complete, .abandon:
                throw GitHubGraphQLError.graphQLError("\(verb.title) is an Azure DevOps action")
            }
        case .azureDevOps:
            let service = appState.devOpsService
            let repo = pullRequest.repository, number = pullRequest.number, project = pullRequest.container
            switch verb {
            case .approve:
                try await service.approve(repository: repo, pullRequestId: number, project: project)
            case .requestChanges:
                try await service.requestChanges(repository: repo, pullRequestId: number, project: project)
                if let text, !text.isEmpty {
                    try await service.comment(repository: repo, pullRequestId: number, project: project, text: text)
                }
            case .comment:
                try await service.comment(repository: repo, pullRequestId: number, project: project, text: text ?? "")
            case .complete:
                _ = try await service.completePullRequest(repository: repo, pullRequestId: number, project: project)
            case .abandon:
                _ = try await service.abandonPullRequest(repository: repo, pullRequestId: number, project: project)
            case .markReady:
                _ = try await service.setReady(repository: repo, pullRequestId: number, project: project, ready: true)
            case .convertToDraft:
                _ = try await service.setReady(repository: repo, pullRequestId: number, project: project, ready: false)
            case .merge, .close:
                throw AzDevOpsError.httpError(code: 400, message: "\(verb.title) is a GitHub action")
            }
        }
    }

    // MARK: Checks

    /// Compact roll-up beside the verbs: one dot per state with counts.
    @ViewBuilder
    private var checksSummary: some View {
        if checks.isEmpty {
            Text("No checks")
                .appFont(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            let failing = checks.filter { $0.state == .failure }.count
            let pending = checks.filter { $0.state == .pending }.count
            let passing = checks.filter { $0.state == .success }.count
            HStack(spacing: 8) {
                if failing > 0 { checkCount(failing, label: "failing", state: .failure) }
                if pending > 0 { checkCount(pending, label: "pending", state: .pending) }
                if passing > 0 { checkCount(passing, label: "passing", state: .success) }
            }
            .help(checks.map { "\($0.name): \($0.state.rawValue)" }.joined(separator: "\n"))
        }
    }

    private func checkCount(_ count: Int, label: String, state: PullRequestCheckState) -> some View {
        HStack(spacing: 3) {
            Image(systemName: state.symbolName).appFont(fixed: 10).foregroundStyle(state.tint)
            Text("\(count) \(label)").appFont(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var showsActions: Bool { isActionable }

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

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .appFont(fixed: 9, weight: .medium)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
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
            // One vertical read: Overview, Checks, then Commits, then Changes.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overviewSection(detail)
                    if !checks.isEmpty { checksSection }
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

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Checks", count: checks.count)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                        HStack(spacing: 8) {
                            Image(systemName: check.state.symbolName)
                                .appFont(fixed: 12)
                                .foregroundStyle(check.state.tint)
                                .frame(width: 16)
                            Text(check.name).appFont(.callout)
                            if check.isRequired {
                                Text("Required")
                                    .appFont(fixed: 9, weight: .medium)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(check.state.rawValue.capitalized)
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                            if let link = check.detailsUrl, let url = URL(string: link) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.right.square").appFont(fixed: 11)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Open the check details")
                            }
                        }
                        .padding(.vertical, 5)
                        if index < checks.count - 1 { Divider() }
                    }
                }
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
                async let fetched = appState.devOpsService.getPullRequestDetail(
                    repository: pullRequest.repository,
                    pullRequestId: pullRequest.number,
                    project: pullRequest.container
                )
                async let fetchedChecks = appState.devOpsService.getChecks(
                    repository: pullRequest.repository,
                    pullRequestId: pullRequest.number,
                    project: pullRequest.container
                )
                detail = try await fetched
                checks = (try? await fetchedChecks) ?? []
            case .gitHub:
                let config = appState.config.tasks?.providers.github ?? GitHubProviderConfig()
                let service = GitHubPullRequestService(config: config)
                async let fetched = service.getPullRequestDetail(
                    owner: pullRequest.container,
                    repo: pullRequest.repository,
                    number: pullRequest.number
                )
                async let fetchedChecks = service.getChecks(
                    owner: pullRequest.container,
                    repo: pullRequest.repository,
                    number: pullRequest.number
                )
                detail = try await fetched
                checks = (try? await fetchedChecks) ?? []
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension PullRequestCheckState {
    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .pending: return "clock"
        case .neutral: return "minus.circle"
        case .skipped: return "arrow.right.circle"
        }
    }

    /// Orange, not red, for failures — the app has no red badges.
    var tint: Color {
        switch self {
        case .success: return .green
        case .failure: return .orange
        case .pending: return .yellow
        case .neutral, .skipped: return .secondary
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

    /// Character ranges that actually changed within paired old/new lines —
    /// the darker "word diff" emphasis GitHub layers on the row tint.
    private let emphasis: [UUID: Range<Int>]

    /// Visible width of the hunk, so short lines' tints still run edge to
    /// edge — the scroll content is only as wide as the longest line.
    @State private var visibleWidth: CGFloat = 0

    init(hunk: DiffHunk) {
        self.hunk = hunk
        self.emphasis = Self.intralineEmphasis(hunk.lines)
    }

    /// Pair each run of deletions with the run of additions that follows it,
    /// index-wise, and strip the common prefix and suffix of each pair — the
    /// differing middle is what gets emphasized. Pairs that share nothing get
    /// no emphasis: the whole-row tint already says the line was replaced.
    static func intralineEmphasis(_ lines: [DiffLine]) -> [UUID: Range<Int>] {
        var result: [UUID: Range<Int>] = [:]
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .deletion else { i += 1; continue }
            var deletions: [Int] = []
            while i < lines.count, lines[i].kind == .deletion { deletions.append(i); i += 1 }
            var additions: [Int] = []
            while i < lines.count, lines[i].kind == .addition { additions.append(i); i += 1 }
            for (d, a) in zip(deletions, additions) {
                let old = Array(lines[d].content)
                let new = Array(lines[a].content)
                var prefix = 0
                while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < old.count - prefix, suffix < new.count - prefix,
                      old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
                guard prefix + suffix > 0 else { continue }
                if prefix < old.count - suffix { result[lines[d].id] = prefix..<(old.count - suffix) }
                if prefix < new.count - suffix { result[lines[a].id] = prefix..<(new.count - suffix) }
            }
        }
        return result
    }

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
                        DiffLineRow(line: line, emphasis: emphasis[line.id])
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
    /// Character range within `content` that actually changed, for the darker
    /// word-diff tint layered on the row background.
    var emphasis: Range<Int>? = nil

    var body: some View {
        HStack(spacing: 0) {
            numberCell(line.oldLine)
            numberCell(line.newLine)
            Rectangle().fill(gutterColor).frame(width: 3)
            Text(attributedContent)
                .appFont(fixed: 12, design: .monospaced)
                .foregroundStyle(textColor)
                .padding(.horizontal, 6)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                .background(rowBackground)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedContent: AttributedString {
        var text = AttributedString(prefix + line.content)
        if let emphasis, emphasis.upperBound <= line.content.count {
            let start = text.characters.index(text.startIndex, offsetBy: prefix.count + emphasis.lowerBound)
            let end = text.characters.index(start, offsetBy: emphasis.count)
            text[start..<end].backgroundColor = emphasisColor
        }
        return text
    }

    private var emphasisColor: Color {
        line.kind == .addition ? Color.green.opacity(0.32) : Color.red.opacity(0.32)
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

extension String {
    /// Quick tag strip for one-line system messages (DevOps sends HTML).
    var strippedOfHtml: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
