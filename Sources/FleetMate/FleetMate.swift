import ArgumentParser
import Foundation

@main
struct FleetMate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleetmate",
        abstract: "FleetMate - Fleet orchestration, inventory, deployment monitoring, and troubleshooting",
        version: "1.0.0",
        subcommands: [
            LoginCommand.self,
            StatusCommand.self,
            ValidateCommand.self,
            SnipeCommand.self,
            MunkiReportCommand.self,
            IntuneCommand.self,
            AutopilotCommand.self,
            EntraCommand.self,
            DevOpsCommand.self,
            PullRequestsCommand.self,
            TdxCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
}
