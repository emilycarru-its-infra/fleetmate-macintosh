import Foundation

/// Why a SecureShell call ended the way it did. Distinguishes the cases an
/// operator treats differently: a host that is off, a host that refused the
/// key, a command that ran but failed, and a run that was stopped.
public enum SecureShellOutcome: String, Sendable, Codable {
    /// Connected, command ran, exit code 0.
    case success
    /// Connected, command ran, non-zero exit code.
    case commandFailed
    /// No TCP connection: host down, port closed, resolution failure, or connect timeout.
    case unreachable
    /// Connected, but the command exceeded its timeout.
    case timeout
    /// Connected, but the server rejected the key or username.
    case authFailed
    /// The caller cancelled the run.
    case cancelled
    /// Anything else.
    case error
}

/// Result of a streaming SSH run. Stdout was delivered live through the
/// chunk callback; stderr is collected here because it is what classifies
/// the outcome.
public struct SecureShellStreamResult: Sendable {
    public var outcome: SecureShellOutcome
    public var exitCode: Int32
    public var stderr: String
    public var duration: TimeInterval

    public init(outcome: SecureShellOutcome, exitCode: Int32, stderr: String, duration: TimeInterval) {
        self.outcome = outcome
        self.exitCode = exitCode
        self.stderr = stderr
        self.duration = duration
    }
}

/// Anything that can run a script on a remote address and stream its
/// output. `SecureShellService` is the real one; tests substitute a fake.
public protocol RemoteScriptExecutor: Sendable {
    func runStreaming(
        script: String,
        address: String,
        username: String?,
        timeout: TimeInterval?,
        onChunk: @escaping @Sendable (String) -> Void
    ) async -> SecureShellStreamResult

    /// Copy a local file to the remote address. Returns the exit code and stderr of scp.
    func copyFile(localPath: String, address: String, remotePath: String, username: String?) async -> (exitCode: Int32, stderr: String)
}

extension SecureShellService: @unchecked Sendable {}

extension SecureShellService: RemoteScriptExecutor {

    /// Classify an ssh exit code and stderr into an outcome. ssh itself exits
    /// 255 for every connection-level failure, so the text is what separates
    /// a host that is off from one that refused the key.
    public static func classify(exitCode: Int32, stderr: String) -> SecureShellOutcome {
        if exitCode == 0 { return .success }
        let text = stderr.lowercased()
        if exitCode == 255 || exitCode == -1 {
            if isAuthFailure(text) { return .authFailed }
            if isUnreachable(text) { return .unreachable }
            return .error
        }
        return .commandFailed
    }

    public static func isAuthFailure(_ lowercasedStderr: String) -> Bool {
        let patterns = [
            "permission denied",
            "publickey",
            "no mutual signature algorithm",
            "too many authentication failures",
            "authentication failed",
            "no supported authentication methods",
        ]
        return patterns.contains { lowercasedStderr.contains($0) }
    }

    public static func isUnreachable(_ lowercasedStderr: String) -> Bool {
        let patterns = [
            "connection refused",
            "connection timed out",
            "operation timed out",
            "timed out",
            "no route to host",
            "network is unreachable",
            "could not resolve hostname",
            "name or service not known",
            "nodename nor servname provided",
            "connection reset by peer",
            "connection closed by",
            "kex_exchange_identification",
            "host is down",
        ]
        return patterns.contains { lowercasedStderr.contains($0) }
    }

    /// The ssh argument list shared by the streaming runner and the session
    /// launchers: batch mode, no host-key prompts, keep-alives.
    public func streamingArguments(address: String, username: String?) -> [String] {
        var args = [
            "-T",
            "-o", "ConnectTimeout=\(max(1, min(config.connectionTimeoutSeconds, 10)))",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-p", "\(config.port)",
        ]
        if let keyPath = getPrivateKeyPath(), FileManager.default.fileExists(atPath: keyPath) {
            args.append(contentsOf: ["-i", keyPath])
        }
        args.append("\(username ?? config.defaultUsername)@\(address)")
        return args
    }

    /// Run `script` on `address` through `/bin/zsh -s` with the script on
    /// stdin, so nothing in it needs shell quoting. Stdout arrives through
    /// `onChunk` as it is produced. Cancelling the calling task terminates
    /// the ssh process; exceeding `timeout` does the same and reports
    /// `.timeout`.
    public func runStreaming(
        script: String,
        address: String,
        username: String? = nil,
        timeout: TimeInterval? = nil,
        onChunk: @escaping @Sendable (String) -> Void
    ) async -> SecureShellStreamResult {
        let arguments = streamingArguments(address: address, username: username) + ["/bin/zsh", "-s"]
        let limit = timeout ?? TimeInterval(config.commandTimeoutSeconds)
        return await StreamingProcess.run(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: script.hasSuffix("\n") ? script : script + "\n",
            timeout: limit,
            onChunk: onChunk
        )
    }

