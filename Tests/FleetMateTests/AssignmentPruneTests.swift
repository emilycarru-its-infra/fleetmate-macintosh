import Foundation
import XCTest
@testable import FleetMateCore

final class AssignmentPruneTests: XCTestCase {

    // MARK: - Verdict table

    func testOnlyTwoNotFoundsAndNoDeletedItemIsGone() {
        XCTAssertEqual(GroupTargetVerdict.decide(firstRead: 404, secondRead: 404, deletedItemsRead: 404), .gone)
    }

    func testResolvingGroupIsLive() {
        XCTAssertEqual(GroupTargetVerdict.decide(firstRead: 200, secondRead: nil, deletedItemsRead: nil), .live)
    }

    func testNotFoundThatResolvesOnRecheckIsLive() {
        XCTAssertEqual(GroupTargetVerdict.decide(firstRead: 404, secondRead: 200, deletedItemsRead: nil), .live)
    }

    func testSoftDeletedGroupIsNotPruned() {
        let verdict = GroupTargetVerdict.decide(firstRead: 404, secondRead: 404, deletedItemsRead: 200)
        XCTAssertEqual(verdict, .softDeleted)
        XCTAssertFalse(verdict.isPrunable)
    }

    func testFailedOrThrottledReadsAreNeverPrunable() {
        let cases: [(Int?, Int?, Int?)] = [
            (nil, nil, nil), (500, nil, nil), (429, nil, nil), (403, nil, nil),
            (404, nil, nil), (404, 503, nil), (404, 429, nil),
            (404, 404, nil), (404, 404, 500), (404, 404, 403),
        ]
        for (first, second, deleted) in cases {
            let verdict = GroupTargetVerdict.decide(firstRead: first, secondRead: second, deletedItemsRead: deleted)
            XCTAssertFalse(verdict.isPrunable, "\(String(describing: first)) \(String(describing: second)) \(String(describing: deleted))")
            XCTAssertNotEqual(verdict, .live)
        }
    }

    // MARK: - Plan

    private func row(_ group: String, assignment: String = UUID().uuidString,
                     source: EnrollmentAssignmentSource = .autopilotProfile) -> EnrollmentAssignmentRow {
        EnrollmentAssignmentRow(source: source, configurationId: "profile", configurationName: "Profile",
                                assignmentId: assignment, groupId: group, isExclusion: false)
    }

    func testPlanReReadsOnlyMissingGroupsAndChecksDeletedItemsOnlyAfterTwoMisses() async throws {
        let rows = [row("live"), row("gone"), row("flaky"), row("restorable"), row("gone", source: .enrollmentStatusPage)]
        var groupReads: [[String]] = []
        var deletedReads: [[String]] = []
        var paused = 0

        let plan = try await AssignmentPrunePlan.build(
            rows: rows,
            readGroups: { ids in
                groupReads.append(ids)
                if groupReads.count == 1 {
                    return ["live": 200, "gone": 404, "flaky": 404, "restorable": 404]
                }
                return ["gone": 404, "flaky": 503, "restorable": 404]
            },
            readDeletedItems: { ids in
                deletedReads.append(ids)
                return ["gone": 404, "restorable": 200]
            },
            pause: { paused += 1 }
        )

        XCTAssertEqual(groupReads.count, 2)
        XCTAssertEqual(groupReads[0], ["live", "gone", "flaky", "restorable"])
        XCTAssertEqual(groupReads[1], ["gone", "flaky", "restorable"])
        XCTAssertEqual(deletedReads, [["gone", "restorable"]])
        XCTAssertEqual(paused, 1)

        XCTAssertEqual(plan.prunable.map(\.groupId), ["gone", "gone"])
        XCTAssertEqual(Set(plan.held.map(\.groupId)), ["flaky", "restorable"])
        XCTAssertEqual(plan.verdicts["live"], .live)
        XCTAssertEqual(plan.verdicts["restorable"], .softDeleted)
    }

