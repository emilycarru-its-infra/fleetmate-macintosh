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
            ManageCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )

    // No flags at the root. A root --json used to sit here and, because
    // ArgumentParser hands a name to the first command that declares it,
    // it swallowed every subcommand's --json: `fleetmate validate --json`
    // printed text while `-j` worked. Each subcommand owns its own flags.
}
