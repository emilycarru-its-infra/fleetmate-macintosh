import XCTest
@testable import FleetMateCore

final class SharedRepositoryTests: XCTestCase {
    private let registry = AgentAppsRepoRegistry(sections: [
        .init(name: "A", repos: [
            .init(path: "/w/shared", shared: true),
            .init(path: "/w/alone"),
        ]),
    ])

    func testASharedRepositoryAndItsWorktreesAreShared() {
        XCTAssertTrue(registry.isShared(directory: "/w/shared"))
        XCTAssertTrue(registry.isShared(directory: "/w/shared/"))
        XCTAssertTrue(registry.isShared(directory: "/w/shared/.worktrees/fix"))
        XCTAssertTrue(registry.isShared(directory: "/w/shared/.claude/worktrees/fix"))
    }

    func testAnUnsharedOrUnlistedFolderIsNot() {
        XCTAssertFalse(registry.isShared(directory: "/w/alone"))
        XCTAssertFalse(registry.isShared(directory: "/w/alone/.worktrees/fix"))
        XCTAssertFalse(registry.isShared(directory: "/w/shared/sub"))
        XCTAssertFalse(registry.isShared(directory: "/w/sharedother"))
        XCTAssertFalse(registry.isShared(directory: "/elsewhere"))
        XCTAssertFalse(registry.isShared(directory: nil))
    }

    func testTheFileSaysWhichRepositoriesAreShared() throws {
        let json = """
        {"schema_version": 1, "app": {"zone": "ecu"}, "sections": [{"name": "S", "repos": [
          {"path": "/w/one", "shared": true}, {"path": "/w/two", "shared": false}, {"path": "/w/three"}]}]}
        """
        let decoded = try XCTUnwrap(AgentAppsRepoRegistry.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.sections.first?.repos.map(\.shared), [true, false, false])
    }
}
