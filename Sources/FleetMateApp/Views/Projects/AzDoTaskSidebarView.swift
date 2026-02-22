import SwiftUI
import FleetMateCore

/// Full editable Azure DevOps work item sidebar — mirrors the web UI.
/// Loads full work item detail, supports inline editing of all fields,
/// threaded comments, relations display, and state management.
struct AzDoTaskSidebarView: View {
    let task: UnifiedTask
    let service: AzureDevOpsService
    let onClose: () -> Void

    // Full detail loaded from API
    @State private var workItem: WorkItem?
    @State private var comments: [WorkItemComment] = []
    @State private var isLoadingDetail = false
    @State private var loadError: String?

    // Editing state — title
    @State private var isEditingTitle = false
    @State private var editedTitle = ""

    // Editing state — description
    @State private var isEditingDescription = false
    @State private var editedDescription = ""

    // Editing state — metadata pickers
    @State private var isEditingState = false
    @State private var editedState = ""
    @State private var isEditingPriority = false
    @State private var editedPriority = 2
    @State private var isEditingAssignee = false
    @State private var editedAssignee = ""

    // Editing state — paths & tags
    @State private var isEditingAreaPath = false
    @State private var editedAreaPath = ""
    @State private var isEditingIterationPath = false
    @State private var editedIterationPath = ""
    @State private var isEditingTags = false
    @State private var editedTags = ""

    // Editing state — effort fields
    @State private var isEditingEffort = false
    @State private var editedRemaining = ""
    @State private var editedOriginal = ""
    @State private var editedCompleted = ""

    // Editing state — repro steps / acceptance criteria
    @State private var isEditingReproSteps = false
    @State private var editedReproSteps = ""
    @State private var isEditingAcceptance = false
    @State private var editedAcceptance = ""

    // New comment
    @State private var newCommentText = ""
    @State private var isAddingComment = false

    // Action states
    @State private var isUpdating = false
    @State private var actionError: String?
    @State private var showDangerZone = false
    @State private var showConfirmRemove = false

    private var fields: WorkItemFields? { workItem?.fields }
    private var workItemId: Int? { Int(task.id) }

