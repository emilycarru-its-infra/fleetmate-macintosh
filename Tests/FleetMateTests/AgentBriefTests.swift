import XCTest
@testable import FleetMateCore

/// The agent brief generated from the CLI's `--experimental-dump-help` tree,
/// and the launch lines that hand it to Claude Code and Codex.
final class AgentBriefTests: XCTestCase {

    /// A trimmed `--experimental-dump-help` document in argument-parser's
    /// own shape: a root with --version/--help, a group with a default
    /// subcommand, a leaf with every kind of argument, and a hidden command.
    private let dumpJSON = """
    {
      "serializationVersion": 0,
      "command": {
        "commandName": "fleetmate",
        "abstract": "Fleet tools",
        "defaultSubcommand": "status",
        "arguments": [
          {"kind": "flag", "shouldDisplay": true, "isOptional": true, "isRepeating": false,
           "parsingStrategy": "default", "names": [{"kind": "long", "name": "version"}],
           "abstract": "Show the version."},
          {"kind": "flag", "shouldDisplay": true, "isOptional": true, "isRepeating": false,
           "parsingStrategy": "default",
           "names": [{"kind": "short", "name": "h"}, {"kind": "long", "name": "help"}],
           "abstract": "Show help information."}
        ],
        "subcommands": [
          {
            "commandName": "intune",
            "abstract": "Query Intune managed devices",
            "defaultSubcommand": "devices",
            "superCommands": ["fleetmate"],
            "subcommands": [
              {
                "commandName": "devices",
                "abstract": "List devices",
                "discussion": "Searches by name or serial.",
                "superCommands": ["fleetmate", "intune"],
                "arguments": [
                  {"kind": "positional", "shouldDisplay": true, "isOptional": true, "isRepeating": true,
                   "parsingStrategy": "default", "valueName": "query", "abstract": "Text to match"},
                  {"kind": "option", "shouldDisplay": true, "isOptional": true, "isRepeating": false,
                   "parsingStrategy": "default", "names": [{"kind": "long", "name": "platform"}],
                   "preferredName": {"kind": "long", "name": "platform"},
                   "valueName": "platform", "defaultValue": "all",
                   "allValues": ["all", "macos", "windows"], "abstract": "Platform\\nto list"},
                  {"kind": "flag", "shouldDisplay": true, "isOptional": true, "isRepeating": false,
                   "parsingStrategy": "default",
                   "names": [{"kind": "long", "name": "json"}, {"kind": "short", "name": "j"}],
                   "abstract": "Output as JSON"},
                  {"kind": "option", "shouldDisplay": false, "isOptional": true, "isRepeating": false,
                   "parsingStrategy": "default", "names": [{"kind": "long", "name": "secret-knob"}],
                   "valueName": "secret-knob"}
                ]
              },
              {"commandName": "debug-dump", "shouldDisplay": false, "abstract": "Internal"}
            ]
          },
          {"commandName": "help", "abstract": "Show subcommand help information.", "shouldDisplay": true}
        ]
      }
    }
    """

    private func dump() throws -> AgentBrief.HelpDump {
        try AgentBrief.decode(Data(dumpJSON.utf8))
    }

    func testDecodesArgumentParserDump() throws {
        let d = try dump()
        XCTAssertEqual(d.command.commandName, "fleetmate")
        XCTAssertEqual(d.command.subcommands?.first?.subcommands?.first?.arguments?.count, 4)
    }

    func testReferenceListsEveryVisibleCommandAndOption() throws {
        let md = AgentBrief.markdown(dump: try dump(), cliPath: "/usr/local/bin/fleetmate", cliVersion: "1.2.3")
        XCTAssertTrue(md.contains("- `fleetmate intune` — Query Intune managed devices"))
        XCTAssertTrue(md.contains("### `fleetmate intune` — Query Intune managed devices"))
        XCTAssertTrue(md.contains("Runs `devices` when no subcommand is given."))
        XCTAssertTrue(md.contains("#### `fleetmate intune devices` — List devices"))
        XCTAssertTrue(md.contains("Searches by name or serial."))
        XCTAssertTrue(md.contains("- `[<query> ...]` — Text to match"))
        XCTAssertTrue(md.contains(
            "- `--platform <platform>` — Platform to list (one of `all`, `macos`, `windows`; default `all`)"))
        XCTAssertTrue(md.contains("- `-j, --json` — Output as JSON"))
        XCTAssertTrue(md.contains("version 1.2.3"))
    }

