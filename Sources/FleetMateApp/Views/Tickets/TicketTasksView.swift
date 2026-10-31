import SwiftUI
import FleetMateCore

struct TicketTasksView: View {
    @EnvironmentObject private var appState: AppState
    let ticketId: Int
    let service: TdxService
    let refreshToken: Int
    let onChanged: () -> Void

    @State private var isExpanded = false
    @State private var tasks: [TdxTicketTask] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reload = 0
    @State private var selection: TaskSheetSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("Tasks").font(.headline)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                Spacer()
                Button("Apply Template…") { selection = .init(mode: .template) }
                    .disabled(isLoading || selection != nil)
                Button("Add Task…") { selection = .init(mode: .create) }
                    .disabled(isLoading || selection != nil)
                Button("Refresh", systemImage: "arrow.clockwise") { reload += 1 }
                    .labelStyle(.iconOnly).help("Refresh tasks")
                    .disabled(isLoading || selection != nil)
            }
            if isExpanded {
                if isLoading { ProgressView("Loading tasks…").controlSize(.small) }
                else if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                else if tasks.isEmpty { Text("No tasks on this ticket.").foregroundStyle(.secondary) }
                else {
                    ForEach(tasks) { task in taskRow(task) }
                }
            }
        }
        .task(id: "\(refreshToken)-\(reload)") { await load() }
        .sheet(item: $selection, onDismiss: { reload += 1; onChanged() }) { selected in
            if selected.mode == .template {
                TicketTaskTemplateSheet(ticketId: ticketId, service: service,
                                        config: appState.config)
            } else if selected.mode == .create || selected.mode == .edit {
                TicketTaskEditor(ticketId: ticketId, task: selected.task,
                                 service: service)
            } else if let task = selected.task {
                TicketTaskDetail(ticketId: ticketId, task: task, service: service,
                                 isDeleting: selected.mode == .delete)
            }
        }
    }

    private func taskRow(_ task: TdxTicketTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(task.title) { selection = .init(mode: .update, task: task) }
                    .buttonStyle(.link).fontWeight(.medium)
                Spacer()
                Text("\(task.percentComplete)%").monospacedDigit()
                if task.isStandard {
                    Button("Edit…") { selection = .init(mode: .edit, task: task) }
                    Button("Delete…", role: .destructive) { selection = .init(mode: .delete, task: task) }
                }
            }
            ProgressView(value: Double(task.percentComplete), total: 100)
                .accessibilityLabel("Progress for \(task.title)")
            Text([task.typeLabel, task.responsibleGroupName, task.responsibleFullName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if !task.isActive && task.percentComplete < 100 {
                Text("Waiting for \(task.predecessorTitle ?? "predecessor task")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(.quaternary, in: .rect(cornerRadius: 6))
        .contextMenu {
            Button("Update Progress…") { selection = .init(mode: .update, task: task) }
            if task.isStandard {
                Button("Edit Task…") { selection = .init(mode: .edit, task: task) }
                Button("Delete Task…", role: .destructive) { selection = .init(mode: .delete, task: task) }
            }
        }
    }

    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await service.getTicketTasks(ticketId: ticketId)
            try Task.checkCancellation()
            tasks = loaded
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }
}

private struct TaskSheetSelection: Identifiable {
    enum Mode { case create, edit, update, delete, template }
    let id = UUID()
    let mode: Mode
    var task: TdxTicketTask?
}

private struct TicketTaskDetail: View {
    @Environment(\.dismiss) private var dismiss
    let ticketId: Int
    let task: TdxTicketTask
    let service: TdxService
    let isDeleting: Bool

    @State private var current: TdxTicketTask?
    @State private var feed: [TdxFeedEntry] = []
    @State private var loadingReplies: Int?
    @State private var replyError: String?
    @State private var progress = 0
    @State private var comments = ""
    @State private var isPrivate = false
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var didAttempt = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isDeleting ? "Delete Task" : task.title).font(.title2)
            Text("Ticket #\(String(ticketId)) · Task #\(String(task.id))").foregroundStyle(.secondary)
            if isLoading { ProgressView("Loading task…") }
            else if let current {
                if isDeleting {
                    Text("Permanently delete “\(current.title)”? This cannot be undone.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(current.typeLabel).foregroundStyle(.secondary)
                            if let description = current.description, !description.isEmpty {
                                MarkdownTextView(content: HtmlToMarkdown.convert(description)).textSelection(.enabled)
                            }
                            Text([current.responsibleGroupName, current.responsibleFullName]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            Text("Estimated: \(current.estimatedMinutes) min · Actual: \(current.actualMinutes ?? 0) min")
                            if let start = current.startDate { Text("Start: \(dateLabel(start))") }
                            if let end = current.endDate { Text("Due: \(dateLabel(end))") }
                            if let duration = current.completeWithinMinutes { Text("Expected duration: \(duration) operational min") }
                            if current.predecessorId > 0 {
                                Text("Predecessor: \(current.predecessorTitle ?? String(current.predecessorId))")
                            }
                            if current.percentComplete == 100 {
                                Text("Completed\(current.completedFullName.map { " by \($0)" } ?? "")\(current.completedDate.map { " · \(dateLabel($0))" } ?? "")")
                            }
                            Divider()
                            Text("Activity").font(.headline)
                            if let replyError { Text(replyError).foregroundStyle(.red) }
                            if feed.isEmpty { Text("No task activity.").foregroundStyle(.secondary) }
                            ForEach(Array(feed.enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text([entry.createdFullName, entry.createdDate.map(dateLabel)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    MarkdownTextView(content: HtmlToMarkdown.convert(entry.body ?? "")).textSelection(.enabled)
                                    ForEach(Array(entry.replyList.enumerated()), id: \.offset) { _, reply in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(reply.createdFullName ?? "Reply").font(.caption).foregroundStyle(.secondary)
                                            MarkdownTextView(content: HtmlToMarkdown.convert(reply.body ?? ""))
                                                .textSelection(.enabled)
                                        }.padding(.leading, 16)
                                    }
                                    if entry.hasUnloadedReplies, let id = entry.id {
                                        Button("Load \(entry.repliesCount ?? 0) replies") { Task { await loadReplies(id) } }
                                            .disabled(loadingReplies != nil)
                                    }
                                }
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 250)
                    HStack {
                        Text("Progress")
                        TextField("Percent complete", value: $progress, format: .number).frame(width: 60)
                        Text("%")
                        Stepper("Progress", value: $progress, in: 0...100, step: 5).labelsHidden()
                            .disabled(!current.isActive && current.percentComplete < 100)
                        Button("Set to 100%") { progress = 100 }
                            .disabled(!current.isActive && current.percentComplete < 100)
                    }.disabled(didAttempt || (!current.isActive && current.percentComplete < 100))
                    if !current.isActive && current.percentComplete < 100 {
                        Text("Progress is unavailable until its predecessor is complete.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Comment")
                    TextEditor(text: $comments).frame(height: 80).border(.quaternary)
                        .disabled(didAttempt)
                    Toggle("Private comment", isOn: $isPrivate).disabled(didAttempt)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(didAttempt ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                if isDeleting {
                    Button("Delete Task", role: .destructive) { Task { await submit() } }
                        .disabled(isLoading || current == nil || isSubmitting || didAttempt)
                } else {
                    Button(progress == 100 && current?.percentComplete != 100 ? "Complete Task" : "Save Update") {
                        Task { await submit() }
                    }.disabled(isLoading || current == nil || isSubmitting || didAttempt || !hasUpdate || !(0...100).contains(progress))
                }
            }
            if isSubmitting { ProgressView("Saving…").controlSize(.small) }
        }.padding(24).frame(width: 580)
            .interactiveDismissDisabled(isSubmitting)
            .task { await load() }
    }

    private var hasUpdate: Bool {
        progress != current?.percentComplete || !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor private func load() async {
        defer { isLoading = false }
        do {
            let loaded = try await service.getTicketTask(ticketId: ticketId, taskId: task.id)
            let entries = try await service.getTicketTaskFeed(ticketId: ticketId, taskId: task.id)
            try Task.checkCancellation()
            current = loaded
            progress = loaded.percentComplete
            feed = entries
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    @MainActor private func submit() async {
        guard let current, !didAttempt, !isSubmitting else { return }
        isSubmitting = true
        didAttempt = true
        defer { isSubmitting = false }
        do {
            if isDeleting { try await service.deleteTicketTask(ticketId: ticketId, expected: current) }
            else {
                try await service.updateTicketTask(ticketId: ticketId, expected: current,
                    update: .init(percentComplete: progress == current.percentComplete ? nil : progress,
                                  comments: comments, isPrivate: isPrivate))
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription + " Close to refresh before trying again." }
    }

    @MainActor private func loadReplies(_ id: Int) async {
        guard loadingReplies == nil else { return }
        loadingReplies = id
        replyError = nil
        defer { loadingReplies = nil }
        do {
            let replies = try await service.getTaskFeedReplies(entryId: id)
            try Task.checkCancellation()
            if let index = feed.firstIndex(where: { $0.id == id }) { feed[index] = feed[index].withReplies(replies) }
        } catch { if !Task.isCancelled { replyError = "Couldn't load replies. Try again." } }
    }

    private func dateLabel(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

private struct TicketTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    let ticketId: Int
    let task: TdxTicketTask?
    let service: TdxService

    @State private var expected: TdxTicketTask?
    @State private var values = TdxTaskValues()
    @State private var descriptionText = ""
    @State private var originalDescriptionText = ""
    @State private var eligibleTasks: [TdxTicketTask] = []
    @State private var groups: [TdxLookupItem] = []
    @State private var people: [TdxPerson] = []
    @State private var personSearch = ""
    @State private var personName = "Unassigned"
    @State private var isLoading = true
    @State private var isSearching = false
    @State private var isSubmitting = false
    @State private var didAttempt = false
    @State private var errorMessage: String?
    @State private var lookupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task == nil ? "Add Task" : "Edit Task").font(.title2)
            Text("Ticket #\(String(ticketId))").foregroundStyle(.secondary)
            if isLoading { ProgressView("Loading task details…") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Title").fontWeight(.medium)
                        TextField("Task title", text: $values.title)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Description").fontWeight(.medium)
                        TextEditor(text: $descriptionText)
                            .multilineTextAlignment(.leading)
                            .frame(height: 100).border(.quaternary)
                            .accessibilityLabel("Task description")
                    }
                    HStack {
                        Text("Estimated minutes")
                        TextField("Estimated minutes", value: $values.estimatedMinutes, format: .number)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Responsible group").fontWeight(.medium)
                        Picker("Responsible group", selection: $values.responsibleGroupId) {
                            Text("Unassigned").tag(0)
                            if values.responsibleGroupId > 0 && !groups.contains(where: { $0.id == values.responsibleGroupId }) {
                                Text(expected?.responsibleGroupName ?? "Current group").tag(values.responsibleGroupId)
                            }
                            ForEach(groups) { group in Text(group.name).tag(group.id) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Responsible person").fontWeight(.medium)
                        HStack {
                            Text(personName).foregroundStyle(.secondary)
                            Spacer()
                            Button("Assign to me") {
                                values.responsibleUid = service.authenticatedUserId
                                personName = service.authenticatedUserName ?? "Me"
                            }.disabled(service.authenticatedUserId == nil)
                            Button("Clear") { values.responsibleUid = nil; personName = "Unassigned" }
                        }
                        HStack {
                            TextField("Find a person", text: $personSearch)
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                                .onSubmit { Task { await searchPeople() } }
                            Button("Search") { Task { await searchPeople() } }
                                .disabled(personSearch.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearching)
                        }
                        if isSearching { ProgressView().controlSize(.small) }
                        ForEach(people) { person in
                            Button(person.fullName ?? person.primaryEmail ?? "Person") {
                                values.responsibleUid = person.uid
                                personName = person.fullName ?? person.primaryEmail ?? "Person"
                                people = []
                            }.buttonStyle(.link)
                        }
                        if let lookupError { Text(lookupError).font(.caption).foregroundStyle(.red) }
                    }
                    Toggle("Notify responsible when task becomes active", isOn: $values.notifyResponsible)
                        .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Predecessor").fontWeight(.medium)
                        Picker("Predecessor", selection: $values.predecessorId) {
                            Text("None").tag(0)
                            if values.predecessorId > 0 && !eligibleTasks.contains(where: { $0.id == values.predecessorId }) {
                                Text(expected?.predecessorTitle ?? "Current predecessor").tag(values.predecessorId)
                            }
                            ForEach(eligibleTasks.filter { $0.id != task?.id }) { predecessor in
                                Text(predecessor.title).tag(predecessor.id)
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle("Start date", isOn: Binding(get: { values.startDate != nil }, set: { values.startDate = $0 ? Self.iso(Date()) : nil }))
                        .toggleStyle(.checkbox)
                    if values.startDate != nil {
                        DatePicker("Starts", selection: Binding(get: { Self.date(values.startDate) }, set: { values.startDate = Self.iso($0) }))
                    }
                    Toggle("Due date", isOn: Binding(get: { values.endDate != nil }, set: { values.endDate = $0 ? Self.iso(Date()) : nil }))
                        .toggleStyle(.checkbox)
                    if values.endDate != nil {
                        DatePicker("Due", selection: Binding(get: { Self.date(values.endDate) }, set: { values.endDate = Self.iso($0) }))
                    }
                    Toggle("Expected operational duration", isOn: Binding(get: { values.completeWithinMinutes != nil }, set: { values.completeWithinMinutes = $0 ? 60 : nil }))
                        .toggleStyle(.checkbox)
                    if values.completeWithinMinutes != nil {
                        HStack {
                            Text("Operational minutes")
                            TextField("Operational minutes", value: Binding(get: { values.completeWithinMinutes ?? 0 }, set: { values.completeWithinMinutes = $0 }), format: .number)
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(width: 100)
                        }
                    }
                }.padding(2).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 520).disabled(isLoading || didAttempt)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(didAttempt ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(task == nil ? "Create Task" : "Save Task") { Task { await submit() } }
                    .disabled(isLoading || isSubmitting || didAttempt || values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isSubmitting { ProgressView("Saving task…").controlSize(.small) }
        }.padding(24).frame(width: 650)
            .interactiveDismissDisabled(isSubmitting)
            .task { await load() }
    }

    @MainActor private func load() async {
        defer { isLoading = false }
        do {
            if let task {
                let current = try await service.getTicketTask(ticketId: ticketId, taskId: task.id)
                try Task.checkCancellation()
                guard current.isStandard else { throw TdxWorkflowError.actionFailed("Only standard tasks can be edited here.") }
                expected = current
                values = current.editableValues
                personName = current.responsibleFullName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unassigned"
            }
            descriptionText = HtmlToMarkdown.convert(values.description ?? "")
            originalDescriptionText = descriptionText
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription; didAttempt = true }
        }
        do {
            let eligible = try await service.getTicketTasks(ticketId: ticketId, eligiblePredecessorsOnly: true)
            try Task.checkCancellation()
            eligibleTasks = eligible
        } catch { if !Task.isCancelled { lookupError = "Couldn't load eligible predecessors. Existing dependencies are preserved." } }
        do {
            let loaded = try await service.getTaskGroups()
            try Task.checkCancellation()
            groups = loaded
        } catch { if !Task.isCancelled { lookupError = "Couldn't load groups. Existing assignments are preserved." } }
    }

    @MainActor private func searchPeople() async {
        let query = personSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !isSearching else { return }
        isSearching = true
        lookupError = nil
        defer { isSearching = false }
        do {
            let found = try await service.searchTaskPeople(searchText: query)
            try Task.checkCancellation()
            guard personSearch.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            people = found.filter { $0.uid != nil }
            if people.isEmpty { lookupError = "No matching people." }
        } catch { if !Task.isCancelled { lookupError = "Couldn't search people. Try again." } }
    }

    @MainActor private func submit() async {
        guard !isSubmitting, !didAttempt else { return }
        if descriptionText != originalDescriptionText { values.description = descriptionText }
        do { try values.validate() }
        catch { errorMessage = error.localizedDescription; return }
        isSubmitting = true
        didAttempt = true
        defer { isSubmitting = false }
        do {
            if let expected { _ = try await service.editTicketTask(ticketId: ticketId, expected: expected, values: values) }
            else { _ = try await service.createTicketTask(ticketId: ticketId, values: values) }
            dismiss()
        } catch { errorMessage = error.localizedDescription + " Close to refresh before trying again." }
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func date(_ raw: String?) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return raw.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? Date()
    }
}

private struct TicketTaskTemplateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ticketId: Int
    let service: TdxService
    let config: FleetMateConfig

    @State private var choices: [TdxWorkflowChoice] = []
    @State private var selectedId: Int?
    @State private var removeExisting = false
    @State private var startDateSource = 0
    @State private var confirmedRemoval = false
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var didAttempt = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply Task Template").font(.title2)
            Text("Ticket #\(String(ticketId))").foregroundStyle(.secondary)
            if isLoading { ProgressView("Loading available task templates…") }
            Picker("Task template", selection: $selectedId) {
                Text("Choose a template").tag(nil as Int?)
                ForEach(choices) { choice in Text(choice.name).tag(Optional(choice.id)) }
            }.disabled(didAttempt)
            Picker("Start dates", selection: $startDateSource) {
                Text("Current date and time").tag(0)
                Text("Ticket created date").tag(1)
                Text("Ticket start date").tag(2)
            }.disabled(didAttempt)
            Toggle("Remove existing tasks", isOn: $removeExisting).disabled(didAttempt)
            if removeExisting {
                Text("Existing tasks may be permanently deleted. This cannot be undone. TeamDynamix will keep them if you don't have permission to delete tasks.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("I understand that existing tasks may be permanently deleted", isOn: $confirmedRemoval)
                    .disabled(didAttempt)
            }
            Text("Applying a template can create tasks and send notifications. Review your selection before applying it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if choices.isEmpty && !isLoading && errorMessage == nil {
                Text("No task templates are available.").foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(didAttempt ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Apply Template") { Task { await submit() } }
                    .disabled(isLoading || isSubmitting || didAttempt || selectedId == nil || (removeExisting && !confirmedRemoval))
            }
            if isSubmitting { ProgressView("Applying task template…").controlSize(.small) }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(isSubmitting)
            .task { await load() }
    }

    @MainActor private func load() async {
        defer { isLoading = false }
        do {
            guard service.actingIdentityIsUser else { throw TdxAuthError.notAuthenticated }
            let loader = TicketWorkflowCatalog()
            choices = try await loader.load(ticketId: ticketId, config: config, taskTemplates: true)
            try Task.checkCancellation()
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    @MainActor private func submit() async {
        guard !didAttempt, !isSubmitting, let selectedId, !removeExisting || confirmedRemoval else { return }
        isSubmitting = true
        didAttempt = true
        defer { isSubmitting = false }
        do {
            let loader = TicketWorkflowCatalog()
            let latest = try await loader.load(ticketId: ticketId, config: config, taskTemplates: true)
            guard latest.contains(where: { $0.id == selectedId }) else {
                throw TdxWorkflowError.actionFailed("This template is no longer available. Close and choose again.")
            }
            _ = try await service.applyTaskTemplate(ticketId: ticketId,
                request: .init(taskTemplateId: selectedId, removeExistingTasks: removeExisting, startDateSource: startDateSource))
            dismiss()
        } catch { errorMessage = error.localizedDescription + " Close to refresh before trying again." }
    }
}
