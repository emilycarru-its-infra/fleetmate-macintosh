import SwiftUI
import FleetMateCore

/// Full GitHub-like issue sidebar. Displays and allows editing of all GitHub issue fields,
/// comments, and dangerous actions (lock, pin, delete, transfer, duplicate).
struct GitHubIssueSidebarView: View {
    let task: UnifiedTask
    let config: GitHubProviderConfig?
    let onClose: () -> Void

    // Loaded detail
    @State private var detail: GitHubIssueDetail? = nil
    @State private var comments: [GitHubComment] = []
    @State private var isLoadingDetail = false
    @State private var loadError: String? = nil

    // Editing state
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var isEditingBody = false
    @State private var editedBody = ""
    @State private var showBodyPreview = false

    // New comment
    @State private var newCommentText = ""
    @State private var isAddingComment = false

    // Metadata editing
    @State private var availableLabels: [(id: String, name: String, color: String?)] = []
    @State private var availableAssignees: [(id: String, login: String)] = []
    @State private var availableMilestones: [(id: String, number: Int, title: String)] = []
    @State private var isLoadingMetadata = false

    // Action states
    @State private var isUpdating = false
    @State private var actionError: String? = nil
    @State private var showConfirmDelete = false
    @State private var showConfirmClose = false
    @State private var showLockConfirm = false
    @State private var showTransferSheet = false
    @State private var showDangerZone = false