    /// How long one package copy may take before it is abandoned. A stalled
    /// transfer used to hold its slot forever and keep the whole run open.
    public static let copyTimeout: TimeInterval = 900

    /// scp a local file to the remote address. Keep-alives catch a host
    /// that vanishes mid-transfer; the timeout catches everything else.
    public func copyFile(localPath: String, address: String, remotePath: String, username: String? = nil) async -> (exitCode: Int32, stderr: String) {
        var args = [
            "-o", "ConnectTimeout=\(max(1, min(config.connectionTimeoutSeconds, 10)))",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-P", "\(config.port)",
        ]
        if let keyPath = getPrivateKeyPath(), FileManager.default.fileExists(atPath: keyPath) {
            args.append(contentsOf: ["-i", keyPath])
        }
        args.append(localPath)
        args.append("\(username ?? config.defaultUsername)@\(address):\(remotePath)")
        let result = await StreamingProcess.run(
            executable: "/usr/bin/scp", arguments: args, stdin: nil, timeout: Self.copyTimeout) { _ in }
        switch result.outcome {
        case .timeout:
            return (result.exitCode == 0 ? 1 : result.exitCode, "scp: transfer to \(address) timed out after \(Int(Self.copyTimeout))s")
        case .cancelled:
            return (result.exitCode == 0 ? 1 : result.exitCode, result.stderr.isEmpty ? "scp: cancelled" : result.stderr)
        default:
            return (result.exitCode, result.stderr)
        }
    }
}

/// A child process whose stdout is delivered as it arrives, with a timeout
/// and task cancellation that both terminate it. Closes every pipe end on
/// every path, for the same reason `ProcessRunner` does.
enum StreamingProcess {

    static func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        timeout: TimeInterval,
        onChunk: @escaping @Sendable (String) -> Void
    ) async -> SecureShellStreamResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let state = TerminationState()
        let exited = ExitSignal()
        process.terminationHandler = { _ in exited.signal() }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let chunk = String(data: data, encoding: .utf8) {
                onChunk(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close(); try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close(); try? errPipe.fileHandleForWriting.close()
            try? inPipe.fileHandleForReading.close(); try? inPipe.fileHandleForWriting.close()
            return SecureShellStreamResult(
                outcome: .error, exitCode: -1,
                stderr: "could not launch \(executable): \(error.localizedDescription)",
                duration: Date().timeIntervalSince(started))
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            // Written on a background queue: a script larger than the pipe
            // buffer would otherwise block here before the child reads.
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let timer = DispatchWorkItem {
            state.markTimedOut()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Collect stderr concurrently so a chatty stderr can never fill its
        // pipe and stall the child.
        let stderrTask = Task.detached(priority: .userInitiated) { () -> String in
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        }

        await withTaskCancellationHandler {
            await exited.wait()
        } onCancel: {
            state.markCancelled()
            if process.isRunning { process.terminate() }
        }

        timer.cancel()

        // Flush whatever stdout is left, then stop delivering.
        outPipe.fileHandleForReading.readabilityHandler = nil
        let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty, let chunk = String(data: remaining, encoding: .utf8) {
            onChunk(chunk)
        }
        let stderr = await stderrTask.value

        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        try? inPipe.fileHandleForReading.close()

        let exitCode = process.terminationStatus
        let duration = Date().timeIntervalSince(started)
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if state.cancelled {
            return SecureShellStreamResult(outcome: .cancelled, exitCode: exitCode, stderr: trimmedErr, duration: duration)
        }
        if state.timedOut {
            return SecureShellStreamResult(outcome: .timeout, exitCode: exitCode, stderr: trimmedErr, duration: duration)
        }
        let outcome = SecureShellService.classify(exitCode: exitCode, stderr: trimmedErr)
        return SecureShellStreamResult(outcome: outcome, exitCode: exitCode, stderr: trimmedErr, duration: duration)
    }

    /// Bridges `Process.terminationHandler` to an awaitable, whichever fires
    /// first: the handler may run before anyone waits, so the signal is latched.
    private final class ExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var continuation: CheckedContinuation<Void, Never>?

        func signal() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                fired = true
                let c = continuation
                continuation = nil
                return c
            }
            pending?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if fired { return true }
                    continuation = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
    }

    /// Why the process was terminated, if we did it.
    private final class TerminationState: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false
        private var _cancelled = false

        var timedOut: Bool { lock.withLock { _timedOut } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        func markTimedOut() { lock.withLock { _timedOut = true } }
        func markCancelled() { lock.withLock { _cancelled = true } }
    }
}
