import Foundation
import Logging

/// SecureShell service for remote command execution on fleet devices
/// Uses native macOS ssh command for reliable SSH connectivity
/// Future: Can be enhanced to use SwiftNIO SSH for pure Swift implementation
public class SecureShellService {
    private let config: SecureShellConfig
    private let reportMate: ReportMateService?
    private let logger = Logger(label: "com.fleetmate.ssh")
    private let connectionSemaphore: DispatchSemaphore
    
    public init(config: SecureShellConfig, reportMate: ReportMateService? = nil) {
        self.config = config
        self.reportMate = reportMate
        self.connectionSemaphore = DispatchSemaphore(value: config.maxConcurrentConnections)
    }
    
    /// Convenience initializer from FleetMateConfig
    public convenience init(fleetConfig: FleetMateConfig) {
        let sshConfig = fleetConfig.secureShell ?? SecureShellConfig()
        let reportMate = fleetConfig.isReportMateConfigured ?
            ReportMateService(config: fleetConfig) : nil
        self.init(config: sshConfig, reportMate: reportMate)
    }
    
    // MARK: - Host Resolution
    
    /// Resolve a device identifier to an IP address
    public func resolveHost(_ hostOrDevice: String) async throws -> (ip: String, device: ReportMateDevice?) {
        // If it looks like an IP address, return it directly
        if isIPAddress(hostOrDevice) {
            var device: ReportMateDevice? = nil
            if let rm = reportMate {
                let devices = try await rm.getDevices()
                device = devices.first { $0.ipAddress == hostOrDevice }
            }
            return (hostOrDevice, device)
        }
        
        // Try to resolve via ReportMate
        if let rm = reportMate {
            if let device = try await rm.findDevice(hostOrDevice) {
                // Device found - try to get IP from device, or fetch network module
                if !device.ipAddress.isEmpty {
                    logger.debug("Resolved \(hostOrDevice) to IP \(device.ipAddress) (\(device.displayName))")
                    return (device.ipAddress, device)
                }
                
                // Fetch network module to get IP address
                if let networkInfo = try await rm.getDeviceNetwork(device.serialNumber),
                   let primaryIp = networkInfo.primaryIpv4 {
                    logger.debug("Resolved \(hostOrDevice) to IP \(primaryIp) (\(device.displayName)) via network module")
                    return (primaryIp, device)
                }
                
                // Fall back to hostname if available
                if !device.hostname.isEmpty {
                    logger.debug("Resolved \(hostOrDevice) to hostname \(device.hostname) (\(device.displayName))")
                    return (device.hostname, device)
                }
            }
        }
        
        // Assume it's a hostname that can be resolved by DNS
        logger.debug("Using \(hostOrDevice) as hostname (no IP resolution)")
        return (hostOrDevice, nil)
    }
    
    // MARK: - Command Execution
    
    /// Execute a command on a single host
    public func execute(host hostOrDevice: String, command: String, username: String? = nil) async throws -> SecureShellResult {
        let effectiveUsername = username ?? config.defaultUsername
        var result = SecureShellResult(
            username: effectiveUsername,
            command: command,
            startedAt: Date()
        )
        
        let startTime = Date()
        
        do {
            let (ip, device) = try await resolveHost(hostOrDevice)
            result.host = ip
            result.deviceName = device?.displayName
            
            // Build SSH command
            let sshResult = try await runSSHCommand(
                host: ip,
                username: result.username,
                command: command
            )
            
            result.connected = true
            result.exitCode = sshResult.exitCode
            result.stdout = sshResult.stdout
            result.stderr = sshResult.stderr
            
            logger.debug("Command on \(ip) completed with exit code \(result.exitCode)")
        } catch {
            result.errorMessage = error.localizedDescription
            logger.warning("SecureShell command failed on \(result.host): \(error.localizedDescription)")
        }
        
        result.durationSeconds = Date().timeIntervalSince(startTime)
        return result
    }
    