    func testPlanWithEveryGroupLiveMakesOneReadAndNoPause() async throws {
        var reads = 0
        var paused = false
        let plan = try await AssignmentPrunePlan.build(
            rows: [row("a"), row("b")],
            readGroups: { _ in reads += 1; return ["a": 200, "b": 200] },
            readDeletedItems: { _ in XCTFail("deleted items should not be read"); return [:] },
            pause: { paused = true }
        )
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(paused)
        XCTAssertTrue(plan.prunable.isEmpty)
        XCTAssertTrue(plan.held.isEmpty)
    }

    func testGroupMissingFromBatchResponseIsHeldNotPruned() async throws {
        let plan = try await AssignmentPrunePlan.build(
            rows: [row("absent")],
            readGroups: { _ in [:] },
            readDeletedItems: { _ in [:] },
            pause: {}
        )
        XCTAssertTrue(plan.prunable.isEmpty)
        XCTAssertEqual(plan.held.count, 1)
    }

    func testGroupIdsDifferingOnlyInCaseShareOneVerdict() async throws {
        let plan = try await AssignmentPrunePlan.build(
            rows: [row("ABC"), row("abc")],
            readGroups: { ids in
                XCTAssertEqual(ids, ["abc"])
                return ["abc": 404]
            },
            readDeletedItems: { _ in ["abc": 404] },
            pause: {}
        )
        XCTAssertEqual(plan.prunable.count, 2)
    }

    func testFailedReadAbortsThePlan() async {
        struct Outage: Error {}
        do {
            _ = try await AssignmentPrunePlan.build(
                rows: [row("a")],
                readGroups: { _ in throw Outage() },
                readDeletedItems: { _ in [:] },
                pause: {}
            )
            XCTFail("expected the read failure to propagate")
        } catch {
            XCTAssertTrue(error is Outage)
        }
    }

    // MARK: - Graph shapes

    func testOnlyGroupAndExclusionTargetsBecomeRows() throws {
        let json = """
        {"value":[{"id":"p1","displayName":"Profile","assignments":[
          {"id":"a1","target":{"@odata.type":"#microsoft.graph.groupAssignmentTarget","groupId":"g1"}},
          {"id":"a2","target":{"@odata.type":"#microsoft.graph.exclusionGroupAssignmentTarget","groupId":"g2"}},
          {"id":"a3","target":{"@odata.type":"#microsoft.graph.allDevicesAssignmentTarget"}}
        ]}]}
        """
        let page = try JSONDecoder().decode(EnrollmentConfigurationsResponse.self, from: Data(json.utf8))
        let rows = page.value[0].rows(source: .autopilotProfile)
        XCTAssertEqual(rows.map(\.groupId), ["g1", "g2"])
        XCTAssertEqual(rows.map(\.isExclusion), [false, true])
        XCTAssertEqual(rows.map(\.assignmentId), ["a1", "a2"])
    }

    func testEnrollmentStatusPageIsPickedOutOfEnrollmentConfigurations() throws {
        let json = """
        {"value":[
          {"id":"c1","@odata.type":"#microsoft.graph.windows10EnrollmentCompletionPageConfiguration"},
          {"id":"c2","@odata.type":"#microsoft.graph.deviceEnrollmentLimitConfiguration"}
        ]}
        """
        let page = try JSONDecoder().decode(EnrollmentConfigurationsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(page.value.filter(\.isEnrollmentStatusPage).map(\.id), ["c1"])
    }

    func testBatchStatusesIgnoreBodies() throws {
        let json = """
        {"responses":[
          {"id":"0","status":200,"body":{"id":"g1","onPremisesProvisioningErrors":[{"value":"x"}]}},
          {"id":"1","status":404,"body":{"error":{"code":"Request_ResourceNotFound"}}}
        ]}
        """
        let response = try JSONDecoder().decode(StatusOnlyBatchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.responses.map(\.status), [200, 404])
    }
}
