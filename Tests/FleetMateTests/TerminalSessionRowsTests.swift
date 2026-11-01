import XCTest
@testable import FleetMateCore

/// Switching a session's agent, duplicating it, and writing the session
/// list's repository rows back to the Repos workspace.
final class TerminalSessionRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func tracked(_ name: String) -> TerminalWorkspaceBaseline.Checkout {
        .init(provider: .gitHub, scope: "o", displayName: "o/\(name)", path: "/src/o/\(name)", lastActivity: nil, tracked: true)
    }

    private func reposWorkspace(_ names: [String]) throws -> TerminalWorkspace {
        try XCTUnwrap(TerminalWorkspaceBaseline.make(from: names.map(tracked), now: now))
    }

    private func row(_ name: String, id: String? = nil, section: String = "GitHub", title: String = "",
                     pinned: Bool = false, command: String? = nil) -> TerminalWorkspaceBaseline.Row {
        .init(id: id, directory: "/src/o/\(name)", label: "o/\(name)", section: section, name: title,
              pinned: pinned, command: command)
    }

    // MARK: Naming a duplicate

    func testADuplicateIsNumberedFromTwo() {
        XCTAssertEqual(TerminalSessionName.duplicate(of: "fleetmate", existing: ["fleetmate"]), "fleetmate 2")
    }

    func testADuplicateSkipsNamesInUse() {
        XCTAssertEqual(TerminalSessionName.duplicate(of: "api", existing: ["api", "API 2", "api 3"]), "api 4")
    }

    func testADuplicateOfANumberedNameCountsOn() {
        XCTAssertEqual(TerminalSessionName.duplicate(of: "api 2", existing: ["api", "api 2"]), "api 3")
        // A bare number, or a name like a version, is a name of its own.
        XCTAssertEqual(TerminalSessionName.duplicate(of: "2", existing: []), "2 2")
        XCTAssertEqual(TerminalSessionName.duplicate(of: "o/repo", existing: []), "o/repo 2")
    }

    // MARK: Switching the agent

    func testSwitchingARowWritesItsCommandBack() throws {
        var workspace = try reposWorkspace(["a", "b"])
        TerminalWorkspaceBaseline.write([row("a", command: "claude"), row("b")], sections: ["GitHub"],
                                        collapsed: [], to: &workspace)
        let sessions = workspace.sections[0].sessions
        XCTAssertEqual(sessions.map(\.command), ["claude", nil])
        // Its folder and label stay; only what it runs changed.
        XCTAssertEqual(sessions[0].directory, "/src/o/a")
        XCTAssertEqual(sessions[0].label, "o/a")
    }

    func testASwitchedRowNoLongerFollowsTheDefaultAfterSync() throws {
        var workspace = try reposWorkspace(["a"])
        TerminalWorkspaceBaseline.write([row("a", command: "codex")], sections: ["GitHub"], collapsed: [], to: &workspace)
        TerminalWorkspaceBaseline.sync(&workspace, with: [tracked("a")], defaultCommand: "codex", now: now)
        XCTAssertEqual(workspace.sections[0].sessions[0].command, "codex")
    }

    func testWritingBackKeepsWhatTheRowDoesNotCarry() throws {
        var workspace = try reposWorkspace(["a"])
        workspace.sections[0].sessions[0].resume = true
        TerminalWorkspaceBaseline.write([row("a", title: "Mine", pinned: true)], sections: ["GitHub"],
                                        collapsed: ["GitHub"], to: &workspace)
        let session = workspace.sections[0].sessions[0]
        XCTAssertEqual(session.resume, true)
        XCTAssertEqual(session.name, "Mine")
        XCTAssertEqual(session.pinned, true)
        XCTAssertEqual(workspace.sections[0].collapsed, true)
    }

    // MARK: Duplicating

    func testADuplicateGoesDirectlyBelowTheOriginal() throws {
        var workspace = try reposWorkspace(["a", "b"])
        let rows = [row("a"), row("a", id: "copy", title: "o/a 2", command: "claude"), row("b")]
        TerminalWorkspaceBaseline.write(rows, sections: ["GitHub"], collapsed: [], to: &workspace)
        let sessions = workspace.sections[0].sessions
        XCTAssertEqual(sessions.map(\.directory), ["/src/o/a", "/src/o/a", "/src/o/b"])
        XCTAssertEqual(sessions.map(\.id), [nil, "copy", nil])
        XCTAssertEqual(sessions[1].name, "o/a 2")
        XCTAssertEqual(sessions[1].command, "claude")
        XCTAssertEqual(sessions[1].label, "o/a")
    }

    func testTheDuplicateIsNotAGeneratedSession() throws {
        var workspace = try reposWorkspace(["a"])
        TerminalWorkspaceBaseline.write([row("a"), row("a", id: "copy", command: "codex")], sections: ["GitHub"],
                                        collapsed: [], to: &workspace)
        // The original and its copy are told apart by the copy's id.
        XCTAssertEqual(workspace.sections[0].sessions.map(\.rowKey), ["/src/o/a", "copy"])
        // a stops being tracked: its generated session goes, the copy stays.
        let change = TerminalWorkspaceBaseline.sync(&workspace, with: [], now: now)
        XCTAssertEqual(change.removed, ["/src/o/a"])
        XCTAssertEqual(workspace.sections.flatMap(\.sessions).map(\.id), ["copy"])
        // Tracked again, nothing is added: the copy holds the folder.
        TerminalWorkspaceBaseline.sync(&workspace, with: [tracked("a")], now: now)
        XCTAssertEqual(workspace.sections.flatMap(\.sessions).map(\.id), ["copy"])
    }

    func testRemovingADuplicateTakesItOut() throws {
        var workspace = try reposWorkspace(["a"])
        TerminalWorkspaceBaseline.write([row("a"), row("a", id: "copy")], sections: ["GitHub"], collapsed: [], to: &workspace)
        TerminalWorkspaceBaseline.write([row("a")], sections: ["GitHub"], collapsed: [], to: &workspace)
        XCTAssertEqual(workspace.sections[0].sessions.map(\.id), [nil])
    }

    func testAGeneratedRowSyncTookOutIsNotWrittenBack() throws {
        var workspace = try reposWorkspace(["a", "b"])
        TerminalWorkspaceBaseline.sync(&workspace, with: [tracked("a")], now: now)
        // b's row is still running in the list, so it is still a row.
        TerminalWorkspaceBaseline.write([row("a"), row("b")], sections: ["GitHub"], collapsed: [], to: &workspace)
        XCTAssertEqual(workspace.sections[0].sessions.map(\.directory), ["/src/o/a"])
    }

    func testTheIdRoundTripsAndIsLeftOutWhenNil() throws {
        let copy = TerminalWorkspace.Session(command: "codex", directory: "~/src/a", id: "copy")
        let decoded = try JSONDecoder().decode(TerminalWorkspace.Session.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(decoded, copy)
        let plain = try JSONEncoder().encode(TerminalWorkspace.Session(directory: "~/src/a"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"id\""))
    }
}
