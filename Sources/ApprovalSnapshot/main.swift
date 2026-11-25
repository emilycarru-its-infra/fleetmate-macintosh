import AppKit
import SwiftUI
import FleetMateCore

// Renders the approval card offscreen with made-up fixture data and writes
// PNGs. It opens no window and calls no network endpoint.
// Usage: ApprovalSnapshot <output-directory>

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
_ = NSApplication.shared

let clock = Date(timeIntervalSince1970: 1_790_000_000)

let run = PipelineRun(
    source: .azureDevOps, container: "Demo Project", repository: "demo-service", pipelineName: "Demo Infrastructure",
    pipelineId: 12, runId: 1234, runNumber: "20260101.1", status: .running, branch: "main", commitSha: nil,
    triggeredBy: "Sample User", startedAt: clock.addingTimeInterval(-9000), finishedAt: nil, webUrl: "https://example.test"
)

let manualValidation = PipelineApproval(
    id: "11111111-aaaa-bbbb-cccc-000000000001", project: "Demo Project", buildId: 1234,
    instructions: "Review the Terraform plan in the previous step. Resume only if no resources are destroyed.",
    createdOn: clock.addingTimeInterval(-8100), approvers: ["Platform Team", "Sample User"],
    kind: .manualValidation, stageName: "Apply", stepName: "Approve the plan", startedAt: clock.addingTimeInterval(-8100),
    settings: ManualValidationSettings(instructions: nil, timeoutMinutes: 1440, onTimeout: .reject)
)

let environment = PipelineApproval(
    id: "11111111-aaaa-bbbb-cccc-000000000002", project: "Demo Project", buildId: 1234,
    instructions: "Production deployment. Confirm the change window is open.",
    createdOn: clock.addingTimeInterval(-1500), approvers: ["Release Managers"],
    kind: .environment, minRequiredApprovers: 2, stageName: "Deploy", stepName: "Production"
)

struct StepFrame<Content: View>: View {
    let name: String
    let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(90)).foregroundStyle(.secondary)
                Image(systemName: "circle.dotted.circle").foregroundStyle(.yellow)
                Text(name).appFont(.callout, weight: .medium)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            content.padding(10)
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

@MainActor func render<V: View>(_ view: V, name: String, dark: Bool) {
    let host = NSHostingView(rootView: view.padding(14).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let url = outputDirectory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try? png.write(to: url)
    print(url.path)
}

MainActor.assumeIsolated {
    for dark in [false, true] {
        render(
            StepFrame(name: "Approve the plan", content: ApprovalCard(approval: manualValidation, run: run, respond: { _, _ in }, now: clock)),
            name: "manual-validation", dark: dark
        )
        render(
            ApprovalCard(approval: environment, run: run, respond: { _, _ in }, now: clock),
            name: "environment-approval", dark: dark
        )
    }
    render(
        ApprovalCard(approval: manualValidation, run: run, respond: { _, _ in }, now: clock, initialConfirmation: true),
        name: "manual-validation-confirm", dark: false
    )
}