    /// Execute a command on multiple hosts in parallel
    public func executeBatch(
        hosts hostsOrDevices: [String],
        command: String,
        username: String? = nil,
        stopOnError: Bool = false
    ) async throws -> SecureShellBatchResult {
        let startTime = Date()
        var results: [SecureShellResult] = []
        var shouldStop = false
        
        logger.info("Starting batch execution on \(hostsOrDevices.count) hosts")
        
        // Use task group for concurrent execution with semaphore throttling
        await withTaskGroup(of: SecureShellResult.self) { group in
            for host in hostsOrDevices {
                if shouldStop { break }
                
                group.addTask {
                    // Throttle concurrent connections
                    self.connectionSemaphore.wait()
                    defer { self.connectionSemaphore.signal() }
                    
                    do {
                        return try await self.execute(host: host, command: command, username: username)
                    } catch {
                        var result = SecureShellResult()
                        result.host = host
                        result.command = command
                        result.username = username ?? self.config.defaultUsername
                        result.errorMessage = error.localizedDescription
                        return result
                    }
                }
            }
            
            for await result in group {
                results.append(result)
                
                if stopOnError && !result.success {
                    logger.warning("Stopping batch execution due to error on \(result.host)")
                    shouldStop = true
                    group.cancelAll()
                    break
                }
            }
        }
        
        let totalDuration = Date().timeIntervalSince(startTime)
        
        logger.info("Batch execution completed: \(results.filter { $0.success }.count)/\(results.count) succeeded in \(String(format: "%.2f", totalDuration))s")
        
        return SecureShellBatchResult(results: results, totalDurationSeconds: totalDuration)
    }
    
    /// Test SecureShell connectivity to a host
    public func testConnection(host hostOrDevice: String, username: String? = nil) async throws -> SecureShellTestResult {
        var result = SecureShellTestResult(
            username: username ?? config.defaultUsername
        )
        
        let startTime = Date()
        
        do {
            let (ip, device) = try await resolveHost(hostOrDevice)
            result.host = ip
            result.deviceName = device?.displayName
            
            // Run a simple command to test connectivity
            let testResult = try await runSSHCommand(
                host: ip,
                username: result.username,
                command: "echo connected && uname -a"
            )
            
            result.success = testResult.exitCode == 0
            result.serverVersion = testResult.stdout.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !result.success {
                result.errorMessage = testResult.stderr
            }
            
            logger.info("SecureShell test to \(ip) (\(result.deviceName ?? "unknown")): \(result.success ? "Success" : "Failed")")
        } catch {
            result.success = false
            result.errorMessage = error.localizedDescription
            logger.warning("SecureShell test to \(result.host) failed: \(error.localizedDescription)")
        }
        
        result.durationSeconds = Date().timeIntervalSince(startTime)
        return result
    }
    
    /// Get Munki logs from a remote device
    public func getLogs(
        host hostOrDevice: String,
        tailLines: Int = 50,
        errorsOnly: Bool = false,
        username: String? = nil
    ) async throws -> SecureShellResult {
        let logPath = "/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log"
        
        let command: String
        if errorsOnly {
            command = "tail -n \(tailLines) '\(logPath)' | grep -E 'ERROR|WARN|CRITICAL'"
        } else {
            command = "tail -n \(tailLines) '\(logPath)'"
        }
        
        return try await execute(host: hostOrDevice, command: command, username: username)
    }
    
    /// Run Munki check on a remote device
    public func runMunkiCheck(host hostOrDevice: String, autoInstall: Bool = false, username: String? = nil) async throws -> SecureShellResult {
        let command = autoInstall ? 
            "sudo /usr/local/munki/managedsoftwareupdate --auto" :
            "sudo /usr/local/munki/managedsoftwareupdate --checkonly"
        return try await execute(host: hostOrDevice, command: command, username: username)
    }
    
    /// Get Munki preferences from a remote device
    public func getMunkiPrefs(host hostOrDevice: String, username: String? = nil) async throws -> SecureShellResult {
        let command = "defaults read /Library/Preferences/ManagedInstalls"
        return try await execute(host: hostOrDevice, command: command, username: username)
    }
    
