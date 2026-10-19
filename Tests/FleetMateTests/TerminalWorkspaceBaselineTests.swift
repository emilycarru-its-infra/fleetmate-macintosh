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
        XCTAssertEqual(workspace.sections[1].sessions.map(\.label), ["alpha/c", "zed/b"])
        // The repository's name is a label, so the program's title can replace it.
        XCTAssertEqual(workspace.sections[1].sessions.map(\.name), [nil, nil])
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
    func testReposHiddenInTheSidebarAreLeftOut() throws {
        let root = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shown = RepoKey(provider: .gitHub, owner: "owner-a", name: "shown")
        let hidden = RepoKey(provider: .azureDevOps, owner: "org", project: "Proj", name: "Hidden")
        var repos: [String: RepoRegistryEntry] = [:]
        for key in [shown, hidden] {
            let path = root + "/" + key.name
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            repos[key.id] = RepoRegistryEntry(key: key, path: path, tracked: true)
        }
        let document = RepoRegistryDocument(repos: repos)

        let registry = Data("""
        {"version": 1, "repos": {
          "\(shown.id)": {"path": "x", "tracked": true},
          "\(hidden.id)": {"path": "y", "tracked": true, "hidden": true}
        }}
        """.utf8)
        let hiddenIds = TerminalWorkspaceBaseline.hiddenRepoIds(inRegistry: registry)
        XCTAssertEqual(hiddenIds, [hidden.id])
        XCTAssertEqual(TerminalWorkspaceBaseline.hiddenRepoIds(inRegistry: Data("not json".utf8)), [])

        XCTAssertEqual(TerminalWorkspaceBaseline.checkouts(from: document).count, 2)
        let checkouts = TerminalWorkspaceBaseline.checkouts(from: document, excluding: hiddenIds)
        XCTAssertEqual(checkouts.map(\.displayName), ["owner-a/shown"])
        let workspace = try XCTUnwrap(TerminalWorkspaceBaseline.make(from: checkouts, command: "codex", now: now))
        XCTAssertEqual(workspace.sections.map(\.name), ["GitHub"])
    }

    private func tracked(_ provider: RepoProvider, _ scope: String, _ name: String) -> TerminalWorkspaceBaseline.Checkout {
        var c = checkout(provider, scope, name, daysAgo: 300)
        c.tracked = true
        return c
    }

    func testEveryTrackedCheckoutIsIncludedHoweverIdle() {
        let all = (0..<20).map { tracked(.gitHub, "o", "r\($0)") }
        XCTAssertEqual(TerminalWorkspaceBaseline.activeCheckouts(all, now: now).count, 20)
    }

    func testAnEmptyFileGetsTheReposWorkspace() {
        // The case that left a person with "No Saved Workspaces": the file
        // existed, empty, before the generated workspace was first written.
        var file = TerminalWorkspaceFile()
        XCTAssertTrue(file.syncBaseline(with: [tracked(.azureDevOps, "Cloud", "Vantage"), tracked(.gitHub, "o", "a")],
                                        command: "codex", now: now))
        XCTAssertEqual(file.baseline?.sections.map(\.name), ["Azure DevOps", "GitHub"])
        XCTAssertEqual(file.baseline?.sections.first?.sessions.first?.directory, "/src/Cloud/Vantage")
        XCTAssertFalse(file.syncBaseline(with: [tracked(.azureDevOps, "Cloud", "Vantage"), tracked(.gitHub, "o", "a")],
                                         command: "codex", now: now))
    }

    func testADeletedReposWorkspaceIsNotWrittenAgain() {
        var file = TerminalWorkspaceFile()
        file.syncBaseline(with: [tracked(.gitHub, "o", "a")], command: "codex", now: now)
        file.remove(named: TerminalWorkspaceBaseline.name)
        XCTAssertEqual(file.generateFromRepos, false)
        XCTAssertFalse(file.syncBaseline(with: [tracked(.gitHub, "o", "a")], command: "codex", now: now))
        XCTAssertNil(file.baseline)
    }

    func testSyncAddsNewRemovesUntrackedAndKeepsEdits() throws {
        var workspace = try XCTUnwrap(TerminalWorkspaceBaseline.make(
            from: [tracked(.gitHub, "o", "a"), tracked(.gitHub, "o", "b"), tracked(.azureDevOps, "P", "c")],
            command: "codex", now: now))
        // The person renames a, moves it to their own section, and removes b.
        var a = workspace.sections[1].sessions.removeFirst()
        a.name = "Mine"
        workspace.sections[1].sessions.removeAll { $0.directory == "/src/o/b" }
        workspace.sections.append(.init(name: "Focus", sessions: [a]))

        // c stops being tracked (or is hidden); d is newly tracked; b still is.
        let change = TerminalWorkspaceBaseline.sync(
            &workspace, with: [tracked(.gitHub, "o", "a"), tracked(.gitHub, "o", "b"), tracked(.gitHub, "o", "d")],
            command: "codex", now: now)
        XCTAssertEqual(change.added, ["/src/o/d"])
        XCTAssertEqual(change.removed, ["/src/p/c"])
        XCTAssertEqual(workspace.sections.map(\.name), ["GitHub", "Focus"])
        XCTAssertEqual(workspace.sections[0].sessions.map(\.directory), ["/src/o/d"])
        XCTAssertEqual(workspace.sections[1].sessions.first?.name, "Mine")
        // Removed by the person: not added back while it stays tracked.
        XCTAssertFalse(workspace.sections.flatMap(\.sessions).contains { $0.directory == "/src/o/b" })

        // Untracked then tracked again, it comes back.
        TerminalWorkspaceBaseline.sync(&workspace, with: [tracked(.gitHub, "o", "a"), tracked(.gitHub, "o", "d")],
                                       command: "codex", now: now)
        TerminalWorkspaceBaseline.sync(&workspace, with: [tracked(.gitHub, "o", "a"), tracked(.gitHub, "o", "b"),
                                                          tracked(.gitHub, "o", "d")], command: "codex", now: now)
        XCTAssertTrue(workspace.sections.flatMap(\.sessions).contains { $0.directory == "/src/o/b" })
    }

    func testANameStillTheGeneratedOneBecomesTheLabel() {
        var workspace = TerminalWorkspace(name: "Repos", sections: [.init(name: "GitHub", sessions: [
            .init(name: "o/a", command: "codex", directory: "/src/o/a"),
            .init(name: "Release prep", command: "codex", directory: "/src/o/b"),
        ])])
        workspace.source = TerminalWorkspaceBaseline.source
        TerminalWorkspaceBaseline.sync(&workspace, with: [tracked(.gitHub, "o", "a"), tracked(.gitHub, "o", "b")],
                                       command: "codex", now: now)
        XCTAssertEqual(workspace.sections[0].sessions.map(\.name), [nil, "Release prep"])
        XCTAssertEqual(workspace.sections[0].sessions.first?.label, "o/a")
    }
}
