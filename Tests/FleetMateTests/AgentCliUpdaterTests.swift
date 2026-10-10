import XCTest
@testable import FleetMateCore

final class AgentCliUpdaterTests: XCTestCase {
    let home = "/Users/someone"

    // MARK: Install method detection

    func testHomebrewCask() {
        let install = AgentCliUpdater.detect(cli: .codex, path: "/opt/homebrew/bin/codex",
                                             resolvedPath: "/opt/homebrew/Caskroom/codex/0.162.1/bin/codex", home: home)
        XCTAssertEqual(install.method, .homebrewCask)
        XCTAssertEqual(install.package, "codex")
        XCTAssertEqual(install.prefix, "/opt/homebrew")
    }

    func testHomebrewFormulaOnIntelPrefix() {
        let install = AgentCliUpdater.detect(cli: .codex, path: "/usr/local/bin/codex",
                                             resolvedPath: "/usr/local/Cellar/codex/0.160.0/bin/codex", home: home)
        XCTAssertEqual(install.method, .homebrewFormula)
        XCTAssertEqual(install.package, "codex")
        XCTAssertEqual(install.prefix, "/usr/local")
    }

    func testNpmGlobalScopedPackage() {
        let install = AgentCliUpdater.detect(
            cli: .codex, path: "/opt/homebrew/bin/codex",
            resolvedPath: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", home: home)
        XCTAssertEqual(install.method, .npm)
        XCTAssertEqual(install.package, "@openai/codex")
        XCTAssertEqual(install.prefix, "/opt/homebrew")
    }

    func testNpmUnderNvm() {
        let install = AgentCliUpdater.detect(
            cli: .claude, path: "\(home)/.nvm/versions/node/v22.1.0/bin/claude",
            resolvedPath: "\(home)/.nvm/versions/node/v22.1.0/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            home: home)
        XCTAssertEqual(install.method, .npm)
        XCTAssertEqual(install.package, "@anthropic-ai/claude-code")
        XCTAssertEqual(install.prefix, "\(home)/.nvm/versions/node/v22.1.0")
    }

    func testClaudeNativeInstaller() {
        let install = AgentCliUpdater.detect(cli: .claude, path: "\(home)/.local/bin/claude",
                                             resolvedPath: "\(home)/.local/share/claude/versions/2.1.296", home: home)
        XCTAssertEqual(install.method, .claudeNative)
    }

    func testClaudeLegacyLocalInstallIsNative() {
        let install = AgentCliUpdater.detect(
            cli: .claude, path: "\(home)/.claude/local/claude",
            resolvedPath: "\(home)/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js", home: home)
        XCTAssertEqual(install.method, .claudeNative)
    }

    func testUnknownLocation() {
        let install = AgentCliUpdater.detect(cli: .codex, path: "\(home)/bin/codex",
                                             resolvedPath: "\(home)/bin/codex", home: home)
        XCTAssertEqual(install.method, .unknown)
    }

    // MARK: Command selection

    private func updater(executables: Set<String> = ["/opt/homebrew/bin/brew", "/opt/homebrew/bin/npm"],
                         run: @escaping AgentCliUpdater.Runner = { _ in ProcessOutput(stdout: "", stderr: "", exitCode: 0) })
        -> AgentCliUpdater {
        AgentCliUpdater(home: home, run: run, isExecutable: { executables.contains($0) },
                        resolveLinks: { $0 }, log: { _ in })
    }

    func testCaskUpdateIsUnattended() {
        let install = AgentCliInstall(cli: .codex, path: "/opt/homebrew/bin/codex",
                                      resolvedPath: "/opt/homebrew/Caskroom/codex/1/bin/codex",
                                      method: .homebrewCask, package: "codex", prefix: "/opt/homebrew")
        let u = updater()
        XCTAssertEqual(u.refreshCommand(for: install)?.arguments, ["update", "--quiet"])
        let command = u.updateCommand(for: install)
        XCTAssertEqual(command?.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(command?.arguments, ["upgrade", "--cask", "codex"])
        XCTAssertEqual(command?.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(command?.environment["HOMEBREW_NO_ENV_HINTS"], "1")
        XCTAssertFalse(command?.display.contains("sudo") ?? true)
    }

    func testFormulaUpdate() {
        let install = AgentCliInstall(cli: .codex, path: "/usr/local/bin/codex", resolvedPath: "",
                                      method: .homebrewFormula, package: "codex", prefix: "/usr/local")
        let command = updater(executables: ["/usr/local/bin/brew"]).updateCommand(for: install)
        XCTAssertEqual(command?.executable, "/usr/local/bin/brew")
        XCTAssertEqual(command?.arguments, ["upgrade", "--formula", "codex"])
    }

    func testNpmUpdateUsesThePrefixNpm() {
        let install = AgentCliInstall(cli: .codex, path: "", resolvedPath: "", method: .npm,
                                      package: "@openai/codex", prefix: "/opt/homebrew")
        let command = updater().updateCommand(for: install)
        XCTAssertEqual(command?.executable, "/opt/homebrew/bin/npm")
        XCTAssertEqual(command?.arguments.first, "install")
        XCTAssertTrue(command?.arguments.contains("--global") ?? false)
        XCTAssertEqual(command?.arguments.last, "@openai/codex@latest")
        XCTAssertNil(updater().refreshCommand(for: install))
    }

    func testClaudeNativeUsesClaudeUpdate() {
        let install = AgentCliInstall(cli: .claude, path: "\(home)/.local/bin/claude", resolvedPath: "",
                                      method: .claudeNative)
        let command = updater().updateCommand(for: install)
        XCTAssertEqual(command?.executable, "\(home)/.local/bin/claude")
        XCTAssertEqual(command?.arguments, ["update"])
    }

    func testUnknownMethodIsLeftAlone() {
        let install = AgentCliInstall(cli: .codex, path: "/x/codex", resolvedPath: "/x/codex", method: .unknown)
        XCTAssertNil(updater().updateCommand(for: install))
    }

    // MARK: Parsing

    func testVersionParsing() {
        XCTAssertEqual(AgentCliUpdater.parseVersion("codex-cli 0.162.1\n"), "0.162.1")
        XCTAssertEqual(AgentCliUpdater.parseVersion("2.1.296 (Claude Code)"), "2.1.296")
        XCTAssertEqual(AgentCliUpdater.parseVersion("v1.2.3"), "1.2.3")
        XCTAssertNil(AgentCliUpdater.parseVersion("no version here"))
    }

    func testLatestFromBrewAndNpm() {
        let cask = #"{"casks":[{"token":"codex","version":"0.163.0","installed":"0.162.1"}],"formulae":[]}"#
        XCTAssertEqual(AgentCliUpdater.parseLatest(cask, method: .homebrewCask), "0.163.0")
        let formula = #"{"formulae":[{"name":"codex","versions":{"stable":"0.163.0"}}],"casks":[]}"#
        XCTAssertEqual(AgentCliUpdater.parseLatest(formula, method: .homebrewFormula), "0.163.0")
        XCTAssertEqual(AgentCliUpdater.parseLatest("0.163.0\n", method: .npm), "0.163.0")
    }

    // MARK: A whole run

    func testRunSkipsUpgradeWhenCurrentAndSkipsMissingCli() async {
        let log = CommandLog()
        let u = AgentCliUpdater(
            home: home,
            run: { command in
                await log.append(command.display)
                if command.arguments == ["--version"] { return ProcessOutput(stdout: "codex-cli 0.162.1", stderr: "", exitCode: 0) }
                if command.arguments.first == "info" {
                    return ProcessOutput(stdout: #"{"casks":[{"version":"0.162.1"}]}"#, stderr: "", exitCode: 0)
                }
                if command.arguments.contains("command -v claude") { return ProcessOutput(stdout: "", stderr: "", exitCode: 1) }
                return ProcessOutput(stdout: "", stderr: "", exitCode: 0)
            },
            isExecutable: { ["/opt/homebrew/bin/codex", "/opt/homebrew/bin/brew"].contains($0) },
            resolveLinks: { $0 == "/opt/homebrew/bin/codex" ? "/opt/homebrew/Caskroom/codex/0.162.1/bin/codex" : $0 },
            log: { _ in })
        let state = await u.run(checkOnly: false)
        let ran = await log.lines
        XCTAssertTrue(ran.contains("/opt/homebrew/bin/brew update --quiet"))
        XCTAssertFalse(ran.contains { $0.contains("upgrade") })
        XCTAssertEqual(state.statuses.first { $0.cli == .codex }?.message, "Up to date")
        XCTAssertEqual(state.statuses.first { $0.cli == .claude }?.installed, false)
        XCTAssertNotNil(state.lastChecked)
    }

    func testCheckOnlyKeepsTheSchedule() async {
        let u = updater(executables: [], run: { _ in ProcessOutput(stdout: "", stderr: "", exitCode: 1) })
        let earlier = Date(timeIntervalSince1970: 1000)
        let state = await u.run(checkOnly: true, previous: AgentCliUpdateState(lastChecked: earlier))
        XCTAssertEqual(state.lastChecked, earlier)
    }

    func testStaleness() {
        let now = Date()
        XCTAssertTrue(AgentCliUpdateState().isStale(now: now))
        XCTAssertFalse(AgentCliUpdateState(lastChecked: now.addingTimeInterval(-60)).isStale(now: now))
        XCTAssertTrue(AgentCliUpdateState(lastChecked: now.addingTimeInterval(-7 * 3600)).isStale(now: now))
    }
}

private actor CommandLog {
    var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
