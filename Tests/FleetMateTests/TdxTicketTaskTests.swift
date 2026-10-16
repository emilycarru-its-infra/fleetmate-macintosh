import XCTest
@testable import FleetMateCore

final class TdxTicketTaskTests: XCTestCase {
    private let taskBody = #"{"ID":7,"TicketID":42,"Title":"Review","Description":"Keep original","TypeID":1,"PercentComplete":25,"IsActive":true,"EstimatedMinutes":15,"PredecessorID":0,"ResponsibleUid":null,"ResponsibleGroupID":0,"NotifyResponsible":true,"ModifiedDate":"2026-01-01T00:00:00Z"}"#

    private func service(_ stubs: [StubURLProtocol.Stub]) -> TdxService {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://tdx.example.edu/TDWebApi"
        config.tdxAppId = 99
        config.tdxTicketingAppId = 115
        config.tdxAuthMethod = .auto
        config.tdxBeid = "synthetic-service"
        config.tdxWebServicesKey = "synthetic-key"
        StubURLProtocol.reset(stubs: stubs)
        let service = TdxService(config: config, sessionConfiguration: StubURLProtocol.sessionConfiguration())
        service.setSsoToken("eyJ.synthetic.user", expiry: .distantFuture)
        return service
    }

    private func expected() throws -> TdxTicketTask { try JSONDecoder().decode(TdxTicketTask.self, from: Data(taskBody.utf8)) }

    func testListAndFeedUseTicketingAppAndNullMeansEmpty() async throws {
        let service = service([
            .init(pathContains: "/tasks/7/feed", body: "null"),
            .init(pathContains: "/tasks", body: "[\(taskBody)]")
        ])
        let tasks = try await service.getTicketTasks(ticketId: 42)
        XCTAssertEqual(tasks.first?.percentComplete, 25)
        let feed = try await service.getTicketTaskFeed(ticketId: 42, taskId: 7)
        XCTAssertTrue(feed.isEmpty)
        XCTAssertEqual(StubURLProtocol.apiCalls.map(\.path), ["/TDWebApi/api/115/tickets/42/tasks", "/TDWebApi/api/115/tickets/42/tasks/7/feed"])
    }

