import SwiftUI
import FleetMateCore

/// Full editable Azure DevOps work item sidebar — mirrors the web UI.
/// Single Edit mode: one "Edit" button in header toggles all fields editable.
/// Layout: Header → Title → 2-col metadata → Description → Add Comment → Comment Feed → Effort/Repro/Acceptance/Relations/Dates
struct AzDoTaskSidebarView: View {
    let task: UnifiedTask
    let service: AzureDevOpsService
    let onClose: () -> Void
    var onSelectWorkItem: ((Int) -> Void)? = nil
    @EnvironmentObject private var appState: AppState

    // Full detail loaded from API
    @State private var workItem: WorkItem?
    @State private var parentWorkItem: WorkItem?
    @State private var comments: [WorkItemComment] = []
    @State private var isLoadingDetail = false
    @State private var loadError: String?

    // Single edit mode — all fields toggle together
    @State private var isEditing = false
    @State private var editedTitle = ""
    @State private var editedState = ""
    @State private var editedPriority = 2
    @State private var editedAssignee = ""
    @State private var editedAreaPath = ""
    @State private var editedIterationPath = ""
    @State private var editedTags = ""
    @State private var editedDueDate: Date?
    @State private var editedType = "Bug"
    @State private var editedDescription = ""
    @State private var editedRemaining = ""
    @State private var editedOriginal = ""
    @State private var editedCompleted = ""
    @State private var editedReproSteps = ""
    @State private var editedAcceptance = ""

    // Description / rich-text preview toggles
    @State private var showDescriptionPreview = false
    @State private var showReproPreview = false
    @State private var showAcceptancePreview = false

    // Pre-loaded picker options
    @State private var areaPaths: [String] = []
    @State private var iterationPaths: [String] = []
    @State private var teamMembers: [IdentityRef] = []

    // New comment
    @State private var newCommentText = ""
    @State private var isAddingComment = false

    // Linked work item info cache (title, state, date)
    @State private var linkedWorkItemInfo: [Int: LinkedWorkItemInfo] = [:]

    // Artifact display name cache (keyed by relation URL)
    @State private var artifactDisplayNames: [String: String] = [:]

    // Action states
    @State private var isUpdating = false
    @State private var actionError: String?
    @State private var showConfirmRemove = false

    // Code linking
    @State private var showLinkCodePopover = false
    @State private var linkRepos: [GitRepository] = []
    @State private var linkSelectedRepoId = ""
    @State private var linkTab: CodeLinkTab = .commit
    @State private var linkBranches: [GitRef] = []
    @State private var linkCommits: [GitCommitRef] = []
    @State private var linkPullRequests: [GitPullRequest] = []
    @State private var isLoadingLinkData = false
    @State private var isLinking = false
    @State private var linkError: String?
    @State private var linkSearchText = ""

    private enum CodeLinkTab: String, CaseIterable {
        case branch = "Branch"
        case commit = "Commit"
        case pullRequest = "Pull Request"
    }

    private struct LinkedWorkItemInfo {
        let title: String?
        let state: String?
        let workItemType: String?
        let changedDate: String?
    }

    private var fields: WorkItemFields? { workItem?.fields }
    private var workItemId: Int? { Int(task.id) }
    private var workItemProject: String? { fields?.teamProject }

    private var hasEffortData: Bool {
        fields?.originalEstimate != nil || fields?.remainingWork != nil || fields?.completedWork != nil
    }

