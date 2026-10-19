import SwiftUI
import FleetMateCore

/// The parent gives each ticket its own identity so drafts and delayed responses
/// cannot carry over when the selection changes.
struct TicketWorkflowView: View {
    @EnvironmentObject private var appState: AppState
    let ticketId: Int
    let service: TdxService
    let refreshToken: Int
    let onActionCompleted: () -> Void

    @State private var workflow: TdxWorkflow?
    @State private var actions: [UUID: [TdxWorkflowAction]] = [:]
    @State private var actionErrors: [UUID: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedAction: WorkflowActionSelection?
    @State private var reloadToken = 0
    @State private var isExpanded = false
    @State private var management: WorkflowManagementSelection?
    @State private var runningStep: UUID?
    @State private var stepFailures: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("Workflow").font(.headline)
                        if let workflow { Text(workflow.name ?? "").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Hide workflow" : "Show workflow")
                Spacer()
                Button("Restart Workflow…") {
                    if let workflow { management = .init(expected: workflow, isRestart: true) }
                }
                .disabled(workflow?.workflowConfigurationId.map { $0 > 0 } != true || isLoading || selectedAction != nil || management != nil)
                Button(workflow == nil ? "Assign Workflow…" : "Change Workflow…") {
                    management = .init(expected: workflow, isRestart: false)
                }
                .disabled(isLoading || errorMessage != nil || selectedAction != nil || management != nil)
                Button("Refresh", systemImage: "arrow.clockwise") { reloadToken += 1 }
                    .labelStyle(.iconOnly)
                    .help("Refresh workflow")
                    .disabled(isLoading || selectedAction != nil || management != nil || runningStep != nil)
            }

            if isExpanded {
            if isLoading {
                ProgressView("Loading workflow…").controlSize(.small)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let workflow {
                HStack(alignment: .firstTextBaseline) {
                    Text(workflow.name ?? "Ticket workflow").fontWeight(.medium)
                    Spacer()
                    Text(workflow.statusLabel).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                if workflow.activeSteps.isEmpty && !workflow.isComplete {
                    Text("No steps are currently active.").foregroundStyle(.secondary)
                }
                ForEach(workflow.activeSteps) { step in
                    WorkflowStepView(
                        step: step,
                        actions: actions[step.id] ?? [],
                        errorMessage: actionErrors[step.id],
                        failureMessage: stepFailures[step.id],
                        isRunning: runningStep == step.id,
                        isLocked: runningStep != nil || stepFailures[step.id] != nil,
                        perform: { action in
                            Task { await perform(action, on: step) }
                        },
                        performWithComment: { action in
                            selectedAction = WorkflowActionSelection(step: step, action: action)
                        })
                }
            } else {
                Text("No workflow assigned.").foregroundStyle(.secondary)
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Restart Workflow…") {
                if let workflow { management = .init(expected: workflow, isRestart: true) }
            }.disabled(workflow?.workflowConfigurationId.map { $0 > 0 } != true || isLoading || selectedAction != nil || management != nil)
            Button(workflow == nil ? "Assign Workflow…" : "Change Workflow…") {
                management = .init(expected: workflow, isRestart: false)
            }.disabled(isLoading || errorMessage != nil || selectedAction != nil || management != nil)
        }
        .sheet(item: $management, onDismiss: {
            isLoading = true
            reloadToken += 1
            onActionCompleted()
        }) { selection in
            WorkflowManagementSheet(ticketId: ticketId, selection: selection,
                                    service: service, config: appState.config) {
            }
        }
        .task(id: "\(refreshToken)-\(reloadToken)") { await loadWorkflow() }
        .sheet(item: $selectedAction, onDismiss: {
            // Also refresh after an uncertain failure before offering actions again.
            isLoading = true
            reloadToken += 1
            onActionCompleted()
        }) { selection in
            WorkflowActionSheet(ticketId: ticketId, selection: selection, service: service) {
            }
        }
    }

    @MainActor
    private func loadWorkflow() async {
        isLoading = true
        workflow = nil
        actions = [:]
        actionErrors = [:]
        errorMessage = nil
        stepFailures = [:]
        defer { isLoading = false }
        do {
            let loaded = try await service.getWorkflow(ticketId: ticketId)
            try Task.checkCancellation()
            workflow = loaded
            for step in loaded?.activeSteps ?? [] {
                do {
                    let available = try await service.getWorkflowActions(ticketId: ticketId, stepId: step.id)
                    try Task.checkCancellation()
                    actions[step.id] = available
                } catch {
                    try Task.checkCancellation()
                    actionErrors[step.id] = error.localizedDescription
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// One click runs the action with no comment, as most steps need none.
    @MainActor
    private func perform(_ action: TdxWorkflowAction, on step: TdxWorkflowStep) async {
        guard runningStep == nil, stepFailures[step.id] == nil else { return }
        runningStep = step.id
        defer { runningStep = nil }
        do {
            _ = try await service.performWorkflowAction(ticketId: ticketId, request: TdxWorkflowActionRequest(
                stepId: step.id, actionId: action.id, comments: nil))
            isLoading = true
            reloadToken += 1
            onActionCompleted()
        } catch {
            // A timeout may follow a committed action, so the step stays locked
            // until the workflow is refreshed and its real state is shown.
            stepFailures[step.id] = "\(action.label) failed: \(error.localizedDescription) Refresh the workflow before trying again."
        }
    }
}

private struct WorkflowStepView: View {
    let step: TdxWorkflowStep
    let actions: [TdxWorkflowAction]
    let errorMessage: String?
    let failureMessage: String?
    let isRunning: Bool
    let isLocked: Bool
    let perform: (TdxWorkflowAction) -> Void
    let performWithComment: (TdxWorkflowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.name ?? "Workflow step").fontWeight(.medium)
                .textSelection(.enabled)
            if let typeName = step.typeName {
                Text(typeName).font(.caption).foregroundStyle(.secondary)
            }
            if let description = step.description, !description.isEmpty {
                Text(description).textSelection(.enabled)
            }
            if step.isInError {
                Label("This step needs attention.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text("Couldn't load actions: \(errorMessage)")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            } else if actions.isEmpty {
                Text("No actions are available to you for this step.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            actionButtons
                        }
                        VStack(alignment: .leading) {
                            actionButtons
                        }
                    }
                    if isRunning { ProgressView().controlSize(.small) }
                }
            }
            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .contextMenu {
            ForEach(actions) { action in
                Button(action.label) { perform(action) }
                Button("\(action.label) with Comment…") { performWithComment(action) }
            }
            .disabled(isLocked)
        }
    }

    private var actionButtons: some View {
        ForEach(actions) { action in
            Button(action.label) { perform(action) }
                .help("\(action.tooltip ?? action.label). Right-click to add a comment.")
                .disabled(isLocked)
        }
    }
}

private struct WorkflowActionSelection: Identifiable {
    let id = UUID()
    let step: TdxWorkflowStep
    let action: TdxWorkflowAction
}

private struct WorkflowActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ticketId: Int
    let selection: WorkflowActionSelection
    let service: TdxService
    let onCompleted: () -> Void

    @State private var didFail = false
    @State private var comments = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selection.action.label).font(.title2)
            Text("Ticket #\(String(ticketId)) · \(selection.step.name ?? "Workflow step")")
                .textSelection(.enabled)
            if let tooltip = selection.action.tooltip, !tooltip.isEmpty {
                Text(tooltip).foregroundStyle(.secondary)
            }
            Text("This action will be recorded in the ticket's activity.")
                .foregroundStyle(.secondary)
            Text("Comments (optional)").font(.headline)
            TextEditor(text: $comments)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 180)
                .border(.separator)
                .accessibilityLabel("Workflow action comments")
                .disabled(isSubmitting)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Confirm \(selection.action.label)") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || didFail)
            }
        }
        .padding(20)
        .frame(width: 450)
        .interactiveDismissDisabled(isSubmitting)
    }

    @MainActor
    private func submit() async {
        guard !isSubmitting && !didFail else { return }
        isSubmitting = true
        errorMessage = nil
        // A network timeout may follow a committed action. Keep the sheet from
        // blindly resubmitting; the user can cancel and refresh to inspect it.
        do {
            let comment = comments.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await service.performWorkflowAction(ticketId: ticketId, request: TdxWorkflowActionRequest(
                stepId: selection.step.id, actionId: selection.action.id,
                comments: comment.isEmpty ? nil : comment))
            onCompleted()
            dismiss()
        } catch {
            errorMessage = "\(error.localizedDescription) Close this dialog and refresh the workflow before trying again."
            // The Confirm button remains disabled until the dialog is reopened.
            // Cancel must still work so the user can inspect the current state.
            isSubmitting = false
            didFail = true
        }
    }

}

