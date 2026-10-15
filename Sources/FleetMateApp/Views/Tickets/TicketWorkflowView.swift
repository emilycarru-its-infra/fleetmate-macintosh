import SwiftUI
import FleetMateCore

/// The parent gives each ticket its own identity so drafts and delayed responses
/// cannot carry over when the selection changes.
struct TicketWorkflowView: View {
    let ticketId: Int
    let service: TdxService
    let onActionCompleted: () -> Void

    @State private var workflow: TdxWorkflow?
    @State private var actions: [UUID: [TdxWorkflowAction]] = [:]
    @State private var actionErrors: [UUID: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedAction: WorkflowActionSelection?
    @State private var reloadToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Workflow", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { reloadToken += 1 }
                    .labelStyle(.iconOnly)
                    .help("Refresh workflow")
                    .disabled(isLoading || selectedAction != nil)
            }

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
                        selectAction: { action in
                            selectedAction = WorkflowActionSelection(step: step, action: action)
                        })
                }
            } else {
                Text("No workflow assigned.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadToken) { await loadWorkflow() }
        .sheet(item: $selectedAction) { selection in
            WorkflowActionSheet(ticketId: ticketId, selection: selection, service: service) {
                onActionCompleted()
                reloadToken += 1
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
}

private struct WorkflowStepView: View {
    let step: TdxWorkflowStep
    let actions: [TdxWorkflowAction]
    let errorMessage: String?
    let selectAction: (TdxWorkflowAction) -> Void

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
                ViewThatFits(in: .horizontal) {
                    HStack {
                        actionButtons
                    }
                    VStack(alignment: .leading) {
                        actionButtons
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .contextMenu {
            ForEach(actions) { action in
                Button(action.label) { selectAction(action) }
            }
        }
    }

    private var actionButtons: some View {
        ForEach(actions) { action in
            Button(action.label) { selectAction(action) }
                .help(action.tooltip ?? action.label)
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
            Text("Ticket #\(ticketId) · \(selection.step.name ?? "Workflow step")")
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