    // Parsed from externalUrl
    private var ownerRepoParsed: (owner: String, repo: String)? {
        guard let url = task.externalUrl else { return nil }
        // https://github.com/{owner}/{repo}/issues/{number}
        let parts = url.replacingOccurrences(of: "https://github.com/", with: "").components(separatedBy: "/")
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    private var issueNumber: Int? {
        guard let url = task.externalUrl else { return nil }
        let parts = url.components(separatedBy: "/")
        return parts.last.flatMap(Int.init)
    }

    private var serviceConfig: GitHubProviderConfig? { config }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            Divider()
            if isLoadingDetail {
                VStack { Spacer(); ProgressView("Loading issue…"); Spacer() }
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundColor(.orange)
                    Text(error).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { loadDetail() }.buttonStyle(.bordered)
                    Spacer()
                }
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        issueTitleSection
                        Divider().padding(.vertical, 8)
                        issueBodySection
                        Divider().padding(.vertical, 8)
                        issueMetadataSection
                        Divider().padding(.vertical, 8)
                        commentsSection
                        Divider().padding(.vertical, 8)
                        addCommentSection
                        Divider().padding(.vertical, 8)
                        dangerZoneSection
                    }
                    .padding()
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task { loadDetail() }
        .alert("Delete issue?", isPresented: $showConfirmDelete) {
            Button("Delete", role: .destructive) { deleteIssue() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete the issue and cannot be undone.")
        }
        .alert("Close issue?", isPresented: $showConfirmClose) {
            Button("Close Issue") { toggleIssueState() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Close")

            // Issue number + state
            if let number = detail?.number ?? issueNumber {
                Text("#\(number)")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if let detail = detail {
                StateBadge(state: detail.state == "open" ? .open : .closed)
                if detail.locked {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .labelStyle(.iconOnly)
                }
            }

            Spacer()

            if let error = actionError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            // Open in browser
            if let url = task.externalUrl, let urlObj = URL(string: url) {
                Link(destination: urlObj) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open in GitHub")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Title Section

    @ViewBuilder
    private var issueTitleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("Issue title", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                HStack {
                    Button("Save") {
                        saveTitle()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedTitle.trimmingCharacters(in: .whitespaces).isEmpty || isUpdating)
                    Button("Cancel") {
                        isEditingTitle = false
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(alignment: .top) {
                    Text(detail?.title ?? task.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    if canEdit {
                        Button(action: {
                            editedTitle = detail?.title ?? task.title
                            isEditingTitle = true
                        }) {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Edit title")
                    }
                }
            }
        }
    }

    // MARK: - Body Section

    @ViewBuilder
    private var issueBodySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Description", systemImage: "text.alignleft")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if !isEditingBody && canEdit {
                    Button(action: {
                        editedBody = detail?.body ?? ""
                        showBodyPreview = false
                        isEditingBody = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isEditingBody {
                Picker("", selection: $showBodyPreview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                if showBodyPreview {
                    let preview = (try? AttributedString(markdown: editedBody.isEmpty ? "*No content*" : editedBody))
                        ?? AttributedString(editedBody)
                    ScrollView {
                        Text(preview)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                } else {
                    TextEditor(text: $editedBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 300)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }

                HStack {
                    Button("Save") { saveBody() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isUpdating)
                    Button("Cancel") { isEditingBody = false }
                        .buttonStyle(.bordered)
                }
            } else {
                let body = detail?.body ?? task.description
                if let body = body, !body.isEmpty {
                    let rendered = (try? AttributedString(markdown: body)) ?? AttributedString(body)
                    Text(rendered)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("No description provided.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
    }

    // MARK: - Metadata Section

    @ViewBuilder
    private var issueMetadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Assignees
            metadataRow(icon: "person.2", title: "Assignees") {
                let names = detail?.assignees.map(\.login) ?? task.assignees
                if names.isEmpty {
                    Text("No assignees").font(.subheadline).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(names, id: \.self) {
                            Text($0).font(.subheadline)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1)).cornerRadius(4)
                        }
                    }
                }
            }

            // Labels
            metadataRow(icon: "tag", title: "Labels") {
                let labels = detail?.labels.map(\.name) ?? task.labels
                if labels.isEmpty {
                    Text("No labels").font(.subheadline).foregroundColor(.secondary)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(labels, id: \.self) { label in
                            let hex = detail?.labels.first(where: { $0.name == label })?.color
                            Text(label)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(
                                    hex.map { Color(hex: $0) }?.opacity(0.25) ?? Color.accentColor.opacity(0.15)
                                )
                                .cornerRadius(10)
                        }
                    }
                }
            }

            // Milestone
            metadataRow(icon: "flag", title: "Milestone") {
                if let ms = detail?.milestone {
                    HStack(spacing: 4) {
                        Image(systemName: ms.state == "open" ? "flag" : "flag.fill")
                            .foregroundColor(ms.state == "open" ? .primary : .secondary)
                            .font(.caption)
                        Text(ms.title).font(.subheadline)
                        if let due = ms.dueOn {
                            Text("· due \(due, style: .date)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("No milestone").font(.subheadline).foregroundColor(.secondary)
                }
            }

            // Linked PR
            if let pr = detail?.pullRequest, let prUrl = pr.htmlUrl, let urlObj = URL(string: prUrl) {
                metadataRow(icon: "arrow.triangle.pull", title: "Pull Request") {
                    Link(destination: urlObj) {
                        HStack(spacing: 4) {
                            Image(systemName: pr.mergedAt != nil ? "arrow.triangle.merge" : "arrow.triangle.pull")
                            Text(prUrl.components(separatedBy: "/").last ?? prUrl)
                        }
                        .font(.subheadline)
                    }
                }
            }

            // Created by
            if let user = detail?.user {
                metadataRow(icon: "person", title: "Opened by") {
                    Text(user.login).font(.subheadline).textSelection(.enabled)
                }
            }

            // Dates
            metadataRow(icon: "calendar", title: "Dates") {
                VStack(alignment: .leading, spacing: 2) {
                    if let d = detail {
                        Text("Created \(d.createdAt, style: .relative)").font(.caption).foregroundColor(.secondary)
                        Text("Updated \(d.updatedAt, style: .relative)").font(.caption).foregroundColor(.secondary)
                        if let closed = d.closedAt {
                            Text("Closed \(closed, style: .relative)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary).fontWeight(.medium)
                content()
            }
        }
    }

    // MARK: - Comments Section

    @ViewBuilder
    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Comments (\(comments.count))", systemImage: "bubble.left.and.bubble.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if comments.isEmpty {
                Text("No comments yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(comments) { comment in
                    CommentBubble(comment: comment)
                }
            }
        }
    }

    // MARK: - Add Comment Section

    @ViewBuilder
    private var addCommentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Add Comment", systemImage: "plus.bubble")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            TextEditor(text: $newCommentText)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Text("Supports Markdown")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: submitComment) {
                    Label("Comment", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment || !canEdit)
            }
        }
    }

    // MARK: - Danger Zone Section

    @ViewBuilder
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { showDangerZone.toggle() }) {
                HStack {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Image(systemName: showDangerZone ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showDangerZone {
                VStack(alignment: .leading, spacing: 8) {
                    // State toggle
                    if let detail = detail {
                        Button(action: {
                            if detail.state == "open" {
                                showConfirmClose = true
                            } else {
                                toggleIssueState()
                            }
                        }) {
                            Label(detail.state == "open" ? "Close Issue" : "Reopen Issue",
                                  systemImage: detail.state == "open" ? "xmark.circle" : "arrow.counterclockwise.circle")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(detail.state == "open" ? .red : .green)

                        // Lock / Unlock
                        Button(action: { detail.locked ? unlockIssue() : lockIssue() }) {
                            Label(detail.locked ? "Unlock Issue" : "Lock Issue",
                                  systemImage: detail.locked ? "lock.open" : "lock")
                        }
                        .buttonStyle(.bordered)
                    }

                    // Duplicate
                    Button(action: duplicateIssue) {
                        Label("Duplicate Issue", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Divider()

                    // Delete (red, confirm required)
                    Button(action: { showConfirmDelete = true }) {
                        Label("Delete Issue", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .disabled(!canEdit)
                }
                .padding(.leading, 4)
            }
        }
    }

    // MARK: - Load Detail

    private func loadDetail() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else {
            // Fall back to showing what we have from UnifiedTask
            return
        }

        isLoadingDetail = true
        loadError = nil

        Task {
            defer { isLoadingDetail = false }
            do {
                let service = GitHubProjectsService(config: cfg)
                guard try await service.authenticate() else {
                    loadError = "Authentication failed"
                    return
                }
                async let detailResult = service.getIssueDetail(owner: owner, repo: repo, number: number)
                async let commentsResult = service.listIssueComments(owner: owner, repo: repo, number: number)
                detail = try await detailResult
                comments = try await commentsResult

                // Load metadata for editing
                async let labelsResult = service.listRepositoryLabels(owner: owner, name: repo)
                async let assigneesResult = service.listAssignableUsers(owner: owner, name: repo)
                async let milestonesResult = service.listRepositoryMilestones(owner: owner, name: repo)
                availableLabels = try await labelsResult
                availableAssignees = try await assigneesResult
                availableMilestones = try await milestonesResult
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Actions

    private var canEdit: Bool { serviceConfig != nil && ownerRepoParsed != nil && issueNumber != nil }

    private func saveTitle() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else { return }
        let newTitle = editedTitle.trimmingCharacters(in: .whitespaces)
        guard !newTitle.isEmpty else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                detail = try await GitHubProjectsService(config: cfg)
                    .updateIssue(owner: owner, repo: repo, number: number, title: newTitle)
                isEditingTitle = false
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func saveBody() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                detail = try await GitHubProjectsService(config: cfg)
                    .updateIssue(owner: owner, repo: repo, number: number, body: editedBody)
                isEditingBody = false
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func submitComment() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else { return }
        let text = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAddingComment = true
        actionError = nil
        Task {
            defer { isAddingComment = false }
            do {
                let comment = try await GitHubProjectsService(config: cfg)
                    .createIssueComment(owner: owner, repo: repo, number: number, body: text)
                comments.append(comment)
                newCommentText = ""
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func toggleIssueState() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber,
              let current = detail else { return }
        let newState = current.state == "open" ? "closed" : "open"
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                detail = try await GitHubProjectsService(config: cfg)
                    .updateIssue(owner: owner, repo: repo, number: number, state: newState)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func lockIssue() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                try await GitHubProjectsService(config: cfg).lockIssue(owner: owner, repo: repo, number: number)
                detail?.locked = true
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func unlockIssue() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                try await GitHubProjectsService(config: cfg).unlockIssue(owner: owner, repo: repo, number: number)
                detail?.locked = false
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func deleteIssue() {
        guard let cfg = serviceConfig,
              let nodeId = detail?.nodeId else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                try await GitHubProjectsService(config: cfg).deleteIssue(nodeId: nodeId)
                onClose()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func duplicateIssue() {
        guard let cfg = serviceConfig,
              let (owner, repo) = ownerRepoParsed,
              let number = issueNumber else { return }
        let currentTitle = detail?.title ?? task.title
        let currentBody = detail?.body ?? task.description ?? ""
        let dupTitle = "Duplicate of #\(number): \(currentTitle)"
        let dupBody = "Duplicate of #\(number)\n\n\(currentBody)"

        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                let service = GitHubProjectsService(config: cfg)
                guard try await service.authenticate() else { return }
                let repoId = try await service.getRepositoryId(owner: owner, name: repo)
                _ = try await service.createIssue(
                    repositoryId: repoId,
                    title: dupTitle,
                    body: dupBody
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Comment Bubble

private struct CommentBubble: View {
    let comment: GitHubComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.user?.login ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(comment.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            let rendered = (try? AttributedString(markdown: comment.body)) ?? AttributedString(comment.body)
            Text(rendered)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

// MARK: - Color Helper

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default: r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}
