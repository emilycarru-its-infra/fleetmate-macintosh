import XCTest
@testable import FleetMateCore

final class TerminalWorkspacesTests: XCTestCase {
    func testDecodesAHandWrittenFileWithOptionalFieldsLeftOut() throws {
        let json = """
        {"openAtLaunch": "daily", "workspaces": [
          {"name": "Daily", "sections": [
            {"name": "Repos", "sessions": [{"command": "codex", "directory": "~/src/app"}, {}]},
            {"name": "Empty"}
          ]}
        ]}
        """
        let file = try JSONDecoder().decode(TerminalWorkspaceFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.launchWorkspace?.name, "Daily")
        XCTAssertEqual(file.workspaces[0].sessionCount, 2)
        XCTAssertEqual(file.workspaces[0].sections[1].sessions, [])
        XCTAssertNil(file.workspaces[0].show)
    }

    func testUpsertReplacesByNameAndRemoveClearsLaunch() {
        var file = TerminalWorkspaceFile(openAtLaunch: "A", workspaces: [TerminalWorkspace(name: "A", sections: [])])
        file.upsert(TerminalWorkspace(name: "a", fullWindow: true, sections: []))
        XCTAssertEqual(file.workspaces.count, 1)
        XCTAssertEqual(file.workspaces[0].fullWindow, true)
        file.upsert(TerminalWorkspace(name: "B", sections: []))
        XCTAssertEqual(file.workspaces.map(\.name), ["a", "B"])
        file.remove(named: "A")
        XCTAssertNil(file.openAtLaunch)
        XCTAssertEqual(file.workspaces.map(\.name), ["B"])
    }

    func testSaveAndLoadRoundTrip() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + "/terminal-workspaces.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertEqual(try TerminalWorkspaceStore.load(from: path), TerminalWorkspaceFile())
        let file = TerminalWorkspaceFile(openAtLaunch: "W", workspaces: [
            TerminalWorkspace(name: "W", show: true, sections: [
                .init(name: "Sessions", collapsed: true, sessions: [.init(name: "x", command: "claude", directory: "~/a")]),
            ]),
        ])
        try TerminalWorkspaceStore.save(file, to: path)
        XCTAssertEqual(try TerminalWorkspaceStore.load(from: path), file)
    }

    func testHomeIsWrittenAsTilde() {
        XCTAssertEqual(TerminalWorkspaceStore.abbreviate("/Users/a/src", home: "/Users/a"), "~/src")
        XCTAssertEqual(TerminalWorkspaceStore.abbreviate("/Users/a", home: "/Users/a"), "~")
        XCTAssertEqual(TerminalWorkspaceStore.abbreviate("/Users/ab/src", home: "/Users/a"), "/Users/ab/src")
        XCTAssertEqual(TerminalWorkspaceStore.expand("~/src", home: "/Users/a"), "/Users/a/src")
        XCTAssertEqual(TerminalWorkspaceStore.expand("/opt", home: "/Users/a"), "/opt")
    }
}