    private let stateOptions = ["New", "Active", "Resolved", "Closed", "Removed",
                                 "To Do", "Doing", "Done", "Planned", "In Progress"]
    private let workItemTypes = ["Bug", "Task", "User Story", "Feature", "Epic", "Issue"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            Divider()
            if isLoadingDetail {
                VStack { Spacer(); ProgressView("Loading work item…"); Spacer() }
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error).font(.body).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { loadDetail() }.buttonStyle(.bordered)
                    Spacer()
                }.padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        parentSection
                        titleSection
                        Divider().padding(.vertical, 10)
                        metadataColumns
                        Divider().padding(.vertical, 10)
                        descriptionSection
                        Divider().padding(.vertical, 10)
                        codeLinkSection
                        if let relations = workItem?.relations, relations.contains(where: { $0.relationType != .artifact }) {
                            Divider().padding(.vertical, 10)
                            relationsSection(relations)
                        }
                        Divider().padding(.vertical, 10)
                        addCommentSection
                        Divider().padding(.vertical, 10)
                        commentsFeedSection
                        if isEditing || hasEffortData {
                            Divider().padding(.vertical, 10)
                            effortSection
                        }
                        if fields?.workItemType?.lowercased() == "bug",
                           let repro = fields?.reproSteps, !repro.isEmpty {
                            Divider().padding(.vertical, 10)
                            reproStepsSection
                        }
                        if let criteria = fields?.acceptanceCriteria, !criteria.isEmpty {
                            Divider().padding(.vertical, 10)
                            acceptanceCriteriaSection
                        }
                        Divider().padding(.vertical, 10)
                        datesSection
                    }
                    .padding()
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task(id: task.id) {
            resetState()
            loadDetail()
        }
        .alert("Remove work item?", isPresented: $showConfirmRemove) {
            Button("Remove", role: .destructive) { removeWorkItem() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will set the work item state to Removed.")
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Close")

            if let id = workItemId {
                Text("#\(id)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            WorkItemTypeBadge(type: fields?.workItemType ?? task.bucket)

            Spacer()

            if let error = actionError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            if isUpdating {
                ProgressView()
                    .scaleEffect(0.7)
            }

            if let url = task.externalUrl, let urlObj = URL(string: url) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }) {
                    Image(systemName: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy link")

                Button(action: { NSWorkspace.shared.open(urlObj) }) {
                    Image(systemName: "globe")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in Azure DevOps")
            }

            if isEditing {
                Button("Save All") { saveAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isUpdating)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(action: enterEditMode) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            actionsMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Actions Menu (top-right)

    private var actionsMenu: some View {
        Menu {
            let currentState = (fields?.state ?? "New").lowercased()
            if currentState != "resolved" && currentState != "closed" {
                Button(action: { quickStateChange("Resolved") }) {
                    Label("Resolve", systemImage: "checkmark.circle")
                }
            }
            if currentState != "closed" {
                Button(action: { quickStateChange("Closed") }) {
                    Label("Close", systemImage: "xmark.circle")
                }
            }
            if currentState == "closed" || currentState == "resolved" {
                Button(action: { quickStateChange("Active") }) {
                    Label("Reactivate", systemImage: "arrow.counterclockwise.circle")
                }
            }
            Divider()
            Button(role: .destructive, action: { showConfirmRemove = true }) {
                Label("Remove Work Item", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .fixedSize()
        .help("Work item actions")
    }

    // MARK: - Parent Section (above title)

    @ViewBuilder
    private var parentSection: some View {
        if let parent = parentWorkItem, let parentFields = parent.fields {
            Button(action: { onSelectWorkItem?(parent.id) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let parentType = parentFields.workItemType {
                        Text(parentType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("#\(parent.id)")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text(parentFields.title ?? "Parent")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                    if let board = parentFields.boardColumn {
                        Text("· \(board)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Title Section

    @ViewBuilder
    private var titleSection: some View {
        if isEditing {
            TextField("Work item title", text: $editedTitle)
                .textFieldStyle(.roundedBorder)
                .font(.title2)
        } else {
            Text(fields?.title ?? task.title)
                .font(.title2)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Two-Column Metadata

    @ViewBuilder
    private var metadataColumns: some View {
        HStack(alignment: .top, spacing: 24) {
            // Left column: State, Type, Priority, Due Date
            VStack(alignment: .leading, spacing: 12) {
                metadataField(title: "State") {
                    if isEditing {
                        Picker("", selection: $editedState) {
                            ForEach(stateOptions, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    } else {
                        HStack(spacing: 6) {
                            WorkItemStateBadge(state: fields?.state)
                            if let reason = fields?.reason {
                                Text("(\(reason))")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                metadataField(title: "Type") {
                    if isEditing {
                        Picker("", selection: $editedType) {
                            ForEach(workItemTypes, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    } else {
                        WorkItemTypeBadge(type: fields?.workItemType)
                    }
                }

                metadataField(title: "Priority") {
                    if isEditing {
                        Picker("", selection: $editedPriority) {
                            Text("1 – Critical").tag(1)
                            Text("2 – High").tag(2)
                            Text("3 – Medium").tag(3)
                            Text("4 – Low").tag(4)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    } else {
                        HStack(spacing: 6) {
                            PriorityIndicator(priority: fields?.priority)
                            Text(priorityLabel(fields?.priority))
                                .font(.body)
                        }
                    }
                }

                metadataField(title: "Due Date") {
                    if isEditing {
                        DatePicker("",
                            selection: Binding(
                                get: { editedDueDate ?? Date() },
                                set: { editedDueDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        if editedDueDate != nil {
                            Button(action: { editedDueDate = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Clear due date")
                        }
                    } else {
                        if let dateStr = fields?.dueDate, let date = parseISODate(dateStr) {
                            Text(date, style: .date)
                                .font(.body)
                        } else {
                            Text("–")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right column: Assigned To, Area Path, Iteration, Tags
            VStack(alignment: .leading, spacing: 12) {
                metadataField(title: "Assigned To") {
                    if isEditing {
                        if teamMembers.isEmpty {
                            TextField("Email or display name", text: $editedAssignee)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $editedAssignee) {
                                Text("Unassigned").tag("")
                                ForEach(teamMembers.indices, id: \.self) { i in
                                    Text(teamMembers[i].displayName ?? teamMembers[i].uniqueName ?? "Unknown")
                                        .tag(teamMembers[i].uniqueName ?? "")
                                }
                            }
                            .labelsHidden()
                        }
                    } else {
                        Text(fields?.assignedTo?.displayName ?? "Unassigned")
                            .font(.body)
                            .foregroundColor(fields?.assignedTo != nil ? .primary : .secondary)
                    }
                }

                metadataField(title: "Area Path") {
                    if isEditing {
                        if areaPaths.isEmpty {
                            TextField("Area path", text: $editedAreaPath)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $editedAreaPath) {
                                ForEach(areaPaths, id: \.self) { path in
                                    Text(path).tag(path)
                                }
                            }
                            .labelsHidden()
                        }
                    } else {
                        Text(fields?.areaPath ?? "–")
                            .font(.body)
                    }
                }

                metadataField(title: "Iteration") {
                    if isEditing {
                        if iterationPaths.isEmpty {
                            TextField("Iteration path", text: $editedIterationPath)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $editedIterationPath) {
                                ForEach(iterationPaths, id: \.self) { path in
                                    Text(path).tag(path)
                                }
                            }
                            .labelsHidden()
                        }
                    } else {
                        Text(fields?.iterationPath ?? "–")
                            .font(.body)
                    }
                }

                metadataField(title: "Tags") {
                    if isEditing {
                        TextField("Semicolon-separated tags", text: $editedTags)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        let tagList = parseTags(fields?.tags)
                        if tagList.isEmpty {
                            Text("No tags").font(.body).foregroundColor(.secondary)
                        } else {
                            FlowLayout(spacing: 4) {
                                ForEach(tagList, id: \.self) { tag in
                                    Text(tag)
                                        .font(.subheadline)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.12))
                                        .cornerRadius(10)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metadataField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            content()
        }
    }

    // MARK: - Description Section

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Description")
                    .font(.headline)
                if isEditing {
                    Picker("", selection: $showDescriptionPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .controlSize(.small)
                }
                Spacer()
            }

            if isEditing {
                EditableMarkdownField(text: $editedDescription, showPreview: showDescriptionPreview, hideToggle: true)
            } else {
                let desc = fields?.description ?? task.description
                if let desc = desc, !desc.isEmpty {
                    MarkdownTextView(content: desc)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No description provided.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
    }

    // MARK: - Add Comment Section (above feed)

    @ViewBuilder
    private var addCommentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Comment")
                .font(.headline)

            MentionTextEditor(text: $newCommentText, members: teamMembers)

            HStack {
                Text("Supports Markdown · ⌘Enter to post")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Send") { submitComment() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Comments Feed Section

    @ViewBuilder
    private var commentsFeedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments (\(comments.count))")
                .font(.headline)

            if comments.isEmpty {
                Text("No comments yet.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    DevOpsCommentBubble(
                        comment: comment,
                        service: service,
                        workItemId: workItem?.id,
                        project: workItemProject,
                        currentUserName: appState.devOpsSsoUserName,
                        onUpdate: { updatedComment in
                            if let idx = comments.firstIndex(where: { $0.id == updatedComment.id }) {
                                comments[idx] = updatedComment
                            }
                        },
                        onDelete: {
                            comments.removeAll { $0.id == comment.id }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Effort Section

    @ViewBuilder
    private var effortSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effort")
                .font(.headline)

            if isEditing {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Original").font(.subheadline).foregroundColor(.secondary)
                        TextField("hrs", text: $editedOriginal).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remaining").font(.subheadline).foregroundColor(.secondary)
                        TextField("hrs", text: $editedRemaining).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Completed").font(.subheadline).foregroundColor(.secondary)
                        TextField("hrs", text: $editedCompleted).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                }
            } else {
                HStack(spacing: 20) {
                    effortLabel("Original", value: fields?.originalEstimate)
                    effortLabel("Remaining", value: fields?.remainingWork)
                    effortLabel("Completed", value: fields?.completedWork)
                }
            }
        }
    }

    private func effortLabel(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Text(value.map { String(format: "%.1fh", $0) } ?? "–")
                .font(.body)
                .monospacedDigit()
        }
    }

    // MARK: - Repro Steps Section (Bug)

    @ViewBuilder
    private var reproStepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Repro Steps")
                    .font(.headline)
                if isEditing {
                    Picker("", selection: $showReproPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .controlSize(.small)
                }
                Spacer()
            }
            if isEditing {
                EditableMarkdownField(text: $editedReproSteps, showPreview: showReproPreview, hideToggle: true)
            } else if let repro = fields?.reproSteps, !repro.isEmpty {
                MarkdownTextView(content: repro)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Acceptance Criteria Section (User Story)

    @ViewBuilder
    private var acceptanceCriteriaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance Criteria")
                    .font(.headline)
                if isEditing {
                    Picker("", selection: $showAcceptancePreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .controlSize(.small)
                }
                Spacer()
            }
            if isEditing {
                EditableMarkdownField(text: $editedAcceptance, showPreview: showAcceptancePreview, hideToggle: true)
            } else if let criteria = fields?.acceptanceCriteria, !criteria.isEmpty {
                MarkdownTextView(content: criteria)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Relations Section

    @ViewBuilder
    private func relationsSection(_ relations: [WorkItemRelation]) -> some View {
        let nonArtifactRelations = relations.filter { $0.relationType != .artifact }
        VStack(alignment: .leading, spacing: 10) {
            Text("Relations (\(nonArtifactRelations.count))")
                .font(.headline)

            let grouped = Dictionary(grouping: nonArtifactRelations, by: { $0.relationType })
            let order: [WorkItemRelation.RelationType] = [.parent, .child, .related, .predecessor, .successor, .other]
            ForEach(order, id: \.rawValue) { type in
                if let items = grouped[type], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(relationTypeLabel(type))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, rel in
                            relationRow(rel)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationRow(_ relation: WorkItemRelation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: relationIcon(relation.relationType))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 16)

            if relation.relationType != .artifact, let id = relation.linkedWorkItemId {
                // Work item relation — show title, state badge, and date
                Button(action: { onSelectWorkItem?(id) }) {
                    HStack(spacing: 4) {
                        Text("#\(id)")
                            .font(.body)
                            .foregroundColor(.accentColor)
                        if let info = linkedWorkItemInfo[id] {
                            if let title = info.title {
                                Text(title)
                                    .font(.body)
                                    .foregroundColor(.accentColor)
                                    .lineLimit(1)
                            }
                            if let state = info.state {
                                Text(state)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(stateColor(state).opacity(0.15))
                                    .foregroundColor(stateColor(state))
                                    .clipShape(Capsule())
                            }
                            if let dateStr = info.changedDate {
                                Text(relativeDate(dateStr))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Open in sidebar")
            } else if let name = relation.attributes?.name {
                Text(name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
            } else if let url = relation.url {
                Text(url.components(separatedBy: "/").suffix(3).joined(separator: "/"))
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                Spacer()
            } else {
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }

    private func stateColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "new", "to do", "planned": return .blue
        case "active", "doing", "in progress", "developing": return .orange
        case "resolved", "testing": return .purple
        case "closed", "done": return .green
        case "removed": return .red
        default: return .secondary
        }
    }

    private func relativeDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateString) else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: dateString) else { return "" }
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func relationTypeLabel(_ type: WorkItemRelation.RelationType) -> String {
        switch type {
        case .parent: return "Parent"
        case .child: return "Child"
        case .related: return "Related"
        case .predecessor: return "Predecessor"
        case .successor: return "Successor"
        case .artifact: return "Linked Artifacts"
        case .other: return "Other Links"
        }
    }

    private func relationIcon(_ type: WorkItemRelation.RelationType) -> String {
        switch type {
        case .parent: return "arrow.up"
        case .child: return "arrow.down"
        case .related: return "link"
        case .predecessor: return "arrow.left"
        case .successor: return "arrow.right"
        case .artifact: return "doc.text"
        case .other: return "link"
        }
    }

    // MARK: - Code Link Section

    @ViewBuilder
    private var codeLinkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Development")
                    .font(.headline)
                Spacer()
                Button(action: { openLinkCodePopover() }) {
                    Label("Link", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showLinkCodePopover, arrowEdge: .trailing) {
                    linkCodePopoverContent
                }
            }

            // Show existing artifact links
            let artifactLinks = (workItem?.relations ?? []).filter { $0.relationType == .artifact }
            if artifactLinks.isEmpty {
                Text("No linked commits, branches, or pull requests.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(Array(artifactLinks.enumerated()), id: \.offset) { _, rel in
                    artifactLinkRow(rel)
                }
            }
        }
    }

    @ViewBuilder
    private func artifactLinkRow(_ relation: WorkItemRelation) -> some View {
        let artifactType = parseArtifactType(relation.url)
        let linkTypeName = relation.attributes?.name
        let displayName = artifactDisplayNames[relation.url ?? ""]
            ?? artifactLabel(for: relation.url)
        let webUrl = artifactWebUrl(relation.url)

        HStack(spacing: 8) {
            Image(systemName: artifactIcon(for: relation.url))
                .font(.subheadline)
                .foregroundColor(.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(linkTypeName ?? artifactType)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }
                if let webUrl = webUrl, let urlObj = URL(string: webUrl) {
                    Link(displayName, destination: urlObj)
                        .font(.body)
                        .lineLimit(1)
                        .help(webUrl)
                } else {
                    Text(displayName)
                        .font(.body)
                        .lineLimit(1)
                }
                if let comment = relation.attributes?.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func parseArtifactType(_ url: String?) -> String {
        guard let url = url?.lowercased() else { return "Artifact" }
        if url.contains("/commit/") || url.contains("git/commit") || url.contains("%2fcommit%2f") { return "Commit" }
        if url.contains("pullrequestid") || url.contains("/pullrequest/") || url.contains("git/pullrequestid") { return "Pull Request" }
        if url.contains("/ref/") || url.contains("git/ref") || url.contains("%2fref%2f") { return "Branch" }
        return "Artifact"
    }

    /// Convert vstfs:///Git/... URI to a web URL for the Azure DevOps portal.
    private func artifactWebUrl(_ vstfsUrl: String?) -> String? {
        guard let url = vstfsUrl else { return nil }
        let orgBase = service.baseUrl

        // vstfs:///Git/Commit/{projectId}/{repoId}/{commitSha}
        if url.contains("Git/Commit") || url.contains("Git%2FCommit") {
            let decoded = url.removingPercentEncoding ?? url
            let parts = decoded.components(separatedBy: "/")
            // .../{projectId}/{repoId}/{commitSha}
            if parts.count >= 3 {
                let commitSha = parts[parts.count - 1]
                let repoId = parts[parts.count - 2]
                let projectId = parts[parts.count - 3]
                return "\(orgBase)/\(projectId)/_git/\(repoId)/commit/\(commitSha)"
            }
        }

        // vstfs:///Git/PullRequestId/{projectId}/{pullRequestId}
        if url.contains("Git/PullRequestId") || url.contains("Git%2FPullRequestId") {
            let decoded = url.removingPercentEncoding ?? url
            let parts = decoded.components(separatedBy: "/")
            if parts.count >= 2 {
                let prId = parts[parts.count - 1]
                let projectId = parts[parts.count - 2]
                return "\(orgBase)/\(projectId)/_git/pullrequest/\(prId)"
            }
        }

        // vstfs:///Git/Ref/{projectId}/{repoId}/{encodedBranch}
        if url.contains("Git/Ref") || url.contains("Git%2FRef") {
            let decoded = url.removingPercentEncoding ?? url
            let parts = decoded.components(separatedBy: "/")
            if parts.count >= 3 {
                let repoId = parts[parts.count - 2]
                let projectId = parts[parts.count - 3]
                return "\(orgBase)/\(projectId)/_git/\(repoId)"
            }
        }

        // Fallback: if it's already an http URL, use it
        if url.hasPrefix("http") { return url }
        return nil
    }

    private func artifactIcon(for url: String?) -> String {
        guard let url = url?.lowercased() else { return "link" }
        if url.contains("/commit/") || url.contains("git/commit") { return "point.topleft.down.to.point.bottomright.curvepath" }
        if url.contains("pullrequestid") || url.contains("/pullrequest/") { return "arrow.triangle.pull" }
        if url.contains("/ref/") || url.contains("git/ref") { return "arrow.triangle.branch" }
        return "link"
    }

    private func artifactLabel(for url: String?) -> String {
        guard let url = url else { return "Linked Artifact" }
        if url.contains("Commit") { return "Commit" }
        if url.contains("PullRequestId") { return "Pull Request" }
        if url.contains("Ref") { return "Branch" }
        return "Artifact"
    }

    // MARK: - Link Code Popover

    @ViewBuilder
    private var linkCodePopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link to Code")
                .font(.headline)

            if linkRepos.isEmpty && isLoadingLinkData {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(height: 60)
            } else if linkRepos.isEmpty {
                Text("No repositories found.")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                // Repo picker
                Picker("Repository", selection: $linkSelectedRepoId) {
                    Text("Select…").tag("")
                    ForEach(linkRepos) { repo in
                        Text(repo.name).tag(repo.id)
                    }
                }
                .onChange(of: linkSelectedRepoId) { linkSearchText = ""; loadLinkDetails() }

                if !linkSelectedRepoId.isEmpty {
                    // Tab picker
                    Picker("", selection: $linkTab) {
                        ForEach(CodeLinkTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: linkTab) { linkSearchText = ""; loadLinkDetails() }

                    // Search field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search \(linkTab.rawValue.lowercased())…", text: $linkSearchText)
                            .textFieldStyle(.plain)
                        if !linkSearchText.isEmpty {
                            Button(action: { linkSearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                    if isLoadingLinkData {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .frame(height: 40)
                    } else {
                        linkTabContent
                    }
                }

                if let error = linkError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if isLinking {
                    HStack { Spacer(); ProgressView().scaleEffect(0.7); Text("Linking…").font(.caption); Spacer() }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, maxWidth: 500, minHeight: 500, maxHeight: 800)
    }

    @ViewBuilder
    private var linkTabContent: some View {
        let query = linkSearchText.lowercased()
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                switch linkTab {
                case .branch:
                    let filtered = linkBranches.filter { query.isEmpty || $0.shortName.lowercased().contains(query) }
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "No branches found." : "No matching branches.").font(.body).foregroundColor(.secondary)
                    } else {
                        ForEach(filtered) { branch in
                            Button(action: { linkBranch(branch) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.subheadline)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 16)
                                    Text(branch.shortName)
                                        .font(.body)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .commit:
                    let filtered = linkCommits.filter { commit in
                        guard !query.isEmpty else { return true }
                        let msg = (commit.comment ?? "").lowercased()
                        let id = commit.shortId.lowercased()
                        let author = (commit.author?.name ?? "").lowercased()
                        return msg.contains(query) || id.contains(query) || author.contains(query)
                    }
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "No commits found." : "No matching commits.").font(.body).foregroundColor(.secondary)
                    } else {
                        ForEach(filtered) { commit in
                            Button(action: { linkCommit(commit) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                        .font(.subheadline)
                                        .foregroundColor(.orange)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(commit.comment ?? "No message")
                                            .font(.body)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(commit.shortId)
                                                .font(.caption)
                                                .monospacedDigit()
                                                .foregroundColor(.secondary)
                                            if let author = commit.author?.name {
                                                Text(author)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .pullRequest:
                    let filtered = linkPullRequests.filter { pr in
                        guard !query.isEmpty else { return true }
                        let title = (pr.title ?? "").lowercased()
                        let branch = (pr.sourceBranch ?? "").lowercased()
                        let id = String(pr.pullRequestId)
                        return title.contains(query) || branch.contains(query) || id.contains(query)
                    }
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "No pull requests found." : "No matching pull requests.").font(.body).foregroundColor(.secondary)
                    } else {
                        ForEach(filtered) { pr in
                            Button(action: { linkPR(pr) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.pull")
                                        .font(.subheadline)
                                        .foregroundColor(pr.status == "completed" ? .purple : .green)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pr.title ?? "Untitled PR")
                                            .font(.body)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text("#\(pr.pullRequestId)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if let branch = pr.sourceBranch {
                                                Text(branch)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            if let status = pr.status {
                                                Text(status.capitalized)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Code Link Actions

    private func openLinkCodePopover() {
        showLinkCodePopover = true
        linkError = nil
        linkSelectedRepoId = ""
        linkBranches = []
        linkCommits = []
        linkPullRequests = []
        guard linkRepos.isEmpty else { return }
        isLoadingLinkData = true
        Task {
            defer { isLoadingLinkData = false }
            do {
                linkRepos = try await service.getRepositories(project: workItemProject)
            } catch {
                linkError = "Failed to load repos: \(error.localizedDescription)"
            }
        }
    }

    private func loadLinkDetails() {
        guard !linkSelectedRepoId.isEmpty else { return }
        isLoadingLinkData = true
        linkError = nil
        let repoId = linkSelectedRepoId
        let proj = workItemProject
        Task {
            defer { isLoadingLinkData = false }
            do {
                switch linkTab {
                case .branch:
                    linkBranches = try await service.getBranches(repositoryId: repoId, project: proj)
                case .commit:
                    linkCommits = try await service.getCommits(repositoryId: repoId, project: proj)
                case .pullRequest:
                    linkPullRequests = try await service.getPullRequests(repositoryId: repoId, project: proj)
                }
            } catch {
                linkError = error.localizedDescription
            }
        }
    }

    private func selectedRepoProjectId() -> String? {
        linkRepos.first(where: { $0.id == linkSelectedRepoId })?.project?.id
    }

    private func linkBranch(_ branch: GitRef) {
        guard let id = workItemId, let projectId = selectedRepoProjectId() else { return }
        let uri = AzureDevOpsService.branchArtifactUri(projectId: projectId, repositoryId: linkSelectedRepoId, branchName: branch.shortName)
        performLink(workItemId: id, uri: uri, name: "Branch")
    }

    private func linkCommit(_ commit: GitCommitRef) {
        guard let id = workItemId, let projectId = selectedRepoProjectId() else { return }
        let uri = AzureDevOpsService.commitArtifactUri(projectId: projectId, repositoryId: linkSelectedRepoId, commitId: commit.commitId)
        performLink(workItemId: id, uri: uri, name: "Fixed in Commit")
    }

    private func linkPR(_ pr: GitPullRequest) {
        guard let id = workItemId, let projectId = selectedRepoProjectId() else { return }
        let uri = AzureDevOpsService.pullRequestArtifactUri(projectId: projectId, repositoryId: linkSelectedRepoId, pullRequestId: pr.pullRequestId)
        performLink(workItemId: id, uri: uri, name: "Pull Request")
    }

    private func performLink(workItemId: Int, uri: String, name: String) {
        isLinking = true
        linkError = nil
        Task {
            defer { isLinking = false }
            do {
                workItem = try await service.addWorkItemArtifactLink(workItemId: workItemId, artifactUri: uri, linkName: name)
                showLinkCodePopover = false
            } catch {
                linkError = error.localizedDescription
            }
        }
    }

    // MARK: - Dates Section

    @ViewBuilder
    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dates")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                azdoDateRow("Created", date: fields?.createdDate, by: fields?.createdBy)
                azdoDateRow("Changed", date: fields?.changedDate, by: fields?.changedBy)
                if let stateDate = fields?.stateChangeDate {
                    azdoDateRow("State Changed", date: stateDate, by: nil)
                }
                if let resolvedDate = fields?.resolvedDate {
                    azdoDateRow("Resolved", date: resolvedDate, by: fields?.resolvedBy)
                }
                if let closedDate = fields?.closedDate {
                    azdoDateRow("Closed", date: closedDate, by: fields?.closedBy)
                }
            }
        }
    }

    private func azdoDateRow(_ label: String, date: String?, by person: IdentityRef?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            if let date = date, let parsed = parseISODate(date) {
                Text(parsed, style: .relative)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("–").font(.subheadline).foregroundColor(.secondary)
            }
            if let name = person?.displayName {
                Text("by \(name)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - State Management

    private func resetState() {
        workItem = nil
        parentWorkItem = nil
        comments = []
        isEditing = false
        isLoadingDetail = false
        loadError = nil
        newCommentText = ""
        actionError = nil
        linkedWorkItemInfo = [:]
        artifactDisplayNames = [:]
        areaPaths = []
        iterationPaths = []
        teamMembers = []
        linkRepos = []
        linkSelectedRepoId = ""
        linkBranches = []
        linkCommits = []
        linkPullRequests = []
        showLinkCodePopover = false
    }

    private func enterEditMode() {
        editedTitle = fields?.title ?? task.title
        editedState = fields?.state ?? "New"
        editedType = fields?.workItemType ?? "Bug"
        editedPriority = fields?.priority ?? 2
        editedAssignee = fields?.assignedTo?.uniqueName ?? fields?.assignedTo?.displayName ?? ""
        editedAreaPath = fields?.areaPath ?? ""
        editedIterationPath = fields?.iterationPath ?? ""
        editedTags = fields?.tags ?? ""
        if let dueDateStr = fields?.dueDate, let parsed = parseISODate(dueDateStr) {
            editedDueDate = parsed
        } else {
            editedDueDate = nil
        }
        editedDescription = fields?.description ?? ""
        editedRemaining = fields?.remainingWork.map { "\($0)" } ?? ""
        editedOriginal = fields?.originalEstimate.map { "\($0)" } ?? ""
        editedCompleted = fields?.completedWork.map { "\($0)" } ?? ""
        editedReproSteps = fields?.reproSteps ?? ""
        editedAcceptance = fields?.acceptanceCriteria ?? ""
        showDescriptionPreview = false
        showReproPreview = false
        showAcceptancePreview = false
        isEditing = true
    }

    // MARK: - Load Detail

    private func loadDetail() {
        guard let id = workItemId else { return }
        isLoadingDetail = true
        loadError = nil

        Task {
            defer { isLoadingDetail = false }
            let loadedItem: WorkItem?
            do {
                loadedItem = try await service.getWorkItem(id: id)
                workItem = loadedItem
            } catch {
                loadError = error.localizedDescription
                return
            }
            // Read project directly from loaded item (not from @State) to avoid stale reads
            let proj = loadedItem?.fields?.teamProject
            Task {
                do {
                    comments = try await service.getComments(workItemId: id, project: proj)
                } catch {
                    dbg.warn("AzDO comments load failed: \(error)", category: "azdo")
                    actionError = "Comments failed to load"
                }
            }
            // Load parent work item if relation exists
            if let parentRel = loadedItem?.relations?.first(where: { $0.relationType == .parent }),
               let parentId = parentRel.linkedWorkItemId {
                Task {
                    do {
                        parentWorkItem = try await service.getWorkItem(id: parentId)
                    } catch {
                        dbg.debug("Parent load failed: \(error)", category: "azdo")
                    }
                }
            }
            // Fetch info for linked work items (non-artifact relations)
            if let relations = loadedItem?.relations {
                let workItemIds = relations
                    .filter { $0.relationType != .artifact }
                    .compactMap { $0.linkedWorkItemId }
                if !workItemIds.isEmpty {
                    Task {
                        do {
                            let items = try await service.getWorkItemsByIds(workItemIds)
                            var info: [Int: LinkedWorkItemInfo] = [:]
                            for item in items {
                                info[item.id] = LinkedWorkItemInfo(
                                    title: item.fields?.title,
                                    state: item.fields?.state,
                                    workItemType: item.fields?.workItemType,
                                    changedDate: item.fields?.changedDate
                                )
                            }
                            linkedWorkItemInfo = info
                        } catch {
                            dbg.debug("Linked work item info load failed: \(error)", category: "azdo")
                        }
                    }
                }
                // Fetch display names for artifact links (commits, PRs, branches)
                let artifacts = relations.filter { $0.relationType == .artifact }
                if !artifacts.isEmpty {
                    Task { await loadArtifactNames(artifacts) }
                }
            }
            // Pre-load picker data (non-blocking)
            let pickerProj = proj
            Task {
                do { areaPaths = try await service.getAreaPaths(project: pickerProj) } catch {
                    dbg.debug("Area paths load failed: \(error)", category: "azdo")
                }
            }
            Task {
                do { iterationPaths = try await service.getIterationPaths(project: pickerProj) } catch {
                    dbg.debug("Iteration paths load failed: \(error)", category: "azdo")
                }
            }
            Task {
                do { teamMembers = try await service.getTeamMembers(project: pickerProj) } catch {
                    dbg.debug("Team members load failed: \(error)", category: "azdo")
                }
            }
        }
    }

    // MARK: - Load Artifact Names

    /// Parse vstfs:// URIs and fetch real names for commits, PRs, and branches.
    private func loadArtifactNames(_ artifacts: [WorkItemRelation]) async {
        var names: [String: String] = [:]

        for artifact in artifacts {
            guard let url = artifact.url else { continue }
            // attributes.name is the link type (e.g. "Fixed in Commit"), not the artifact name
            // Always fetch the real artifact details

            let decoded = url.removingPercentEncoding ?? url

            // vstfs:///Git/Commit/{projectId}/{repoId}/{commitSha}
            if decoded.contains("Git/Commit") {
                let parts = decoded.components(separatedBy: "/")
                if parts.count >= 3 {
                    let commitSha = parts[parts.count - 1]
                    let repoId = parts[parts.count - 2]
                    do {
                        let commit = try await service.getCommit(repositoryId: repoId, commitId: commitSha)
                        let msg = commit.comment?.components(separatedBy: "\n").first ?? commit.shortId
                        names[url] = "\(commit.shortId) \(msg)"
                    } catch {
                        names[url] = String(commitSha.prefix(7))
                    }
                }
            }

            // vstfs:///Git/PullRequestId/{projectId}/{pullRequestId}
            else if decoded.contains("Git/PullRequestId") {
                let parts = decoded.components(separatedBy: "/")
                if parts.count >= 2 {
                    let prIdStr = parts[parts.count - 1]
                    if let prId = Int(prIdStr) {
                        let projectId = parts[parts.count - 2]
                        do {
                            let pr = try await service.getPullRequestById(prId, project: projectId)
                            names[url] = "PR #\(prId) \(pr.title ?? "")"
                        } catch {
                            names[url] = "PR #\(prId)"
                        }
                    }
                }
            }

            // vstfs:///Git/Ref/{projectId}/{repoId}/{encodedRefName}
            else if decoded.contains("Git/Ref") {
                let parts = decoded.components(separatedBy: "/")
                if parts.count >= 3 {
                    // The last component is the encoded ref name (e.g., "GBrefs%2Fheads%2Fmain" or "refs/heads/feature")
                    let refEncoded = parts[parts.count - 1]
                    let refDecoded = refEncoded.removingPercentEncoding ?? refEncoded
                    // Clean up: remove "GB" prefix and "refs/heads/" prefix
                    var branchName = refDecoded
                    if branchName.hasPrefix("GB") { branchName = String(branchName.dropFirst(2)) }
                    branchName = branchName.removingPercentEncoding ?? branchName
                    if branchName.hasPrefix("refs/heads/") { branchName = String(branchName.dropFirst("refs/heads/".count)) }
                    names[url] = branchName
                }
            }
        }

        artifactDisplayNames = names
    }

    // MARK: - Save All

    private func saveAll() {
        guard let id = workItemId else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                let typeChanged = editedType != (fields?.workItemType ?? "")
                let request = UpdateWorkItemRequest(
                    title: editedTitle.azdoTrimmed,
                    state: editedState,
                    workItemType: typeChanged ? editedType : nil,
                    assignedTo: editedAssignee,
                    priority: editedPriority,
                    iterationPath: editedIterationPath,
                    areaPath: editedAreaPath,
                    description: editedDescription,
                    tags: editedTags,
                    remainingWork: Double(editedRemaining),
                    originalEstimate: Double(editedOriginal),
                    completedWork: Double(editedCompleted),
                    reproSteps: editedReproSteps,
                    acceptanceCriteria: editedAcceptance,
                    dueDate: editedDueDate.map { formatDateForApi($0) }
                )
                workItem = try await service.updateWorkItem(id: id, request: request)
                isEditing = false
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: - Quick Actions

    private func quickStateChange(_ newState: String) {
        guard let id = workItemId else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                workItem = try await service.updateWorkItem(id: id, request: UpdateWorkItemRequest(state: newState))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func removeWorkItem() {
        guard let id = workItemId else { return }
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                _ = try await service.updateWorkItem(id: id, request: UpdateWorkItemRequest(state: "Removed"))
                onClose()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func submitComment() {
        guard let id = workItemId else { return }
        let rawText = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return }
        // Convert @mentions to Azure DevOps HTML format
        let text = convertMentionsToHtml(rawText)
        isAddingComment = true
        actionError = nil
        Task {
            defer { isAddingComment = false }
            do {
                let comment = try await service.addComment(workItemId: id, text: text, project: workItemProject)
                comments.insert(comment, at: 0)
                newCommentText = ""
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Convert plain-text @DisplayName mentions to the HTML format Azure DevOps expects.
    private func convertMentionsToHtml(_ text: String) -> String {
        var result = text
        for member in teamMembers {
            guard let displayName = member.displayName else { continue }
            let email = member.uniqueName ?? ""
            let plain = "@\(displayName)"
            guard result.contains(plain) else { continue }
            let html = "<a href=\"mailto:\(email)\" data-vss-mention=\"version:2.0\">@\(displayName)</a>"
            result = result.replacingOccurrences(of: plain, with: html)
        }
        return result
    }

    // MARK: - Helpers

    private func parseTags(_ tags: String?) -> [String] {
        guard let tags = tags, !tags.isEmpty else { return [] }
        return tags.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func priorityLabel(_ priority: Int?) -> String {
        switch priority {
        case 1: return "Critical"
        case 2: return "High"
        case 3: return "Medium"
        case 4: return "Low"
        default: return "–"
        }
    }

    private func parseISODate(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: string)
    }

    /// Format an ISO date string to YYYY-MM-DD for the edit text field.
    private func formatDateForApi(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

// MARK: - DevOps Comment Bubble

private struct DevOpsCommentBubble: View {
    let comment: WorkItemComment
    let service: AzureDevOpsService
    let workItemId: Int?
    let project: String?
    var currentUserName: String? = nil
    var onUpdate: ((WorkItemComment) -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var showReactionPicker = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var showDeleteConfirm = false
    @State private var isUpdating = false
    @State private var linkCopied = false

    private let reactionEmojis: [(type: String, emoji: String)] = [
        ("like", "👍"), ("dislike", "👎"), ("heart", "❤️"), ("hooray", "🎉"), ("confused", "😕"), ("laugh", "😄")
    ]

    private var isOwnComment: Bool {
        guard let userName = currentUserName, let author = comment.createdBy?.displayName else { return false }
        return author.lowercased() == userName.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: author top-left, actions + timestamp top-right
            HStack(alignment: .top, spacing: 6) {
                Text(comment.createdBy?.displayName ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.semibold)

                Spacer()

                // Copy link
                if commentPermalink != nil {
                    Button(action: copyLink) {
                        Image(systemName: linkCopied ? "checkmark" : "link")
                            .font(.caption)
                            .foregroundColor(linkCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy comment link")
                }

                // Edit / Delete for own comments
                if isOwnComment {
                    Button(action: startEditing) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit comment")

                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete comment")
                    .alert("Delete Comment?", isPresented: $showDeleteConfirm) {
                        Button("Delete", role: .destructive) { deleteComment() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This cannot be undone.")
                    }
                }

                if let dateStr = comment.createdDate, let date = parseDate(dateStr) {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Comment content or edit field
            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $editText)
                        .font(.body)
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Button("Cancel") { isEditing = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                        Button("Save") { saveEdit() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUpdating)
                    }
                }
            } else {
                let rendered = comment.renderedText
                let content = (rendered != nil && !rendered!.isEmpty) ? rendered! : (comment.text ?? "")
                if !content.isEmpty {
                    MarkdownTextView(content: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Existing reactions + add button
            HStack(spacing: 6) {
                if let reactions = comment.reactions {
                    ForEach(reactions.filter { ($0.count ?? 0) > 0 }, id: \.type) { reaction in
                        if let type = reaction.type,
                           let emoji = reactionEmojis.first(where: { $0.type == type })?.emoji {
                            Text("\(emoji) \(reaction.count ?? 0)")
                                .font(.body)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(reaction.isCurrentUserEngaged == true ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                                .cornerRadius(12)
                        }
                    }
                }
                Button(action: { showReactionPicker.toggle() }) {
                    Image(systemName: "face.smiling")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add reaction")
                .popover(isPresented: $showReactionPicker) {
                    HStack(spacing: 10) {
                        ForEach(reactionEmojis, id: \.type) { item in
                            Button(item.emoji) {
                                addReaction(type: item.type)
                                showReactionPicker = false
                            }
                            .buttonStyle(.plain)
                            .font(.title2)
                        }
                    }
                    .padding(10)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func copyLink() {
        guard let url = commentPermalink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        linkCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { linkCopied = false }
    }

    private func startEditing() {
        editText = comment.text ?? ""
        isEditing = true
    }

    private func saveEdit() {
        guard let wiId = workItemId else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            do {
                let updated = try await service.updateComment(
                    workItemId: wiId, commentId: comment.id,
                    text: trimmed, project: project
                )
                isEditing = false
                onUpdate?(updated)
            } catch {
                // Stay in editing mode on failure
            }
        }
    }

    private func deleteComment() {
        guard let wiId = workItemId else { return }
        Task {
            do {
                try await service.deleteComment(workItemId: wiId, commentId: comment.id, project: project)
                onDelete?()
            } catch {
                // Silently fail
            }
        }
    }

    private func addReaction(type: String) {
        guard let wiId = workItemId else { return }
        Task {
            _ = try? await service.toggleCommentReaction(
                workItemId: wiId, commentId: comment.id,
                reactionType: type, add: true, project: project
            )
        }
    }

    private var commentPermalink: URL? {
        guard let wiId = workItemId, let proj = project else { return nil }
        let base = service.baseUrl
        let encodedProj = proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj
        return URL(string: "\(base)/\(encodedProj)/_workitems/edit/\(wiId)#\(comment.id)")
    }

    private func parseDate(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: string)
    }
}

// MARK: - String Trimmed Helper

private extension String {
    var azdoTrimmed: String { trimmingCharacters(in: .whitespaces) }
}
