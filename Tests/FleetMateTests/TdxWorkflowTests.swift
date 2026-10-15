import XCTest
@testable import FleetMateCore

/// Workflow contracts are pinned to the vendor OpenAPI, with synthetic fixtures.
final class TdxWorkflowTests: XCTestCase {
    private let stepId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherStepId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func service(body: String, status: Int = 200) -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxAppId = 99
        config.tdxTicketingAppId = 115
        config.tdxAuthMethod = .browserSSO
        StubURLProtocol.reset(stubs: [
            .init(pathContains: "/workflow", statusCode: status, body: body)
        ])
        let service = TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
        service.setSsoToken("eyJ.synthetic.user", expiry: .distantFuture)
        return service
    }

    func testWorkflowCallsRequireUserSessionWithoutServiceAccountFallback() async throws {
        let service = service(body: "null")
        service.clearSsoToken()
        do {
            _ = try await service.getWorkflow(ticketId: 42)
            XCTFail("A workflow must use the signed-in user")
        } catch is TdxAuthError { }
        do {
            _ = try await service.getWorkflowActions(ticketId: 42, stepId: stepId)
            XCTFail("Actions must use the signed-in user")
        } catch is TdxAuthError { }
        do {
            _ = try await service.performWorkflowAction(ticketId: 42, request: .init(stepId: stepId, actionId: "complete"))
            XCTFail("Writes must use the signed-in user")
        } catch is TdxAuthError { }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testWorkflowReadUsesTicketingAppAndIncludesParallelSteps() async throws {
        let body = """
        {"ID":12,"Name":"Review","IsComplete":false,"Status":0,
        "CurrentStepIDs":["\(otherStepId)"],"Steps":[
          {"ID":"\(stepId)","Name":"First review","TypeName":"Approval","IsCurrent":true,"IsInError":false},
          {"ID":"\(otherStepId)","Name":"Second review","IsCurrent":false,"IsInError":true},
          {"ID":"33333333-3333-3333-3333-333333333333","Name":"Later","IsCurrent":false,"IsInError":false}]}
        """
        let loaded = try await service(body: body).getWorkflow(ticketId: 42)
        let workflow = try XCTUnwrap(loaded)
        XCTAssertEqual(workflow.activeSteps.map(\.id), [stepId, otherStepId])
        XCTAssertEqual(workflow.statusLabel, "In progress")
        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/TDWebApi/api/115/tickets/42/workflow")
        XCTAssertEqual(call.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer eyJ.synthetic.user")
    }

    func testNullWorkflowMeansUnassigned() async throws {
        let workflow = try await service(body: "null").getWorkflow(ticketId: 42)
        XCTAssertNil(workflow)
    }

    func testCompletedWorkflowOffersNoActiveStepsEvenWithOldCurrentFlags() throws {
        let data = Data("""
        {"ID":12,"Name":"Review","IsComplete":true,"Status":1,"Steps":[
        {"ID":"\(stepId)","IsCurrent":true,"IsInError":false}]}
        """.utf8)
        let workflow = try JSONDecoder().decode(TdxWorkflow.self, from: data)
        XCTAssertTrue(workflow.activeSteps.isEmpty)
        XCTAssertEqual(workflow.statusLabel, "Approved")
    }

    func testActionsRequireStepIdQueryAndPreserveOpaqueIds() async throws {
        let actions = try await service(body: #"[{"ID":"choice:yes/next","Name":"Proceed","Tooltip":"Continue review"}]"#)
            .getWorkflowActions(ticketId: 42, stepId: stepId)
        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/TDWebApi/api/115/tickets/42/workflow/actions")
        let query = URLComponents(url: call.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "stepId", value: stepId.uuidString)])
        XCTAssertEqual(actions.first?.id, "choice:yes/next")
        XCTAssertEqual(actions.first?.tooltip, "Continue review")
    }

    func testNullAndEmptyActionsAreReadOnly() async throws {
        let empty = try await service(body: "[]").getWorkflowActions(ticketId: 42, stepId: stepId)
        XCTAssertTrue(empty.isEmpty)
        let null = try await service(body: "null").getWorkflowActions(ticketId: 42, stepId: stepId)
        XCTAssertTrue(null.isEmpty)
    }

    func testActionPostsExactRequestWithCommentsAndChecksBusinessSuccess() async throws {
        let result = try await service(body: #"{"IsSuccessful":true,"WasWorkflowUpdated":false,"Message":"Vote recorded"}"#)
            .performWorkflowAction(ticketId: 42, request: .init(stepId: stepId, actionId: "choice:yes/next", comments: "Reviewed"))
        XCTAssertTrue(result.isSuccessful)
        XCTAssertFalse(result.wasWorkflowUpdated) // A vote need not complete the step.
        let call = try XCTUnwrap(StubURLProtocol.apiCalls.first)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/TDWebApi/api/115/tickets/42/workflow/approve")
        let body = try XCTUnwrap(call.jsonObject)
        XCTAssertEqual(Set(body.keys), ["StepID", "ActionID", "Comments"])
        XCTAssertEqual(body["StepID"] as? String, stepId.uuidString)
        XCTAssertEqual(body["ActionID"] as? String, "choice:yes/next")
        XCTAssertEqual(body["Comments"] as? String, "Reviewed")
    }

    func testActionOmitsAbsentComments() async throws {
        _ = try await service(body: #"{"IsSuccessful":true,"WasWorkflowUpdated":true}"#)
            .performWorkflowAction(ticketId: 42, request: .init(stepId: stepId, actionId: "complete"))
        XCTAssertNil(StubURLProtocol.apiCalls.first?.jsonObject?["Comments"])
    }

    func testHttp200ValidationFailureThrowsAllMessages() async throws {
        do {
            _ = try await service(body: #"{"IsSuccessful":false,"WasWorkflowUpdated":false,"Message":"Cannot advance","Errors":[{"Message":"Step is no longer current","StepIDs":[]},{"Message":"Refresh first"}]}"#)
                .performWorkflowAction(ticketId: 42, request: .init(stepId: stepId, actionId: "complete"))
            XCTFail("HTTP 200 is not business success")
        } catch let error as TdxWorkflowError {
            XCTAssertTrue(error.localizedDescription.contains("Cannot advance"))
            XCTAssertTrue(error.localizedDescription.contains("Step is no longer current"))
            XCTAssertTrue(error.localizedDescription.contains("Refresh first"))
        }
    }

    func testMissingSuccessFlagCannotReportSuccess() async throws {
        do {
            _ = try await service(body: #"{"Message":"Unknown response","WasWorkflowUpdated":true}"#)
                .performWorkflowAction(ticketId: 42, request: .init(stepId: stepId, actionId: "complete"))
            XCTFail("A malformed response must not succeed")
        } catch { }
    }

    func testPermissionAndTransportFailuresDoNotBecomeEmptyWorkflows() async throws {
        for status in [401, 403, 404, 429, 500] {
            do {
                _ = try await service(body: "{}", status: status).getWorkflow(ticketId: 42)
                XCTFail("HTTP \(status) must fail")
            } catch let error as TdxWorkflowError {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }
}
