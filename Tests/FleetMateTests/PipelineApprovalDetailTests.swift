import XCTest
@testable import FleetMateCore

/// Waiting approvals on a pipeline run. Every request goes to the stub
/// protocol; nothing here reaches a real organisation.
final class PipelineApprovalDetailTests: XCTestCase {

    private func makeService() -> AzureDevOpsService {
        var config = FleetMateConfig()
        config.devopsOrganization = "example-org"
        let service = AzureDevOpsService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
        service.setBearerToken("stub-token", expiry: Date().addingTimeInterval(3600))
        return service
    }

    private let started = Date(timeIntervalSince1970: 1_700_000_000)

    private func manual(settings: ManualValidationSettings? = nil) -> PipelineApproval {
        PipelineApproval(
            id: "a1", project: "Demo", buildId: 7, instructions: "Check the plan.", createdOn: started,
            approvers: ["Ops Team"], kind: .manualValidation, stageName: "Deploy", stepName: "Approve release",
            startedAt: started, settings: settings
        )
    }

    func testKindFollowsWhetherTheApprovalNamesABuild() {
        XCTAssertEqual(PipelineApproval(id: "x", project: "p", buildId: nil, instructions: "", createdOn: nil, approvers: []).kind, .manualValidation)
        XCTAssertEqual(PipelineApproval(id: "x", project: "p", buildId: 3, instructions: "", createdOn: nil, approvers: []).kind, .environment)
    }

    func testVerbsAndConfirmationNameRunStageAndAction() {
        let approval = manual()
        XCTAssertEqual(approval.approveVerb, "Resume")
        XCTAssertEqual(approval.confirmationTitle(approve: true, runName: "Build 7"), "Resume \u{201C}Approve release\u{201D} in stage Deploy of Build 7?")
        XCTAssertEqual(approval.confirmationTitle(approve: false, runName: "Build 7"), "Reject \u{201C}Approve release\u{201D} in stage Deploy of Build 7?")
        let env = PipelineApproval(id: "e", project: "p", buildId: 1, instructions: "", createdOn: nil, approvers: [])
        XCTAssertEqual(env.approveVerb, "Approve")
        XCTAssertEqual(env.confirmationTitle(approve: true, runName: "Build 1"), "Approve Build 1?")
    }

    func testWaitingAndTimeout() {
        let approval = manual(settings: ManualValidationSettings(instructions: nil, timeoutMinutes: 1440, onTimeout: .resume))
        let now = started.addingTimeInterval(3 * 3600 + 5 * 60)
        XCTAssertEqual(approval.waitingDuration(now: now), 3 * 3600 + 5 * 60)
        XCTAssertEqual(approval.deadline, started.addingTimeInterval(86_400))
        XCTAssertEqual(approval.timeoutSummary(now: now), "Times out in 20h 55m; then the run resumes.")
        XCTAssertEqual(approval.timeoutSummary(now: started.addingTimeInterval(90_000)), "Timed out; the run resumes.")
        XCTAssertNil(manual().timeoutSummary(now: now))
    }

    func testManualValidationSettingsComeFromTheFinalYaml() {
        let yaml = """
        stages:
        - stage: Deploy
          jobs:
          - job: wait
            pool: server
            steps:
            - task: ManualValidation@0
              timeoutInMinutes: 1440
              inputs:
                notifyUsers: ops@example.test
                instructions: Check the plan.
                onTimeout: resume
            - task: ManualValidation@0
              inputs:
                instructions: Second
        """
        let found = AzureDevOpsService.manualValidationSettings(inYaml: yaml)
        XCTAssertEqual(found, [
            ManualValidationSettings(instructions: "Check the plan.", timeoutMinutes: 1440, onTimeout: .resume),
            ManualValidationSettings(instructions: "Second", timeoutMinutes: nil, onTimeout: .reject),
        ])
    }

    func testPendingApprovalsReadInstructionsApproversAndQuorum() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/pipelines/approvals", method: "GET", body: """
        {"value":[{"id":"a1","status":"pending","instructions":"Check the plan.","createdOn":"2026-01-01T10:00:00Z",
        "minRequiredApprovers":2,"steps":[{"assignedApprover":{"displayName":"Ops Team"}}]}]}
        """)])
        let approvals = try await makeService().getPendingApprovals(project: "Demo")
        XCTAssertEqual(approvals.first?.kind, .manualValidation)
        XCTAssertEqual(approvals.first?.approvers, ["Ops Team"])
        XCTAssertEqual(approvals.first?.minRequiredApprovers, 2)
        XCTAssertEqual(approvals.first?.instructions, "Check the plan.")
    }

    func testTimelinePlaceFindsStepStageAndStart() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/timeline", body: """
        {"records":[
         {"id":"s1","type":"Stage","name":"Deploy","state":"inProgress"},
         {"id":"j1","parentId":"s1","type":"Job","name":"wait","state":"inProgress"},
         {"id":"t1","parentId":"j1","type":"Task","name":"Approve release","state":"inProgress","identifier":"A1","startTime":"2026-01-01T10:00:00Z"}]}
        """)])
        let places = try await makeService().getApprovalPlaces(project: "Demo", buildId: 7)
        XCTAssertEqual(places["a1"]?.stepName, "Approve release")
        XCTAssertEqual(places["a1"]?.stageName, "Deploy")
        XCTAssertNotNil(places["a1"]?.startedAt)
    }

    func testPreviewIsReadOnlyAndParsesTheTimeout() async throws {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/preview", method: "POST", body: """
        {"finalYaml":"steps:\\n- task: ManualValidation@0\\n  timeoutInMinutes: 60\\n  inputs:\\n    onTimeout: resume\\n"}
        """)])
        let found = try await makeService().getManualValidationSettings(project: "Demo", pipelineId: 12, branch: "main")
        XCTAssertEqual(found.first?.timeoutMinutes, 60)
        XCTAssertEqual(found.first?.onTimeout, .resume)
        let call = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(call.jsonObject?["previewRun"] as? Bool, true)
        XCTAssertTrue(call.path.hasSuffix("/pipelines/12/preview"))
    }

    func testResumeAndRejectPatchTheApprovalsEndpointWithTheComment() async throws {
        for (approve, status) in [(true, "approved"), (false, "rejected")] {
            StubURLProtocol.reset(stubs: [.init(pathContains: "/pipelines/approvals", method: "PATCH", body: """
            {"value":[{"id":"a1","status":"\(status)"}]}
            """)])
            try await makeService().respondToApproval(project: "Demo", approvalId: "a1", approve: approve, comment: "Looks right")
            let call = try XCTUnwrap(StubURLProtocol.recorded.first)
            XCTAssertEqual(call.method, "PATCH")
            XCTAssertTrue(call.path.hasSuffix("/_apis/pipelines/approvals"))
            XCTAssertEqual(call.query?.contains("api-version=7.1"), true)
            XCTAssertEqual(call.jsonArray?.first?["approvalId"] as? String, "a1")
            XCTAssertEqual(call.jsonArray?.first?["status"] as? String, status)
            XCTAssertEqual(call.jsonArray?.first?["comment"] as? String, "Looks right")
        }
    }

    func testAnApprovalThatStaysPendingIsReportedAsRefused() async {
        StubURLProtocol.reset(stubs: [.init(pathContains: "/pipelines/approvals", method: "PATCH", body: #"{"value":[{"id":"a1","status":"pending"}]}"#)])
        do {
            try await makeService().respondToApproval(project: "Demo", approvalId: "a1", approve: true, comment: "")
            XCTFail("expected a refusal")
        } catch {}
    }
}
