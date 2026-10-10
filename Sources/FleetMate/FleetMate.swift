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
            ConfigureCommand.self,
            ValidateCommand.self,
            LintCommand.self,
            ErrorsCommand.self,
            TroubleshootCommand.self,
            DeviceCommand.self,
            SecureShellCommand.self,
            ArdCommand.self,
            WipeCommand.self,
            LockCommand.self,
            UnlockCommand.self,
            CimianCommand.self,
            ReportMateCommand.self,
            DeadlineCommand.self,
            SnipeCommand.self,
            IntuneCommand.self,
            AutopilotCommand.self,
            EntraCommand.self,
            PimCommand.self,
            ElevateCommand.self,
            DevOpsCommand.self,
            PullRequestsCommand.self,
            TasksCommand.self,
            ProjectsCommand.self,
            TdxCommand.self,
            ManageCommand.self,
            ReposCommand.self,
            AgentCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )

    // No flags at the root. A root --json used to sit here and, because
    // ArgumentParser hands a name to the first command that declares it,
    // it swallowed every subcommand's --json: `fleetmate validate --json`
    // printed text while `-j` worked. Each subcommand owns its own flags.
}
