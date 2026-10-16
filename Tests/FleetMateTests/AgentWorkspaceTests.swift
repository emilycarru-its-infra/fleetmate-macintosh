import XCTest
@testable import FleetMateCore

final class AgentWorkspaceTests: XCTestCase {
    func testRefreshPreservesPersonalInstructionsAndUpdatesGeneratedGuide() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AgentWorkspace(root: root)
        try workspace.prepare()
        let entry = root.appendingPathComponent("AGENTS.md")
        XCTAssertTrue(try String(contentsOf: entry).contains("FLEETMATE.md"))
        try "Personal instructions".write(to: entry, atomically: true, encoding: .utf8)
        try "Old generated guide".write(to: workspace.instructionsURL, atomically: true, encoding: .utf8)
        try workspace.prepare()
        XCTAssertEqual(try String(contentsOf: entry), "Personal instructions")
        XCTAssertEqual(try String(contentsOf: workspace.instructionsURL), AgentWorkspace.guide)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testMetadataIsOptionalAndSanitizesUntrustedLabels() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(AgentSessionMetadata.self, from: Data("{}".utf8))
        XCTAssertNil(empty.title)
        XCTAssertNil(empty.section)
        let data = try JSONSerialization.data(withJSONObject: [
            "title": "Task\u{1b}[31m\nname",
            "section": String(repeating: "x", count: 500)
        ])
        let metadata = try decoder.decode(AgentSessionMetadata.self, from: data)
        XCTAssertFalse(try XCTUnwrap(metadata.title).contains("\u{1b}"))
        XCTAssertFalse(try XCTUnwrap(metadata.title).contains("\n"))
        XCTAssertEqual(metadata.section?.count, 120)
        XCTAssertThrowsError(try decoder.decode(AgentSessionMetadata.self, from: Data("{\"title\":3}".utf8)))
    }
}
