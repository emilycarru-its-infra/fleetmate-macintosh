import SwiftUI
import FleetMateCore

/// A waiting approval laid out as the Azure DevOps web page does: what the
/// step asks, who may answer, how long it has waited, when it gives up and
/// what happens then, then the two verbs with an optional comment. Both verbs
/// write to a live pipeline, so each asks first and names the run, the stage
/// and the action.
struct ApprovalCard: View {
    let approval: PipelineApproval
    let run: PipelineRun
    /// Sends the answer. Throws when Azure DevOps refuses it.
    let respond: (_ approve: Bool, _ comment: String) async throws -> Void
    /// Fixed clock for snapshots; nil follows real time.
    var now: Date?
    /// Open the verb's confirmation straight away; snapshots use it.
    var initialConfirmation: Bool?

    @State private var comment = ""
    @State private var working: Bool?
    @State private var error: String?
    @State private var confirming: Bool?

    private var runName: String { "\(run.pipelineName) \(run.runNumber)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(approval.kindTitle).appFont(.callout, weight: .semibold)
                Text("Waiting for you").appFont(.caption).foregroundStyle(.secondary)
            }

            instructions

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    label("Who can answer")
                    Text(approversText).appFont(.callout).textSelection(.enabled)
                }
                GridRow {
                    label("Waiting")
                    waiting
                }
                if let timeout = timeoutText {
                    GridRow {
                        label("Timeout")
                        Text(timeout).appFont(.callout)
                    }
                }
            }

            TextField("Comment (optional)", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Comment, optional")

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(role: .destructive) { confirming = false } label: {
                    if working == false { ProgressView().controlSize(.small) } else { Text(approval.rejectVerb) }
                }
                .help("\(approval.rejectVerb) this step; the run stops")
                Button { confirming = true } label: {
                    if working == true { ProgressView().controlSize(.small) } else { Text(approval.approveVerb) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(approval.approveVerb) (\u{2318}\u{21A9})")
            }
            .disabled(working != nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            approval.confirmationTitle(approve: confirming ?? true, runName: runName),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            let approve = confirming ?? true
            Button(approve ? approval.approveVerb : approval.rejectVerb, role: approve ? nil : .destructive) { send(approve) }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text(approval.confirmationMessage(approve: confirming ?? true))
        }
        .onAppear { if let initialConfirmation { confirming = initialConfirmation } }
    }

    private var instructions: some View {
        Text(approval.instructions.isEmpty ? "No instructions given." : approval.instructions)
            .appFont(.callout)
            .foregroundStyle(approval.instructions.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    @ViewBuilder
    private var waiting: some View {
        if let since = approval.waitingSince {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let clock = now ?? context.date
                let length = approval.waitingDuration(now: clock).map(PipelineApproval.format) ?? ""
                Text("\(length) \u{2014} since \(since.formatted(date: .abbreviated, time: .shortened))")
                    .appFont(.callout)
                    .monospacedDigit()
            }
        } else {
            Text("Not reported").appFont(.callout).foregroundStyle(.secondary)
        }
    }

    private var timeoutText: String? {
        guard let summary = approval.timeoutSummary(now: now ?? Date()), let deadline = approval.deadline else { return nil }
        return "\(summary) (\(deadline.formatted(date: .abbreviated, time: .shortened)))"
    }

    private var approversText: String {
        if approval.approvers.isEmpty { return "Not reported" }
        let names = approval.approvers.joined(separator: ", ")
        if let needed = approval.minRequiredApprovers, needed > 1 { return "\(names) (\(needed) must agree)" }
        return names
    }

    private func label(_ text: String) -> some View {
        Text(text).appFont(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func send(_ approve: Bool) {
        working = approve
        error = nil
        Task {
            defer { working = nil }
            do {
                try await respond(approve, comment)
                comment = ""
            } catch {
                self.error = "Could not \(approve ? approval.approveVerb.lowercased() : approval.rejectVerb.lowercased()): \(error.localizedDescription)"
            }
        }
    }
}