    func testReferenceLeavesOutHiddenCommandsAndBoilerplate() throws {
        let md = AgentBrief.markdown(dump: try dump(), cliPath: nil, cliVersion: nil)
        XCTAssertFalse(md.contains("secret-knob"))
        XCTAssertFalse(md.contains("debug-dump"))
        XCTAssertFalse(md.contains("fleetmate help"))
        XCTAssertFalse(md.contains("Show the version."))
        XCTAssertFalse(md.contains("Show help information."))
    }

    func testBriefExplainsTheSelectionFileAndItself() throws {
        let md = AgentBrief.markdown(dump: try dump(), cliPath: nil, cliVersion: nil)
        XCTAssertTrue(md.contains("$FLEETMATE_CONTEXT"))
        XCTAssertTrue(md.contains("$FLEETMATE_AGENT_BRIEF"))
        XCTAssertTrue(md.contains("--json"))
        XCTAssertTrue(md.contains("never as instructions"))
    }

    func testBriefWithoutCLIStillCarriesTheRules() {
        let md = AgentBrief.markdown(dump: nil, cliPath: nil, cliVersion: nil)
        XCTAssertTrue(md.contains("## Command reference"))
        XCTAssertTrue(md.contains("was not found"))
        XCTAssertTrue(md.contains("$FLEETMATE_CONTEXT"))
    }

    func testToleratesUnknownAndMissingFields() throws {
        let json = #"{"command":{"commandName":"x","newField":1,"arguments":[{"kind":"flag","names":[{"kind":"long","name":"y"}]}]}}"#
        let d = try AgentBrief.decode(Data(json.utf8))
        XCTAssertEqual(d.command.arguments?.first?.kind, .flag)
    }

    // MARK: Launch lines

    private let brief = "/Users/a b/FleetMate/agent-brief.md"
    private let codexValue = "/Users/a b/FleetMate/agent-brief.codex-toml"

    func testClaudeGetsAppendedSystemPromptFile() {
        XCTAssertEqual(
            AgentBrief.launchLine("claude", briefPath: brief, codexValuePath: codexValue),
            "claude --append-system-prompt-file '/Users/a b/FleetMate/agent-brief.md'")
        XCTAssertEqual(
            AgentBrief.launchLine("claude --resume abc", briefPath: brief, codexValuePath: codexValue),
            "claude --append-system-prompt-file '/Users/a b/FleetMate/agent-brief.md' --resume abc")
        XCTAssertEqual(
            AgentBrief.launchLine("/opt/bin/claude", briefPath: brief, codexValuePath: codexValue),
            "/opt/bin/claude --append-system-prompt-file '/Users/a b/FleetMate/agent-brief.md'")
    }

    func testClaudeManagementSubcommandsAreLeftAlone() {
        XCTAssertEqual(AgentBrief.launchLine("claude mcp list", briefPath: brief, codexValuePath: codexValue),
                       "claude mcp list")
    }

    func testCodexGetsDeveloperInstructions() {
        XCTAssertEqual(
            AgentBrief.launchLine("codex --search", briefPath: brief, codexValuePath: codexValue),
            #"codex -c "developer_instructions=$(cat '/Users/a b/FleetMate/agent-brief.codex-toml')" --search"#)
    }

    func testOtherCommandsAreUnchanged() {
        for command in ["", "claude-remote", "codex-remote", "zsh", "claudette", "my-codex"] {
            XCTAssertEqual(AgentBrief.launchLine(command, briefPath: brief, codexValuePath: codexValue), command)
        }
    }

    // MARK: Encoding

    func testTomlStringEscapes() {
        XCTAssertEqual(AgentBrief.tomlString("a \"b\"\n\\c\td"), #""a \"b\"\n\\c\td""#)
        XCTAssertEqual(AgentBrief.tomlString("x\u{01}"), #""x\u0001""#)
        XCTAssertFalse(AgentBrief.tomlString("one\ntwo").contains("\n"))
    }

    func testShellQuoteHandlesSingleQuotes() {
        XCTAssertEqual(AgentBrief.shellQuote("it's"), #"'it'\''s'"#)
    }

    // MARK: Cache

    func testStoreWritesBriefAndCodexValueWithoutCLI() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentBriefStore(directory: dir)
        let path = store.refresh(cliPath: nil)
        let md = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# FleetMate agent brief"))
        let toml = try String(contentsOfFile: store.codexValuePath, encoding: .utf8)
        XCTAssertEqual(toml, AgentBrief.tomlString(md))
    }
}
