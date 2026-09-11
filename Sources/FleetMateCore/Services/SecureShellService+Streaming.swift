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
/// and task cancellation that both terminate it.
///
/// Nothing in here blocks a thread. The pipes are drained by `DispatchIO`
/// on a private queue, the script is written the same way, and the caller
/// only ever suspends on a continuation. The previous version parked a
/// detached task in `readDataToEndOfFile()` for every running session, which
/// pins one cooperative-pool thread per child. On an 8-core laptop ten
/// sessions took every pool thread; the kernel then refused threads to the
/// global queues that carried the stdin write and the timeout, so the remote
/// shell waited forever for a script that never arrived and the timer never
/// fired. Private queues target the overcommit root and are not subject to
/// that limit, and DispatchIO never holds a thread while it waits.
enum StreamingProcess {

    /// How long a terminated child may take to actually die before it is
    /// killed, and how long its pipes may stay open after it exits before
    /// the drain gives up on them.
    static let gracePeriod: TimeInterval = 5

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

        let queue = DispatchQueue(label: "fleetmate.streaming-process", qos: .userInitiated, attributes: .concurrent)
        let state = TerminationState()
        let stderrBuffer = ByteBuffer()
        let drains = DrainSet()

        // Exit, stdout EOF and stderr EOF each hold the group once; the run
        // is over when all three have let go.
        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { _ in
            finished.leave()
            // A grandchild that inherited the pipes could keep them open
            // after ssh itself is gone; do not wait on it forever.
            queue.asyncAfter(deadline: .now() + gracePeriod) { drains.stopAll() }
        }

        do {
            try process.run()
        } catch {
            finished.leave()
            try? outPipe.fileHandleForReading.close(); try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close(); try? errPipe.fileHandleForWriting.close()
            try? inPipe.fileHandleForReading.close(); try? inPipe.fileHandleForWriting.close()
            return SecureShellStreamResult(
                outcome: .error, exitCode: -1,
                stderr: "could not launch \(executable): \(error.localizedDescription)",
                duration: Date().timeIntervalSince(started))
        }
        // From here on the child-side ends belong to Foundation, which closed
        // its copies when the child was spawned; only our ends are touched.

        drains.add(drain(outPipe.fileHandleForReading, queue: queue, group: finished) { data in
            onChunk(String(decoding: data, as: UTF8.self))
        })
        drains.add(drain(errPipe.fileHandleForReading, queue: queue, group: finished) { data in
            stderrBuffer.append(data)
        })
        if let stdin, let data = stdin.data(using: .utf8) {
            feed(inPipe.fileHandleForWriting, data: data, queue: queue)
        }

        let timer = DispatchWorkItem {
            state.markTimedOut()
            stop(process, queue: queue)
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                finished.notify(queue: queue) { continuation.resume() }
            }
        } onCancel: {
            state.markCancelled()
            stop(process, queue: queue)
        }
        timer.cancel()
        drains.closeAll()
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        let exitCode = process.terminationStatus
        let duration = Date().timeIntervalSince(started)
        let trimmedErr = stderrBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines)

        if state.cancelled {
            return SecureShellStreamResult(outcome: .cancelled, exitCode: exitCode, stderr: trimmedErr, duration: duration)
        }
        if state.timedOut {
            return SecureShellStreamResult(outcome: .timeout, exitCode: exitCode, stderr: trimmedErr, duration: duration)
        }
        let outcome = SecureShellService.classify(exitCode: exitCode, stderr: trimmedErr)
        return SecureShellStreamResult(outcome: outcome, exitCode: exitCode, stderr: trimmedErr, duration: duration)
    }

    /// Ask the child to stop, and make sure it does.
    private static func stop(_ process: Process, queue: DispatchQueue) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + gracePeriod) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Read `handle` to EOF through DispatchIO, handing every chunk to
    /// `onData` on `queue`, and leave `group` once when the stream ends.
    private static func drain(
        _ handle: FileHandle,
        queue: DispatchQueue,
        group: DispatchGroup,
        onData: @escaping @Sendable (Data) -> Void
    ) -> DispatchIO {
        group.enter()
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in }
        channel.setLimit(lowWater: 1)
        let ended = OnceFlag()
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty {
                onData(data.withUnsafeBytes { Data(bytes: $0, count: data.count) })
            }
            if done, ended.first() { group.leave() }
        }
        return channel
    }

    /// Write `data` to `handle` through DispatchIO and close it so the
    /// child sees EOF. A child that exits early makes the write fail with
    /// EPIPE, which must not raise SIGPIPE in this process.
    private static func feed(_ handle: FileHandle, data: Data, queue: DispatchQueue) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            try? handle.close()
        }
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: queue) { done, _, _ in
            if done { channel.close() }
        }
    }

    /// The DispatchIO channels draining a child's pipes, so an exit that
    /// leaves them open can still end the run.
    private final class DrainSet: @unchecked Sendable {
        private let lock = NSLock()
        private var channels: [DispatchIO] = []

        func add(_ channel: DispatchIO) { lock.withLock { channels.append(channel) } }
        /// Abort outstanding reads: their handlers run once more with `done`.
        func stopAll() { lock.withLock { channels }.forEach { $0.close(flags: .stop) } }
        func closeAll() { lock.withLock { channels }.forEach { $0.close() } }
    }

    /// Bytes collected from arbitrary queues.
    private final class ByteBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// True exactly once.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
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
