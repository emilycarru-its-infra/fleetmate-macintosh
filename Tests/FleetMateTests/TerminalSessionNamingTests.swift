import XCTest
@testable import FleetMateCore

final class TerminalSessionNamingTests: XCTestCase {
    func testAnAgentTitleLosesItsGlyphAndReportsWorking() {
        XCTAssertEqual(TerminalTitle.parse("⠐ Fix login redirect"), TerminalTitle(task: "Fix login redirect", working: true))
        XCTAssertEqual(TerminalTitle.parse("✳ Fix login redirect"), TerminalTitle(task: "Fix login redirect", working: false))
        XCTAssertEqual(TerminalTitle.parse("Release notes"), TerminalTitle(task: "Release notes", working: nil))
    }

    func testShellAndProgramTitlesNameNoTask() {
        XCTAssertNil(TerminalTitle.parse("✳ Claude Code").task)
        XCTAssertNil(TerminalTitle.parse("codex").task)
        XCTAssertNil(TerminalTitle.parse("person@workstation: ~/src/app").task)
        XCTAssertNil(TerminalTitle.parse("person@workstation ~/src").task)
        XCTAssertNil(TerminalTitle.parse("~/src/app").task)
        XCTAssertNil(TerminalTitle.parse("  ").task)
    }

    func testControlCharactersAreStrippedAndLengthCapped() {
        XCTAssertEqual(TerminalTitle.parse("Deploy\u{07} fix").task, "Deploy fix")
        XCTAssertEqual(TerminalTitle.parse(String(repeating: "x", count: 300)).task?.count, TerminalTitle.maxLength)
    }

    func testAManualNameWinsOverEveryAutomaticOne() {
        XCTAssertEqual(TerminalSessionName.resolve(custom: "Mine", agent: "Agent", task: "Task", label: "o/a", fallback: "Codex"), "Mine")
        XCTAssertEqual(TerminalSessionName.resolve(custom: "  ", agent: nil, task: "Task", label: "o/a", fallback: "Codex"), "Task")
        XCTAssertEqual(TerminalSessionName.resolve(custom: "", agent: "Agent", task: "Task", label: nil, fallback: "Codex"), "Agent")
        XCTAssertEqual(TerminalSessionName.resolve(custom: "", agent: nil, task: nil, label: "o/a", fallback: "Codex"), "o/a")
        XCTAssertEqual(TerminalSessionName.resolve(custom: nil, agent: nil, task: nil, label: nil, fallback: "Codex"), "Codex")
    }

    func testBreadcrumbStartsBelowTheNearestRoot() {
        let home = "/Users/person"
        XCTAssertEqual(TerminalBreadcrumb.make("~/src/Cloud/Vantage", roots: ["~/src"], home: home), "Cloud · Vantage")
        XCTAssertEqual(TerminalBreadcrumb.make("/Users/person/src/GitHub/o/app/.worktrees/fix", roots: ["~/src", "~/src/GitHub"], home: home),
                       "o · app · fix")
        XCTAssertEqual(TerminalBreadcrumb.make("/Users/person/src", roots: ["~/src/"], home: home), "src")
        XCTAssertEqual(TerminalBreadcrumb.make("/Users/person/Documents/x", roots: ["~/src"], home: home), "~ · Documents · x")
        XCTAssertEqual(TerminalBreadcrumb.make("/Users/person", roots: [], home: home), "~")
        XCTAssertEqual(TerminalBreadcrumb.make("/opt/tools", roots: [], home: home), "opt · tools")
    }

    func testResumeCommands() {
        XCTAssertEqual(AgentResume.command("claude"), "claude --continue")
        XCTAssertEqual(AgentResume.command("claude --model opus"), "claude --model opus --continue")
        XCTAssertNil(AgentResume.command("claude --continue"))
        XCTAssertEqual(AgentResume.command("codex"), "codex resume --last")
        XCTAssertNil(AgentResume.command("codex exec hi"))
        XCTAssertNil(AgentResume.command("claude-remote"))
        XCTAssertNil(AgentResume.command(""))
    }
}