    func testProgressUsesFeedWithoutReplacingTaskFields() async throws {
        let service = service([
            .init(pathContains: "/tasks/7/feed", method: "POST", body: #"{"ID":100,"Body":"Completed"}"#),
            .init(pathContains: "/tasks/7", method: "GET", body: taskBody)
        ])
        try await service.updateTicketTask(ticketId: 42, expected: expected(), update: .init(percentComplete: 100, comments: "Done"))
        let writes = StubURLProtocol.apiCalls.filter { $0.method == "POST" }
        let call = try XCTUnwrap(writes.first)
        XCTAssertEqual(writes.count, 1)
        let body = try XCTUnwrap(call.jsonObject)
        XCTAssertEqual(body["PercentComplete"] as? Int, 100)
        XCTAssertEqual(body["Comments"] as? String, "Done")
        XCTAssertEqual(body["IsRichHtml"] as? Bool, false)
        XCTAssertEqual(body["IsPrivate"] as? Bool, true)
        XCTAssertNil(body["Title"])
        XCTAssertTrue(StubURLProtocol.apiCalls.allSatisfy { $0.headers.first(where: { $0.key.lowercased() == "authorization" })?.value == "Bearer eyJ.synthetic.user" })
    }

    func testProgressRejectsInvalidValuesBeforeNetwork() async throws {
        let service = service([])
        for value in [-1, 101] {
            do {
                try await service.updateTicketTask(ticketId: 42, expected: expected(), update: .init(percentComplete: value))
                XCTFail("Invalid percentage accepted")
            } catch { }
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testStaleTaskBlocksEditAndProgressWithoutWrites() async throws {
        let service = service([.init(pathContains: "/tasks/7", body: taskBody.replacingOccurrences(of: "\"PercentComplete\":25", with: "\"PercentComplete\":50"))])
        do {
            try await service.updateTicketTask(ticketId: 42, expected: expected(), update: .init(percentComplete: 100))
            XCTFail("Stale task accepted")
        } catch { }
        XCTAssertTrue(StubURLProtocol.apiCalls.allSatisfy { $0.method == "GET" })
    }

    func testEditingSendsOnlyWritableFieldsAndExplicitNullClears() async throws {
        let service = service([
            .init(pathContains: "/tasks/7", method: "GET", body: taskBody),
            .init(pathContains: "/tasks/7", method: "PUT", body: taskBody)
        ])
        let task = try expected()
        var values = task.editableValues
        values.description = nil
        _ = try await service.editTicketTask(ticketId: 42, expected: task, values: values)
        let body = try XCTUnwrap(StubURLProtocol.apiCalls.first(where: { $0.method == "PUT" })?.jsonObject)
        XCTAssertTrue(body["Description"] is NSNull)
        XCTAssertTrue(body["StartDate"] is NSNull)
        XCTAssertTrue(body["ResponsibleUid"] is NSNull)
        XCTAssertNil(body["PercentComplete"])
        XCTAssertNil(body["ID"])
        XCTAssertNil(body["TypeID"])
        XCTAssertEqual(body["EstimatedMinutes"] as? Int, 15)
    }

    func testWorkflowTaskCannotBeDeletedOrEditedAsStandardTask() async throws {
        let body = taskBody.replacingOccurrences(of: "\"TypeID\":1", with: "\"TypeID\":3")
        let task = try JSONDecoder().decode(TdxTicketTask.self, from: Data(body.utf8))
        let service = service([])
        do { try await service.deleteTicketTask(ticketId: 42, expected: task); XCTFail("Deleted workflow task") } catch { }
        do { _ = try await service.editTicketTask(ticketId: 42, expected: task, values: task.editableValues); XCTFail("Edited workflow task") } catch { }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testTaskWritesNeverFallBackAfterUserExpiry() async throws {
        let service = service([])
        service.setSsoToken("eyJ.expired.user", expiry: .distantPast)
        do { _ = try await service.createTicketTask(ticketId: 42, values: .init(title: "New")); XCTFail("Used expired session") } catch is TdxAuthError { }
        do { try await service.updateTicketTask(ticketId: 42, expected: expected(), update: .init(percentComplete: 100)); XCTFail("Used expired session") } catch is TdxAuthError { }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testCrossTicketResponseIsRejected() async throws {
        let body = taskBody.replacingOccurrences(of: "\"TicketID\":42", with: "\"TicketID\":43")
        let service = service([.init(pathContains: "/tasks", body: "[\(body)]")])
        do { _ = try await service.getTicketTasks(ticketId: 42); XCTFail("Wrong ticket accepted") } catch { }
    }

    func testPermissionErrorsStayErrors() async throws {
        for code in [401, 403, 404, 429, 500] {
            let service = service([.init(pathContains: "/tasks", statusCode: code, body: "{}")])
            do { _ = try await service.getTicketTasks(ticketId: 42); XCTFail("HTTP failure hidden") } catch is TdxWorkflowError { }
        }
    }
    func testTaskTemplateUsesDocumentedBodyAndKeepsExistingByDefault() async throws {
        let service = service([.init(pathContains: "/tasks/applytemplate", method: "POST", body: "[\(taskBody)]")])
        let tasks = try await service.applyTaskTemplate(ticketId: 42, request: .init(taskTemplateId: 16, startDateSource: 2))
        XCTAssertEqual(tasks.count, 1)
        let body = try XCTUnwrap(StubURLProtocol.apiCalls.first?.jsonObject)
        XCTAssertEqual(body["TaskTemplateId"] as? Int, 16)
        XCTAssertEqual(body["StartDateSource"] as? Int, 2)
        XCTAssertEqual(body["RemoveExistingTasks"] as? Bool, false)
    }

    func testDeletionRequiresFreshSnapshotAndConfirmsAbsence() async throws {
        let service = service([
            .init(pathContains: "/tasks/7", method: "GET", body: taskBody),
            .init(pathContains: "/tasks/7", method: "DELETE", body: #""Removed""#),
            .init(pathContains: "/tasks", method: "GET", body: "[]")
        ])
        try await service.deleteTicketTask(ticketId: 42, expected: expected())
        XCTAssertEqual(StubURLProtocol.apiCalls.map(\.method), ["GET", "DELETE", "GET"])
    }

    func testProgressRequiresGeneratedFeedEntry() async throws {
        let service = service([
            .init(pathContains: "/tasks/7/feed", method: "POST", body: "{}"),
            .init(pathContains: "/tasks/7", method: "GET", body: taskBody)
        ])
        do {
            try await service.updateTicketTask(ticketId: 42, expected: expected(), update: .init(percentComplete: 100))
            XCTFail("Unverified success accepted")
        } catch { }
    }

}
