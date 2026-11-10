import XCTest
@testable import FleetMateCore

final class TicketScopedSnapshotTests: XCTestCase {
    func testScopedSnapshotsRequireMatchingServiceAndPersonAndLeaveLegacyUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(TicketInboxScope(ticketEndpoint: "https://tickets.example.invalid/TDWebApi/api/1/tickets", personUid: "person-one"))
        let otherPerson = try XCTUnwrap(TicketInboxScope(ticketEndpoint: "https://tickets.example.invalid/TDWebApi/api/1/tickets", personUid: "person-two"))
        let otherService = try XCTUnwrap(TicketInboxScope(ticketEndpoint: "https://tickets.example.invalid/TDWebApi/api/2/tickets", personUid: "person-one"))
        let legacy = TicketSnapshot.fileURL(root: root)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("legacy snapshot with no provenance".utf8)
        try original.write(to: legacy)
        XCTAssertTrue(TicketSnapshot.load(scope: first, root: root).isEmpty)
        let ticket = try JSONDecoder().decode(TdxTicket.self, from: Data(#"{"ID":42,"Title":"Example ticket"}"#.utf8))
        TicketSnapshot.save([ticket], scope: first, root: root)
        let deadline = Date().addingTimeInterval(5)
        while TicketSnapshot.load(scope: first, root: root).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(TicketSnapshot.load(scope: first, root: root).first?.id, 42)
        XCTAssertTrue(TicketSnapshot.load(scope: otherPerson, root: root).isEmpty)
        XCTAssertTrue(TicketSnapshot.load(scope: otherService, root: root).isEmpty)
        let wrong = TicketSnapshot.fileURL(scope: otherPerson, root: root)
        try FileManager.default.createDirectory(at: wrong.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TicketSnapshot.fileURL(scope: first, root: root), to: wrong)
        XCTAssertTrue(TicketSnapshot.load(scope: otherPerson, root: root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
    }
}
