import ArgumentParser
import Foundation
import FleetMateCore

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage the agent CLIs FleetMate's terminal runs",
        subcommands: [AgentUpdateCommand.self]
    )
}

struct AgentUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update codex and claude to their latest versions",
        discussion: """
        Finds each agent CLI, works out how it was installed (Homebrew cask or \
        formula, npm global, or Claude Code's native installer) and updates it \
        with that same tool, non-interactively. CLIs that are not installed are \
        skipped; nothing is installed and nothing runs with sudo. The FleetMate \
        app does the same in the background every six hours.
        """
    )

    @Flag(name: .long, help: "Report versions and install methods without updating")
    var check = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json = false

    func run() async throws {
        // Progress goes to the log, which also echoes to stderr.
        let updater = AgentCliUpdater()
        let state = await updater.run(checkOnly: check, previous: AgentCliUpdateState.load())
        state.save()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(state), as: UTF8.self))
            return
        }
        for status in state.statuses {
            let name = status.cli.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            guard status.installed else {
                print("\(name)not installed")
                continue
            }
            let version = (status.version ?? "?").padding(toLength: 12, withPad: " ", startingAt: 0)
            let method = (status.method?.displayName ?? "").padding(toLength: 26, withPad: " ", startingAt: 0)
            print("\(name)\(version)\(method)\(status.message ?? "")")
            if let path = status.path { print("        \(path)") }
        }
    }
}
