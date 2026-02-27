import ArgumentParser
import Foundation
import FleetMateCore
import Rainbow

/// SecureShell command - Execute commands on remote devices
struct SecureShellCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Execute commands on remote devices",
        discussion: """
            Connect to fleet devices via SSH to run diagnostics, retrieve logs,
            or execute Munki-related commands.
            """,
        subcommands: [
            ExecSubcommand.self,
            BatchSubcommand.self,
            TestSubcommand.self,
            LogsSubcommand.self,
            MunkiSubcommand.self
        ],
        defaultSubcommand: ExecSubcommand.self
    )
}

// MARK: - Execute Command

struct ExecSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Execute a command on a remote device"
    )
    
    @Argument(help: "Device identifier (hostname, serial, or IP)")
    var device: String
    
    @Argument(parsing: .remaining, help: "Command to execute")
    var command: [String]
    
    @Option(name: .shortAndLong, help: "SecureShell username (default: from config)")
    var user: String?
    
    @Option(name: .shortAndLong, help: "Timeout in seconds")
    var timeout: Int = 30
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured. Set SECURE_SHELL_PRIVATE_KEY_PATH or Key Vault settings.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        let commandString = command.joined(separator: " ")
        
        print("Connecting to \(device)...".cyan)
        
        let result = try await sshService.execute(
            host: device,
            command: commandString,
            username: user
        )
        
        if json {
            let output = CommandOutput(
                host: device,
                command: commandString,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                duration: result.durationSeconds
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            if result.exitCode == 0 {
                print("\n" + "Command succeeded".green + " (exit code 0)\n")
            } else {
                print("\n" + "Command failed".red + " (exit code \(result.exitCode))\n")
            }
            
            if !result.stdout.isEmpty {
                print("STDOUT:".bold)
                print(result.stdout)
            }
            
            if !result.stderr.isEmpty {
                print("STDERR:".yellow.bold)
                print(result.stderr)
            }
            
            print("\n" + "Duration: \(String(format: "%.2f", result.durationSeconds))s".lightBlack)
        }
        
        if result.exitCode != 0 {
            throw ExitCode(Int32(result.exitCode))
        }
    }
}

// MARK: - Batch Execute

struct BatchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Execute a command on multiple devices"
    )
    
    @Argument(parsing: .remaining, help: "Device identifiers")
    var devices: [String]
    
    @Option(name: .shortAndLong, help: "Command to execute on all devices")
    var command: String
    
    @Option(name: .shortAndLong, help: "SecureShell username")
    var user: String?
    
    @Option(name: .shortAndLong, help: "Maximum concurrent connections")
    var concurrency: Int = 5
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    @Flag(name: .long, help: "Continue even if some hosts fail")
    var continueOnError: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured.".red)
            throw ExitCode.failure
        }
        
        guard !devices.isEmpty else {
            print("[ERROR] No devices specified.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        
        print("Executing on \(devices.count) devices...".cyan)
        
        let batchResult = try await sshService.executeBatch(
            hosts: devices,
            command: command,
            username: user
        )
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(BatchOutput(from: batchResult))
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printBatchResults(batchResult)
        }
        
        if batchResult.failedCount > 0 && !continueOnError {
            throw ExitCode.failure
        }
    }
    
    private func printBatchResults(_ result: SecureShellBatchResult) {
        print("\n" + "Batch Execution Results".bold + "\n")
        
        let successRate = Double(result.successCount) / Double(result.totalCount) * 100
        
        print("Summary: \(result.successCount)/\(result.totalCount) succeeded (\(String(format: "%.0f", successRate))%)")
        print("Total duration: \(String(format: "%.2fs", result.totalDurationSeconds))")
        print("")
        
        for cmdResult in result.results {
            let statusIcon = cmdResult.exitCode == 0 ? "yes" : "no"
            let hostDisplay = cmdResult.exitCode == 0 ? cmdResult.host.green : cmdResult.host.red
            print("\(statusIcon) \(hostDisplay)")
            
            if cmdResult.exitCode != 0 {
                print("   Exit code: \(cmdResult.exitCode)")
                if !cmdResult.stderr.isEmpty {
                    let truncated = cmdResult.stderr.prefix(100)
                    print("   Error: \(truncated)")
                }
            }
        }
    }
}

// MARK: - Test Connection

struct TestSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Test SecureShell connectivity to a device"
    )
    
    @Argument(help: "Device identifier (hostname, serial, or IP)")
    var device: String
    
    @Option(name: .shortAndLong, help: "SecureShell username")
    var user: String?
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        
        print("Testing connection to \(device)...".cyan)
        
        let result = try await sshService.testConnection(host: device, username: user)
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            if result.success {
                print("\n[ok] " + "Connection successful!".green.bold)
                print("   Host: \(result.host)")
                print("   Duration: \(String(format: "%.0fms", result.durationSeconds * 1000))")
                if let version = result.serverVersion {
                    print("   SecureShell: \(version)")
                }
            } else {
                print("\n[error] " + "Connection failed!".red.bold)
                print("   Host: \(result.host)")
                if let error = result.errorMessage {
                    print("   Error: \(error)")
                }
            }
        }
        
        if !result.success {
            throw ExitCode.failure
        }
    }
}

// MARK: - Get Logs

