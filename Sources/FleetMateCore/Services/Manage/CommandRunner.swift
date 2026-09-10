import Foundation

/// Runs one script on many machines at once, streaming each machine's
/// output as it arrives. Cancelling the calling task stops every SSH
/// process; results that had not finished are reported as cancelled.
public struct CommandRunner: Sendable {
    public struct Target: Sendable {
        public var computer: RosterComputer
        public var ip: String

        public init(computer: RosterComputer, ip: String) {
            self.computer = computer
            self.ip = ip
        }
    }

    public enum Event: Sendable {
        case started(serial: String)
        case output(serial: String, chunk: String)
        case finished(serial: String, result: SecureShellStreamResult)
        case cancelled(serial: String)
    }

    private let executor: RemoteScriptExecutor
    public var concurrency: Int
    public var username: String?
    public var timeout: TimeInterval?

    public init(executor: RemoteScriptExecutor, concurrency: Int = 10, username: String? = nil, timeout: TimeInterval? = nil) {
        self.executor = executor
        self.concurrency = max(1, concurrency)
        self.username = username
        self.timeout = timeout
    }

    /// Run `script` on every target. `onEvent` is called from arbitrary
    /// threads; callers hop to the main actor themselves.
    public func run(script: String, on targets: [Target], onEvent: @escaping @Sendable (Event) -> Void) async {
        await runEach(targets, onEvent: onEvent) { target, onChunk in
            await executor.runStreaming(script: script, address: target.ip, username: username, timeout: timeout, onChunk: onChunk)
        }
    }

    /// Copy a package to each target and install it with the system installer.
    public func installPackage(localPath: String, on targets: [Target], onEvent: @escaping @Sendable (Event) -> Void) async {
        let packageName = URL(fileURLWithPath: localPath).lastPathComponent
        await runEach(targets, onEvent: onEvent) { target, onChunk in
            let remotePath = "/private/tmp/FleetMate-\(UUID().uuidString).pkg"
            onChunk("Copying \(packageName) to \(target.computer.displayName)…\n")
            let copy = await executor.copyFile(localPath: localPath, address: target.ip, remotePath: remotePath, username: username)
            guard copy.exitCode == 0 else {
                // scp exits 1 for everything, so only the message can tell a
                // refused key from an unreachable host from a missing file.
                let byMessage = SecureShellService.classify(exitCode: 255, stderr: copy.stderr)
                let outcome: SecureShellOutcome = byMessage == .error ? .commandFailed : byMessage
                return SecureShellStreamResult(outcome: outcome, exitCode: copy.exitCode, stderr: copy.stderr, duration: 0)
            }
            onChunk("Installing \(packageName)…\n")
            let quotedPath = Self.shellSingleQuoted(remotePath)
            let script = """
            set -e
            trap 'rm -f \(quotedPath)' EXIT
            sudo /usr/sbin/installer -pkg \(quotedPath) -target /
            printf 'Installed %s\\n' \(Self.shellSingleQuoted(packageName))
            """
            return await executor.runStreaming(script: script, address: target.ip, username: username, timeout: timeout, onChunk: onChunk)
        }
    }

    private func runEach(
        _ targets: [Target],
        onEvent: @escaping @Sendable (Event) -> Void,
        body: @escaping @Sendable (Target, @escaping @Sendable (String) -> Void) async -> SecureShellStreamResult
    ) async {
        guard !targets.isEmpty else { return }
        let limit = concurrency
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            func launch(_ target: Target) {
                group.addTask {
                    let serial = target.computer.serial
                    guard !Task.isCancelled else { onEvent(.cancelled(serial: serial)); return }
                    onEvent(.started(serial: serial))
                    let result = await body(target) { chunk in onEvent(.output(serial: serial, chunk: chunk)) }
                    if result.outcome == .cancelled {
                        onEvent(.cancelled(serial: serial))
                    } else {
                        onEvent(.finished(serial: serial, result: result))
                    }
                }
            }
            while index < targets.count && index < limit { launch(targets[index]); index += 1 }
            while await group.next() != nil {
                if index < targets.count { launch(targets[index]); index += 1 }
            }
        }
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Fetches `MachineInfo` for online machines over SSH and tells apart a
/// host that refused the key from one that merely did not answer.
public struct MachineProbeService: Sendable {
    public enum ProbeOutcome: Sendable {
        case info(MachineInfo)
        case authFailed
        case unreachable
        case failed(String)
    }

    private let executor: RemoteScriptExecutor
    public var concurrency: Int
    public var username: String?

    public init(executor: RemoteScriptExecutor, concurrency: Int = 10, username: String? = nil) {
        self.executor = executor
        self.concurrency = max(1, concurrency)
        self.username = username
    }

    public func probe(_ target: CommandRunner.Target) async -> ProbeOutcome {
        let collector = OutputCollector()
        let result = await executor.runStreaming(
            script: MachineProbe.script, address: target.ip, username: username, timeout: 30
        ) { chunk in collector.append(chunk) }
        let output = collector.text
        if MachineProbe.looksLikeProbeOutput(output) {
            return .info(MachineProbe.parse(hostname: target.computer.hostname, ip: target.ip, raw: output))
        }
        switch result.outcome {
        case .authFailed: return .authFailed
        case .unreachable, .timeout: return .unreachable
        default: return .failed(result.stderr)
        }
    }

    /// Probe many targets, reporting each as it completes.
    public func probeAll(_ targets: [CommandRunner.Target], onResult: @escaping @Sendable (String, ProbeOutcome) -> Void) async {
        let runner = CommandRunner(executor: executor, concurrency: concurrency, username: username, timeout: 30)
        let collectors = OutputCollectors()
        await runner.run(script: MachineProbe.script, on: targets) { event in
            switch event {
            case .started: break
            case .output(let serial, let chunk): collectors.append(serial: serial, chunk: chunk)
            case .finished(let serial, let result):
                let output = collectors.text(serial: serial)
                if MachineProbe.looksLikeProbeOutput(output),
                   let target = targets.first(where: { $0.computer.serial == serial }) {
                    onResult(serial, .info(MachineProbe.parse(hostname: target.computer.hostname, ip: target.ip, raw: output)))
                } else {
                    switch result.outcome {
                    case .authFailed: onResult(serial, .authFailed)
                    case .unreachable, .timeout: onResult(serial, .unreachable)
                    default: onResult(serial, .failed(result.stderr))
                    }
                }
            case .cancelled(let serial): onResult(serial, .unreachable)
            }
        }
    }
}

/// Thread-safe accumulation of streamed chunks.
public final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    public init() {}

    public func append(_ chunk: String) { lock.withLock { buffer += chunk } }
    public var text: String { lock.withLock { buffer } }
}

final class OutputCollectors: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [String: String] = [:]

    func append(serial: String, chunk: String) { lock.withLock { buffers[serial, default: ""] += chunk } }
    func text(serial: String) -> String { lock.withLock { buffers[serial] ?? "" } }
}
