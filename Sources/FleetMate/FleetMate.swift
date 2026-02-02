import ArgumentParser
import Foundation

@main
struct FleetMate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleetmate",
        abstract: "FleetMate - Fleet orchestration, inventory, deployment monitoring, and troubleshooting",
        version: "1.0.0",
        subcommands: [
            // Core commands
            StatusCommand.self,
            DeviceCommand.self,
            ErrorsCommand.self,
            TroubleshootCommand.self,
            
            // Remote access
            SecureShellCommand.self,
            
            // Configuration
            ConfigureCommand.self,
            
            // Validation
            LintCommand.self,
            ValidateCommand.self,
            
            // Service integrations
            SnipeCommand.self,
            MunkiReportCommand.self,  // Legacy - use ReportMate via DeviceCommand
            IntuneCommand.self,
            EntraCommand.self,
            DevOpsCommand.self,
            TdxCommand.self,
            
            // Unified task management (FleetMate Boards)
            TasksCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
}