    // MARK: - Private Helpers
    
    private func runSSHCommand(host: String, username: String, command: String) async throws -> (exitCode: Int, stdout: String, stderr: String) {
        // Determine key path
        let keyPath = getPrivateKeyPath()
        
        // Build SSH arguments
        var sshArgs = ["-o", "StrictHostKeyChecking=no",
                       "-o", "UserKnownHostsFile=/dev/null",
                       "-o", "BatchMode=yes",
                       "-o", "ConnectTimeout=\(config.connectionTimeoutSeconds)"]
        
        if let keyPath = keyPath, FileManager.default.fileExists(atPath: keyPath) {
            sshArgs.append(contentsOf: ["-i", keyPath])
        }
        
        sshArgs.append(contentsOf: ["-p", "\(config.port)"])
        sshArgs.append("\(username)@\(host)")
        sshArgs.append(command)
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                
                continuation.resume(returning: (Int(process.terminationStatus), stdout, stderr))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func getPrivateKeyPath() -> String? {
        // Try multiple key sources in order:
        // 1. Environment variable content (write to temp file)
        if let keyContent = config.getPrivateKeyFromEnv(), !keyContent.isEmpty {
            return writeKeyToTempFile(keyContent)
        }
        
        // 2. Keychain
        if let keyContent = KeychainService.shared.get(.sshPrivateKey), !keyContent.isEmpty {
            return writeKeyToTempFile(keyContent)
        }
        
        // 3. File path from config
        let keyPath = config.resolvedKeyPath
        if FileManager.default.fileExists(atPath: keyPath) {
            return keyPath
        }
        
        // 4. Default SSH key locations
        let defaultPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/id_ed25519",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh/id_rsa"
        ]
        
        for path in defaultPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func writeKeyToTempFile(_ keyContent: String) -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let keyFile = tempDir.appendingPathComponent("fleetmate_ssh_key_\(UUID().uuidString)")
        
        do {
            try keyContent.write(to: keyFile, atomically: true, encoding: .utf8)
            // Set proper permissions (600)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            
            // Schedule cleanup after a short delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                try? FileManager.default.removeItem(at: keyFile)
            }
            
            return keyFile.path
        } catch {
            logger.error("Failed to write SSH key to temp file: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func isIPAddress(_ string: String) -> Bool {
        // Simple check for IPv4 address pattern
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            if let num = Int(part) {
                return num >= 0 && num <= 255
            }
            return false
        }
    }
}

// MARK: - Azure Key Vault Support

extension SecureShellService {
    /// Attempt to retrieve SecureShell key from Azure Key Vault using az CLI
    public func getKeyFromKeyVault(_ vaultName: String) async -> String? {
        let azPath = findAzureCli()
        guard let azPath = azPath else { return nil }
        
        let args = ["keyvault", "secret", "show",
                    "--vault-name", vaultName,
                    "--name", "SecureShellPrivateKey",
                    "--query", "value",
                    "-o", "tsv"]
        
        do {
            let result = try await runProcess(azPath, arguments: args)
            if result.exitCode == 0 && !result.stdout.isEmpty {
                logger.debug("Retrieved SecureShell key from Key Vault \(vaultName)")
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.debug("Failed to get SecureShell key from Key Vault: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func findAzureCli() -> String? {
        let candidates = [
            "/usr/local/bin/az",
            "/opt/homebrew/bin/az",
            "/usr/bin/az"
        ]
        
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        
        // Check PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let azPath = "\(dir)/az"
                if FileManager.default.fileExists(atPath: azPath) {
                    return azPath
                }
            }
        }
        
        return nil
    }
    
    private func runProcess(_ path: String, arguments: [String]) async throws -> (exitCode: Int, stdout: String, stderr: String) {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                
                continuation.resume(returning: (Int(process.terminationStatus), stdout, stderr))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
