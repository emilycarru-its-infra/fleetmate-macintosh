import XCTest
@testable import FleetMateCore

final class TerminalWorkspaceBaselineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func checkout(_ provider: RepoProvider, _ scope: String, _ name: String, daysAgo: Double?) -> TerminalWorkspaceBaseline.Checkout {
        .init(provider: provider, scope: scope, displayName: "\(scope)/\(name)", path: "/src/\(scope)/\(name)",
              lastActivity: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    func testNoCheckoutsMakesNoWorkspace() {
        XCTAssertNil(TerminalWorkspaceBaseline.make(from: [], command: "codex", now: now))
    }

    func testAFewCheckoutsAreAllIncludedGroupedByHost() throws {
        let workspace = try XCTUnwrap(TerminalWorkspaceBaseline.make(from: [
            checkout(.gitHub, "zed", "b", daysAgo: 400),
            checkout(.azureDevOps, "Proj", "a", daysAgo: nil),
            checkout(.gitHub, "alpha", "c", daysAgo: 1),
        ], command: "codex", now: now))
        XCTAssertEqual(workspace.source, TerminalWorkspaceBaseline.source)
        XCTAssertEqual(workspace.sections.map(\.name), ["Azure DevOps", "GitHub"])
        XCTAssertEqual(workspace.sections[1].sessions.map(\.name), ["alpha/c", "zed/b"])
        XCTAssertEqual(workspace.sections[0].sessions.first?.command, "codex")
    }

    func testManyCheckoutsKeepOnlyTheActiveOnes() {
        var all = (0..<10).map { checkout(.gitHub, "o", "old\($0)", daysAgo: 60) }
        all.append(checkout(.gitHub, "o", "recent", daysAgo: 3))
        let chosen = TerminalWorkspaceBaseline.activeCheckouts(all, now: now)
        XCTAssertEqual(chosen.map(\.displayName), ["o/recent"])
    }

    func testManyIdleCheckoutsFallBackToTheMostRecent() {
        let all = (0..<12).map { checkout(.gitHub, "o", "r\($0)", daysAgo: Double(30 + $0)) }
        let chosen = TerminalWorkspaceBaseline.activeCheckouts(all, now: now)
        XCTAssertEqual(chosen.count, TerminalWorkspaceBaseline.includeAllUpTo)
        XCTAssertEqual(chosen.first?.displayName, "o/r0")
    }

    func testAddMissingKeepsEditsAndAddsOnlyNewFolders() throws {
        var workspace = try XCTUnwrap(TerminalWorkspaceBaseline.make(
            from: [checkout(.gitHub, "o", "a", daysAgo: 1)], command: "codex", now: now))
        workspace.sections[0].sessions[0].command = "claude"
        workspace.sections.append(.init(name: "Mine", sessions: []))
        let added = TerminalWorkspaceBaseline.addMissing(
            [checkout(.gitHub, "o", "a", daysAgo: 1), checkout(.azureDevOps, "P", "b", daysAgo: 1)],
            to: &workspace, command: "codex", now: now)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(workspace.sections[0].sessions[0].command, "claude")
        XCTAssertEqual(workspace.sections.map(\.name), ["GitHub", "Mine", "Azure DevOps"])
    }

    func testActivityFollowsTheHeadReflog() throws {
        let root = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git/logs", withIntermediateDirectories: true)
        XCTAssertNil(TerminalWorkspaceBaseline.lastActivity(ofCheckout: root + "/missing"))
        FileManager.default.createFile(atPath: root + "/.git/logs/HEAD", contents: Data())
        XCTAssertNotNil(TerminalWorkspaceBaseline.lastActivity(ofCheckout: root))
    }

    func testBaselineIsFoundAfterARename() {
        var file = TerminalWorkspaceFile(workspaces: [TerminalWorkspace(name: "Mine", sections: [])])
        var generated = TerminalWorkspace(name: "Daily repos", sections: [])
        generated.source = TerminalWorkspaceBaseline.source
        file.upsert(generated)
        XCTAssertEqual(file.baselineIndex, 1)
    }
}