struct LogsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Retrieve Munki logs from a device"
    )
    
    @Argument(help: "Device identifier")
    var device: String
    
    @Option(name: .shortAndLong, help: "Number of lines to retrieve")
    var lines: Int = 100
    
    @Option(name: .shortAndLong, help: "Log file to retrieve")
    var logFile: String = "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log"
    
    @Flag(name: .shortAndLong, help: "Follow log output (like tail -f)")
    var follow: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        
        print("📋 Retrieving logs from \(device)...".cyan)
        
        let result = try await sshService.getLogs(
            host: device,
            tailLines: lines,
            errorsOnly: false
        )
        
        if result.exitCode == 0 {
            print("\n" + "Log output from \(device):".bold + "\n")
            print(result.stdout)
        } else {
            print("[ERROR] Failed to retrieve logs: \(result.stderr)".red)
            throw ExitCode.failure
        }
    }
}

// MARK: - Munki Commands

struct MunkiSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "munki",
        abstract: "Run Munki-related commands on a device",
        subcommands: [
            MunkiCheckSubcommand.self,
            MunkiPrefsSubcommand.self,
            MunkiInstallSubcommand.self
        ],
        defaultSubcommand: MunkiCheckSubcommand.self
    )
}

struct MunkiCheckSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run managedsoftwareupdate --checkonly"
    )
    
    @Argument(help: "Device identifier")
    var device: String
    
    @Flag(name: .shortAndLong, help: "Run with auto install (not just check)")
    var install: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        
        let action = install ? "Running Munki install" : "Running Munki check"
        print("🍎 \(action) on \(device)...".cyan)
        
        let result = try await sshService.runMunkiCheck(host: device, autoInstall: install)
        
        if result.exitCode == 0 {
            print("\n[ok] " + "Munki check completed successfully".green)
            if !result.stdout.isEmpty {
                print("\nOutput:".bold)
                print(result.stdout)
            }
        } else {
            print("\n[error] " + "Munki check failed".red)
            print("Exit code: \(result.exitCode)")
            if !result.stderr.isEmpty {
                print("Error: \(result.stderr)")
            }
            throw ExitCode.failure
        }
    }
}

struct MunkiPrefsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefs",
        abstract: "Get Munki preferences from a device"
    )
    
    @Argument(help: "Device identifier")
    var device: String
    
    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        
        print("📋 Getting Munki preferences from \(device)...".cyan)
        
        let result = try await sshService.getMunkiPrefs(host: device)
        
        if result.exitCode != 0 {
            print("[ERROR] Failed to get Munki preferences: \(result.stderr)".red)
            throw ExitCode.failure
        }
        
        // Parse the output - defaults read outputs "key = value" format
        let prefs = parseMunkiPrefs(result.stdout)
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(prefs)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("\n" + "Munki Preferences".bold + "\n")
            for (key, value) in prefs.sorted(by: { $0.key < $1.key }) {
                print("  \(key.cyan): \(value)")
            }
        }
    }
    
    private func parseMunkiPrefs(_ output: String) -> [String: String] {
        var prefs: [String: String] = [:]
        
        // Parse defaults read output format:
        // {
        //     Key = value;
        //     ...
        // }
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("}") || trimmed.isEmpty {
                continue
            }
            
            // Split on " = "
            if let range = trimmed.range(of: " = ") {
                let key = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                
                // Remove trailing semicolon and quotes
                if value.hasSuffix(";") {
                    value = String(value.dropLast())
                }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                
                prefs[key] = value
            }
        }
        
        return prefs
    }
}

struct MunkiInstallSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Force install a specific item"
    )
    
    @Argument(help: "Device identifier")
    var device: String
    
    @Argument(help: "Item name to install")
    var item: String
    
    func run() async throws {
        let config = try FleetMateConfig.load()
        
        guard config.isSecureShellConfigured else {
            print("[ERROR] SecureShell not configured.".red)
            throw ExitCode.failure
        }
        
        let sshService = SecureShellService(fleetConfig: config)
        
        print("Installing \(item) on \(device)...".cyan)
        
        // First add to SelfServe manifest, then run check
        let installCmd = """
            sudo /usr/local/munki/managedsoftwareupdate --installonly --munkipkgsonly && \
            sudo /usr/local/munki/managedsoftwareupdate --installonly
            """
        
        let result = try await sshService.execute(host: device, command: installCmd)
        
        if result.exitCode == 0 {
            print("\n[ok] " + "Installation triggered successfully".green)
        } else {
            print("\n[error] " + "Installation failed".red)
            print("Exit code: \(result.exitCode)")
            if !result.stderr.isEmpty {
                print("Error: \(result.stderr)")
            }
            throw ExitCode.failure
        }
    }
}

// MARK: - Output Models

struct CommandOutput: Codable {
    let host: String
    let command: String
    let exitCode: Int
    let stdout: String
    let stderr: String
    let duration: TimeInterval
}

struct BatchOutput: Codable {
    let successCount: Int
    let failedCount: Int
    let totalCount: Int
    let totalDuration: TimeInterval
    let results: [SecureShellResult]
    
    init(from result: SecureShellBatchResult) {
        self.successCount = result.successCount
        self.failedCount = result.failedCount
        self.totalCount = result.totalCount
        self.totalDuration = result.totalDurationSeconds
        self.results = result.results
    }
}
