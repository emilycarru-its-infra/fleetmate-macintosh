import XCTest
@testable import FleetMateCore

final class AgentLaneScopeTests: XCTestCase {
    private let home = "/Users/someone"

    private func scope() -> AgentLaneScope {
        let baseline = TerminalWorkspace(name: "Repos", sections: [
            .init(name: "Cloud", sessions: [.init(directory: "\(home)/Code/Cloud/Portal")]),
            .init(name: "Other", sessions: [.init(directory: "\(home)/Code/Notes")]),
            .init(name: "Hub", sessions: [.init(directory: "\(home)/Code/Hub/"), .init(directory: nil)]),
        ])
        return AgentLaneScope(baseline: baseline, workspaceRoot: "\(home)/.fleetmate")
    }

    func testListsSessionsInARepositoryAndItsWorktrees() {
        let scope = scope()
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Cloud/Portal"))
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Cloud/Portal/"), "a trailing slash is the same folder")
        XCTAssertTrue(scope.contains(directory: "\(home)/code/cloud/portal"), "names compare without case")
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Cloud/Portal/.worktrees/fix-login"))
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Cloud/Portal/.claude/worktrees/tidy"))
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Hub"))
    }

    func testLeavesOutFoldersTheSidebarDoesNotList() {
        let scope = scope()
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Notes/categories/Business"),
                       "a project in a repository's subfolder is not that repository's session")
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Cloud"), "a parent of a listed repository is not listed")
        XCTAssertFalse(scope.contains(directory: "\(home)/Code"))
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Cloud/Portal-old"), "a folder that only starts the same")
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Cloud/Portal/.worktrees"), "the worktrees folder itself")
        XCTAssertFalse(scope.contains(directory: nil))
        XCTAssertFalse(scope.contains(directory: ""))
    }

    func testTheAgentWorkspaceCountsOnlyExactly() {
        let scope = scope()
        XCTAssertTrue(scope.contains(directory: "\(home)/.fleetmate"))
        XCTAssertFalse(scope.contains(directory: "\(home)/.fleetmate/sessions"))
        XCTAssertFalse(scope.contains(directory: "\(home)/.fleetmate/.worktrees/x"))
    }

    func testNoBaselineLeavesOnlyTheWorkspace() {
        let scope = AgentLaneScope(baseline: nil, workspaceRoot: "\(home)/.fleetmate")
        XCTAssertTrue(scope.repositories.isEmpty)
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Cloud/Portal"))
        XCTAssertNotEqual(scope, self.scope(), "a changed list is a change, so Detached is swept again")
    }

    func testLaneIDFileIsNamedAsTheWrapperNamesIt() {
        let dir = URL(fileURLWithPath: "/state/claude-lanes", isDirectory: true)
        XCTAssertEqual(ClaudeLaneIDFile.url(lane: "portal", in: dir)?.path, "/state/claude-lanes/portal")
        XCTAssertEqual(ClaudeLaneIDFile.url(lane: "portal-2", in: dir)?.path, "/state/claude-lanes/portal-2")
        XCTAssertEqual(ClaudeLaneIDFile.url(lane: "a/b c", in: dir)?.path, "/state/claude-lanes/a_b_c")
        XCTAssertNil(ClaudeLaneIDFile.url(lane: "", in: dir))
        XCTAssertNil(ClaudeLaneIDFile.url(lane: "..", in: dir))
        XCTAssertEqual(ClaudeLaneIDFile.directory(environment: [:], home: URL(fileURLWithPath: home)).path,
                       "\(home)/.local/state/claude-lanes")
        XCTAssertEqual(ClaudeLaneIDFile.directory(environment: ["CLAUDE_LANE_STATE_DIR": "/elsewhere"]).path, "/elsewhere")
    }

    func testTheRegistryDecidesAndAnotherHostsFolderDoesNotCountHere() {
        let registry = AgentAppsRepoRegistry(sections: [
            .init(name: "Devices", repos: [.init(path: "\(home)/Code/Devices/Agent", host: "hub")]),
            .init(name: "Remote", repos: [.init(path: "\(home)/Code", host: "other", kind: "folder")]),
        ])
        let scope = AgentLaneScope(registry: registry, hub: "hub", workspaceRoot: nil)
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Devices/Agent", host: nil))
        XCTAssertTrue(scope.contains(directory: "\(home)/Code/Devices/Agent/.worktrees/a", host: "hub"))
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Cloud/Portal", host: nil), "not in this app's registry")
        XCTAssertFalse(scope.contains(directory: "\(home)/Code", host: nil), "that folder is listed for the other host")
        XCTAssertTrue(scope.contains(directory: "\(home)/Code", host: "other"))
        XCTAssertFalse(scope.contains(directory: "\(home)/Code/Devices/Agent", host: "other"))
    }
}
