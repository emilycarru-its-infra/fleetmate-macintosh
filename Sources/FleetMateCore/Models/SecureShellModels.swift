import Foundation

// MARK: - SecureShell Configuration

/// SecureShell connection configuration
public struct SecureShellConfig: Codable {
    /// Path to private key file (supports ~ for home directory)
    public var privateKeyPath: String
    
    /// Environment variable containing the private key content (for Azure Key Vault)
    public var privateKeyEnvVar: String?
    
    /// Azure Key Vault name for retrieving the private key
    public var keyVaultName: String?
    
    /// Default username for SecureShell connections
    public var defaultUsername: String
    
    /// Connection timeout in seconds
    public var connectionTimeoutSeconds: Int
    
    /// Command execution timeout in seconds
    public var commandTimeoutSeconds: Int
    
    /// Maximum concurrent SecureShell connections for batch operations
    public var maxConcurrentConnections: Int
    
    /// Default SecureShell port
    public var port: Int
    
    public init(
        privateKeyPath: String = "~/.ssh/id_rsa",
        privateKeyEnvVar: String? = "SECURE_SHELL_PRIVATE_KEY",
        keyVaultName: String? = nil,
        defaultUsername: String = "ithelp",
        connectionTimeoutSeconds: Int = 30,
        commandTimeoutSeconds: Int = 120,
        maxConcurrentConnections: Int = 10,
        port: Int = 22
    ) {
        self.privateKeyPath = privateKeyPath
        self.privateKeyEnvVar = privateKeyEnvVar
        self.keyVaultName = keyVaultName
        self.defaultUsername = defaultUsername
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.maxConcurrentConnections = maxConcurrentConnections
        self.port = port
    }
    
    /// Resolves the private key path, expanding ~ to home directory
    public var resolvedKeyPath: String {
        if privateKeyPath.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return privateKeyPath.replacingOccurrences(of: "~", with: home)
        }
        return privateKeyPath
    }
    
    /// Gets the private key content from environment variable if configured
    public func getPrivateKeyFromEnv() -> String? {
        guard let envVar = privateKeyEnvVar, !envVar.isEmpty else { return nil }
        return ProcessInfo.processInfo.environment[envVar]
    }
    
    enum CodingKeys: String, CodingKey {
        case privateKeyPath = "private_key_path"
        case privateKeyEnvVar = "private_key_env_var"
        case keyVaultName = "key_vault_name"
        case defaultUsername = "default_username"
        case connectionTimeoutSeconds = "connection_timeout_seconds"
        case commandTimeoutSeconds = "command_timeout_seconds"
        case maxConcurrentConnections = "max_concurrent_connections"
        case port
    }
}

// MARK: - SecureShell Result

/// Result of a SecureShell command execution
public struct SecureShellResult: Codable {
    /// Target host (IP address or hostname)
    public var host: String
    
    /// Device name if resolved from ReportMate
    public var deviceName: String?
    
    /// Username used for connection
    public var username: String
    
    /// Command that was executed
    public var command: String
    
    /// Exit code from the command (0 = success)
    public var exitCode: Int
    
    /// Standard output from the command
    public var stdout: String
    
    /// Standard error from the command
    public var stderr: String
    
    /// Duration of command execution in seconds
    public var durationSeconds: Double
    
    /// Timestamp when command started
    public var startedAt: Date
    
    /// Error message if connection or command failed
    public var errorMessage: String?
    
    /// Whether the command executed successfully (exit code 0 and no error)
    public var success: Bool {
        return exitCode == 0 && errorMessage == nil
    }
    
    /// Whether the connection was established (may have failed command)
    public var connected: Bool
    
    public init(
        host: String = "",
        deviceName: String? = nil,
        username: String = "",
        command: String = "",
        exitCode: Int = -1,
        stdout: String = "",
        stderr: String = "",
        durationSeconds: Double = 0,
        startedAt: Date = Date(),
        errorMessage: String? = nil,
        connected: Bool = false
    ) {
        self.host = host
        self.deviceName = deviceName
        self.username = username
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.errorMessage = errorMessage
        self.connected = connected
    }
    
    enum CodingKeys: String, CodingKey {
        case host
        case deviceName = "device_name"
        case username
        case command
        case exitCode = "exit_code"
        case stdout
        case stderr
        case durationSeconds = "duration_seconds"
        case startedAt = "started_at"
        case errorMessage = "error_message"
        case connected
    }
}

// MARK: - Batch Result

/// Result of batch SecureShell execution
public struct SecureShellBatchResult: Codable {
    /// Individual results for each host
    public var results: [SecureShellResult]
    
    /// Total execution time in seconds
    public var totalDurationSeconds: Double
    
    /// Number of successful executions
    public var successCount: Int {
        return results.filter { $0.success }.count
    }
    
    /// Number of failed executions
    public var failedCount: Int {
        return results.filter { !$0.success }.count
    }
    
    /// Total hosts processed
    public var totalCount: Int {
        return results.count
    }
    
    public init(results: [SecureShellResult] = [], totalDurationSeconds: Double = 0) {
        self.results = results
        self.totalDurationSeconds = totalDurationSeconds
    }
    
    enum CodingKeys: String, CodingKey {
        case results
        case totalDurationSeconds = "total_duration_seconds"
    }
}

// MARK: - Test Result

/// Result of SecureShell connection test
public struct SecureShellTestResult: Codable {
    public var host: String
    public var deviceName: String?
    public var username: String
    public var success: Bool
    public var errorMessage: String?
    public var durationSeconds: Double
    public var serverVersion: String?
    
    public init(
        host: String = "",
        deviceName: String? = nil,
        username: String = "",
        success: Bool = false,
        errorMessage: String? = nil,
        durationSeconds: Double = 0,
        serverVersion: String? = nil
    ) {
        self.host = host
        self.deviceName = deviceName
        self.username = username
        self.success = success
        self.errorMessage = errorMessage
        self.durationSeconds = durationSeconds
        self.serverVersion = serverVersion
    }
    
    enum CodingKeys: String, CodingKey {
        case host
        case deviceName = "device_name"
        case username
        case success
        case errorMessage = "error_message"
        case durationSeconds = "duration_seconds"
        case serverVersion = "server_version"
    }
}