private struct WorkflowManagementSelection: Identifiable {
    let id = UUID()
    let expected: TdxWorkflow?
    let isRestart: Bool
}

private struct WorkflowManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let ticketId: Int
    let selection: WorkflowManagementSelection
    let service: TdxService
    let config: FleetMateConfig
    let onCompleted: () -> Void

    @State private var choices: [TdxWorkflowChoice] = []
    @State private var selectedId: Int?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var didAttempt = false
    @State private var errorMessage: String?

    private var title: String {
        selection.isRestart ? "Restart Workflow" : (selection.expected == nil ? "Assign Workflow" : "Change Workflow")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            Text("Ticket #\(String(ticketId))").textSelection(.enabled)
            if let expected = selection.expected {
                Text("Current workflow: \(expected.name ?? "Ticket workflow")")
            }
            if isLoading {
                ProgressView("Loading available workflows…")
            } else if selection.isRestart {
                Text("Restart \(selection.expected?.name ?? "this workflow") from the beginning?")
            } else {
                Picker("New workflow", selection: $selectedId) {
                    Text("Choose a workflow").tag(nil as Int?)
                    ForEach(choices) { choice in Text(choice.name).tag(Optional(choice.id)) }
                }.disabled(didAttempt)
                if choices.isEmpty && errorMessage == nil {
                    Text("No workflows are available to assign.").foregroundStyle(.secondary)
                }
            }
            Text(selection.expected == nil
                 ? "Applying this workflow may create tasks, send notifications, and run automation."
                 : "This removes the current workflow and its incomplete workflow tasks. Progress will reset, and notifications, tasks, and automation may run again.")
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(didAttempt ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(title) { Task { await submit() } }
                    .disabled(isLoading || isSubmitting || selectedId == nil || didAttempt)
            }
            if isSubmitting { ProgressView("Updating workflow…").controlSize(.small) }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(isSubmitting)
        .task { await loadChoices() }
    }

    @MainActor private func loadChoices() async {
        defer { isLoading = false }
        do {
            guard service.actingIdentityIsUser else { throw TdxAuthError.notAuthenticated }
            let loader = TicketWorkflowCatalog()
            choices = try await loader.load(ticketId: ticketId, config: config)
            if !selection.isRestart { choices.removeAll { $0.id == selection.expected?.workflowConfigurationId } }
            try Task.checkCancellation()
            if selection.isRestart {
                guard let id = selection.expected?.workflowConfigurationId,
                      choices.contains(where: { $0.id == id }) else {
                    throw TdxWorkflowError.actionFailed("This workflow is no longer available to restart.")
                }
                selectedId = id
            }
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    @MainActor private func submit() async {
        guard !isSubmitting, !didAttempt, let selectedId else { return }
        isSubmitting = true
        didAttempt = true
        defer { isSubmitting = false }
        do {
            let loader = TicketWorkflowCatalog()
            let currentChoices = try await loader.load(ticketId: ticketId, config: config)
            guard currentChoices.contains(where: { $0.id == selectedId }) else {
                throw TdxWorkflowError.actionFailed("The selected workflow is no longer available. Close this window and choose again.")
            }
            try await service.assignWorkflow(ticketId: ticketId, definitionId: selectedId, expected: selection.expected)
            onCompleted()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription + " Close this window to refresh before trying again."
        }
    }
}