    private let stateOptions = ["New", "Active", "Resolved", "Closed", "Removed",
                                 "To Do", "Doing", "Done", "Planned", "In Progress"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            Divider()
            if isLoadingDetail {
                VStack { Spacer(); ProgressView("Loading work item…"); Spacer() }
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundColor(.orange)
                    Text(error).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { loadDetail() }.buttonStyle(.bordered)
                    Spacer()
                }.padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        titleSection
                        Divider().padding(.vertical, 8)
                        stateAndTypeSection
                        Divider().padding(.vertical, 8)
                        descriptionSection
                        Divider().padding(.vertical, 8)
                        metadataSection
                        Divider().padding(.vertical, 8)
                        effortSection
                        Divider().padding(.vertical, 8)
                        reproStepsSection
                        Divider().padding(.vertical, 8)
                        acceptanceCriteriaSection
                        if let relations = workItem?.relations, !relations.isEmpty {
                            Divider().padding(.vertical, 8)
                            relationsSection(relations)
                        }
                        Divider().padding(.vertical, 8)
                        datesSection
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
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Close")

            if let id = workItemId {
                Text("#\(id)")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            WorkItemTypeBadge(type: fields?.workItemType ?? task.bucket)
            StateBadge(state: task.state)

            Spacer()

            if let error = actionError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            if isUpdating {
                ProgressView()
                    .scaleEffect(0.6)
            }

            if let url = task.externalUrl, let urlObj = URL(string: url) {
                Link(destination: urlObj) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open in Azure DevOps")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Title Section

    @ViewBuilder
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("Work item title", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                HStack {
                    Button("Save") { saveField { UpdateWorkItemRequest(title: editedTitle.azdoTrimmed) } onSuccess: { isEditingTitle = false } }
                        .buttonStyle(.borderedProminent)
                        .disabled(editedTitle.azdoTrimmed.isEmpty || isUpdating)
                    Button("Cancel") { isEditingTitle = false }
                        .buttonStyle(.bordered)
                }
            } else {
                HStack(alignment: .top) {
                    Text(fields?.title ?? task.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer()
                    editButton {
                        editedTitle = fields?.title ?? task.title
                        isEditingTitle = true
                    }
                }
            }
        }
    }

    // MARK: - State & Type Section

    @ViewBuilder
    private var stateAndTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // State
            azdoMetadataRow(icon: "circle.fill", title: "State") {
                if isEditingState {
                    HStack {
                        Picker("", selection: $editedState) {
                            ForEach(stateOptions, id: \.self) { Text($0) }
                        }
                        .frame(width: 140)
                        Button("Save") { saveField { UpdateWorkItemRequest(state: editedState) } onSuccess: { isEditingState = false } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { isEditingState = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        WorkItemStateBadge(state: fields?.state)
                        if let reason = fields?.reason {
                            Text("(\(reason))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        editButton {
                            editedState = fields?.state ?? "New"
                            isEditingState = true
                        }
                    }
                }
            }

            // Type (read-only — Azure DevOps API doesn't support type changes)
            azdoMetadataRow(icon: "doc", title: "Type") {
                WorkItemTypeBadge(type: fields?.workItemType)
            }

            // Priority
            azdoMetadataRow(icon: "flag", title: "Priority") {
                if isEditingPriority {
                    HStack {
                        Picker("", selection: $editedPriority) {
                            Text("1 – Critical").tag(1)
                            Text("2 – High").tag(2)
                            Text("3 – Medium").tag(3)
                            Text("4 – Low").tag(4)
                        }
                        .frame(width: 140)
                        Button("Save") { saveField { UpdateWorkItemRequest(priority: editedPriority) } onSuccess: { isEditingPriority = false } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { isEditingPriority = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack {
                        PriorityIndicator(priority: fields?.priority)
                        Text(priorityLabel(fields?.priority))
                            .font(.subheadline)
                        editButton {
                            editedPriority = fields?.priority ?? 2
                            isEditingPriority = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Description Section

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Description", systemImage: "text.alignleft")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if !isEditingDescription {
                    editButton {
                        editedDescription = fields?.description ?? ""
                        isEditingDescription = true
                    }
                }
            }

            if isEditingDescription {
                EditableMarkdownField(label: "Description", text: $editedDescription)
                HStack {
                    Button("Save") { saveField { UpdateWorkItemRequest(description: editedDescription) } onSuccess: { isEditingDescription = false } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isUpdating)
                    Button("Cancel") { isEditingDescription = false }
                        .buttonStyle(.bordered)
                }
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

    // MARK: - Metadata Section (Assignee, Paths, Tags)

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Assigned To
            azdoMetadataRow(icon: "person", title: "Assigned To") {
                if isEditingAssignee {
                    HStack {
                        TextField("Email or name", text: $editedAssignee)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Button("Save") { saveField { UpdateWorkItemRequest(assignedTo: editedAssignee) } onSuccess: { isEditingAssignee = false } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { isEditingAssignee = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack {
                        Text(fields?.assignedTo?.displayName ?? "Unassigned")
                            .font(.subheadline)
                            .foregroundColor(fields?.assignedTo != nil ? .primary : .secondary)
                        editButton {
                            editedAssignee = fields?.assignedTo?.uniqueName ?? fields?.assignedTo?.displayName ?? ""
                            isEditingAssignee = true
                        }
                    }
                }
            }

            // Area Path
            azdoMetadataRow(icon: "folder", title: "Area Path") {
                if isEditingAreaPath {
                    HStack {
                        TextField("Area path", text: $editedAreaPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Button("Save") { saveField { UpdateWorkItemRequest(areaPath: editedAreaPath) } onSuccess: { isEditingAreaPath = false } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { isEditingAreaPath = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack {
                        Text(fields?.areaPath ?? "–")
                            .font(.subheadline)
                        editButton {
                            editedAreaPath = fields?.areaPath ?? ""
                            isEditingAreaPath = true
                        }
                    }
                }
            }

            // Iteration Path
            azdoMetadataRow(icon: "arrow.triangle.2.circlepath", title: "Iteration") {
                if isEditingIterationPath {
                    HStack {
                        TextField("Iteration path", text: $editedIterationPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Button("Save") { saveField { UpdateWorkItemRequest(iterationPath: editedIterationPath) } onSuccess: { isEditingIterationPath = false } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { isEditingIterationPath = false }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack {
                        Text(fields?.iterationPath ?? "–")
                            .font(.subheadline)
                        editButton {
                            editedIterationPath = fields?.iterationPath ?? ""
                            isEditingIterationPath = true
                        }
                    }
                }
            }

            // Tags
            azdoMetadataRow(icon: "tag", title: "Tags") {
                if isEditingTags {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Semicolon-separated tags", text: $editedTags)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save") { saveField { UpdateWorkItemRequest(tags: editedTags) } onSuccess: { isEditingTags = false } }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Cancel") { isEditingTags = false }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        let tagList = parseTags(fields?.tags)
                        if tagList.isEmpty {
                            Text("No tags").font(.subheadline).foregroundColor(.secondary)
                        } else {
                            FlowLayout(spacing: 4) {
                                ForEach(tagList, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.12))
                                        .cornerRadius(10)
                                }
                            }
                        }
                        editButton {
                            editedTags = fields?.tags ?? ""
                            isEditingTags = true
                        }
                    }
                }
            }

            // Board Column (read-only)
            if let column = fields?.boardColumn {
                azdoMetadataRow(icon: "rectangle.split.3x1", title: "Board Column") {
                    HStack(spacing: 4) {
                        Text(column).font(.subheadline)
                        if fields?.boardColumnDone == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Effort Section

    @ViewBuilder
    private var effortSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Effort", systemImage: "clock")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if !isEditingEffort {
                    editButton {
                        editedOriginal = fields?.originalEstimate.map { "\($0)" } ?? ""
                        editedRemaining = fields?.remainingWork.map { "\($0)" } ?? ""
                        editedCompleted = fields?.completedWork.map { "\($0)" } ?? ""
                        isEditingEffort = true
                    }
                }
            }

            if isEditingEffort {
                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Original").font(.caption).foregroundColor(.secondary)
                        TextField("hrs", text: $editedOriginal).textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                    VStack(alignment: .leading) {
                        Text("Remaining").font(.caption).foregroundColor(.secondary)
                        TextField("hrs", text: $editedRemaining).textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                    VStack(alignment: .leading) {
                        Text("Completed").font(.caption).foregroundColor(.secondary)
                        TextField("hrs", text: $editedCompleted).textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                }
                HStack {
                    Button("Save") {
                        saveField {
                            UpdateWorkItemRequest(
                                remainingWork: Double(editedRemaining),
                                originalEstimate: Double(editedOriginal),
                                completedWork: Double(editedCompleted)
                            )
                        } onSuccess: { isEditingEffort = false }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { isEditingEffort = false }.buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                HStack(spacing: 16) {
                    effortLabel("Original", value: fields?.originalEstimate)
                    effortLabel("Remaining", value: fields?.remainingWork)
                    effortLabel("Completed", value: fields?.completedWork)
                }
            }
        }
    }

    private func effortLabel(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value.map { "\($0)h" } ?? "–")
                .font(.subheadline)
                .monospacedDigit()
        }
    }

    // MARK: - Repro Steps Section (Bug)

    @ViewBuilder
    private var reproStepsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Repro Steps", systemImage: "ladybug")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if !isEditingReproSteps {
                    editButton {
                        editedReproSteps = fields?.reproSteps ?? ""
                        isEditingReproSteps = true
                    }
                }
            }
            if isEditingReproSteps {
                EditableMarkdownField(label: "Repro Steps", text: $editedReproSteps)
                HStack {
                    Button("Save") { saveField { UpdateWorkItemRequest(reproSteps: editedReproSteps) } onSuccess: { isEditingReproSteps = false } }
                        .buttonStyle(.borderedProminent).disabled(isUpdating)
                    Button("Cancel") { isEditingReproSteps = false }.buttonStyle(.bordered)
                }
            } else if let repro = fields?.reproSteps, !repro.isEmpty {
                MarkdownTextView(content: repro)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No repro steps.").font(.body).foregroundColor(.secondary).italic()
            }
        }
    }

    // MARK: - Acceptance Criteria Section (User Story)

    @ViewBuilder
    private var acceptanceCriteriaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Acceptance Criteria", systemImage: "checkmark.seal")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                if !isEditingAcceptance {
                    editButton {
                        editedAcceptance = fields?.acceptanceCriteria ?? ""
                        isEditingAcceptance = true
                    }
                }
            }
            if isEditingAcceptance {
                EditableMarkdownField(label: "Acceptance Criteria", text: $editedAcceptance)
                HStack {
                    Button("Save") { saveField { UpdateWorkItemRequest(acceptanceCriteria: editedAcceptance) } onSuccess: { isEditingAcceptance = false } }
                        .buttonStyle(.borderedProminent).disabled(isUpdating)
                    Button("Cancel") { isEditingAcceptance = false }.buttonStyle(.bordered)
                }
            } else if let criteria = fields?.acceptanceCriteria, !criteria.isEmpty {
                MarkdownTextView(content: criteria)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No acceptance criteria.").font(.body).foregroundColor(.secondary).italic()
            }
        }
    }

    // MARK: - Relations Section

    @ViewBuilder
    private func relationsSection(_ relations: [WorkItemRelation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Relations (\(relations.count))", systemImage: "link")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            let grouped = Dictionary(grouping: relations, by: { $0.relationType })
            let order: [WorkItemRelation.RelationType] = [.parent, .child, .related, .predecessor, .successor, .artifact, .other]
            ForEach(order, id: \.rawValue) { type in
                if let items = grouped[type], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(relationTypeLabel(type))
                            .font(.caption2)
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
        HStack(spacing: 6) {
            Image(systemName: relationIcon(relation.relationType))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 14)

            if let name = relation.attributes?.name {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(1)
            } else if let id = relation.linkedWorkItemId {
                Text("#\(id)")
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            } else if let url = relation.url {
                Text(url.components(separatedBy: "/").suffix(3).joined(separator: "/"))
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }

            Spacer()

            if let url = relation.url, let urlObj = URL(string: url.replacingOccurrences(of: "_apis/wit/workItems", with: "_workitems/edit")) {
                Link(destination: urlObj) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .help("Open")
            }
        }
        .padding(.vertical, 2)
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

    // MARK: - Dates Section

    @ViewBuilder
    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Dates", systemImage: "calendar")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
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
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            if let date = date, let parsed = parseISODate(date) {
                Text(parsed, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("–").font(.caption).foregroundColor(.secondary)
            }
            if let name = person?.displayName {
                Text("by \(name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Comments Section

    @ViewBuilder
    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Discussion (\(comments.count))", systemImage: "bubble.left.and.bubble.right")
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
                    DevOpsCommentBubble(comment: comment)
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
                Text("Supports Markdown & HTML")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: submitComment) {
                    Label("Comment", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingComment)
            }
        }
    }

    // MARK: - Danger Zone

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
                    let currentState = (fields?.state ?? "New").lowercased()
                    if currentState != "resolved" && currentState != "closed" {
                        Button(action: { quickStateChange("Resolved") }) {
                            Label("Resolve", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.green)
                    }
                    if currentState != "closed" {
                        Button(action: { quickStateChange("Closed") }) {
                            Label("Close", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.orange)
                    }
                    if currentState == "closed" || currentState == "resolved" {
                        Button(action: { quickStateChange("Active") }) {
                            Label("Reactivate", systemImage: "arrow.counterclockwise.circle")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.blue)
                    }

                    Divider()

                    Button(action: { showConfirmRemove = true }) {
                        Label("Remove Work Item", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
                .padding(.leading, 4)
            }
        }
    }

    // MARK: - Load Detail

    private func loadDetail() {
        guard let id = workItemId else { return }
        isLoadingDetail = true
        loadError = nil

        Task {
            defer { isLoadingDetail = false }
            do {
                workItem = try await service.getWorkItem(id: id)
            } catch {
                loadError = error.localizedDescription
                return
            }
            // Comments are non-blocking — failures don't prevent detail from showing
            Task {
                do {
                    comments = try await service.getComments(workItemId: id)
                } catch {
                    dbg.warn("AzDO comments load failed (non-fatal): \(error)", category: "azdo")
                }
            }
        }
    }

    // MARK: - Save Helpers

    private func saveField(buildRequest: () -> UpdateWorkItemRequest, onSuccess: @escaping () -> Void) {
        guard let id = workItemId else { return }
        let request = buildRequest()
        isUpdating = true
        actionError = nil
        Task {
            defer { isUpdating = false }
            do {
                workItem = try await service.updateWorkItem(id: id, request: request)
                onSuccess()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func quickStateChange(_ newState: String) {
        saveField { UpdateWorkItemRequest(state: newState) } onSuccess: { }
    }

    private func removeWorkItem() {
        saveField { UpdateWorkItemRequest(state: "Removed") } onSuccess: { onClose() }
    }

    private func submitComment() {
        guard let id = workItemId else { return }
        let text = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAddingComment = true
        actionError = nil
        Task {
            defer { isAddingComment = false }
            do {
                let comment = try await service.addComment(workItemId: id, text: text)
                comments.append(comment)
                newCommentText = ""
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func editButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "pencil")
                Text("Edit")
            }
            .font(.caption)
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .help("Edit")
    }

    @ViewBuilder
    private func azdoMetadataRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
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
}

// MARK: - DevOps Comment Bubble

private struct DevOpsCommentBubble: View {
    let comment: WorkItemComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.createdBy?.displayName ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if let dateStr = comment.createdDate, let date = parseDate(dateStr) {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            // Comments API returns HTML in renderedText or plain in text
            let content = comment.renderedText ?? comment.text ?? ""
            if !content.isEmpty {
                MarkdownTextView(content: content)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
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
