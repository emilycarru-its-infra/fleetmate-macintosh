import XCTest
@testable import FleetMateCore

/// A scripted executor: each address maps to the chunks it emits and the
/// result it ends with. Records concurrency so the gate can be checked.
final class FakeExecutor: RemoteScriptExecutor, @unchecked Sendable {
    struct Reply {
        var chunks: [String]
        var result: SecureShellStreamResult
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    var replies: [String: Reply]
    var copyExit: Int32 = 0
    private(set) var scripts: [String] = []
    private(set) var copies: [(String, String)] = []
    private var inFlight = 0
    private(set) var peakInFlight = 0

    init(replies: [String: Reply]) {
        self.replies = replies
    }

    static func ok(_ chunks: String...) -> Reply {
        Reply(chunks: chunks, result: SecureShellStreamResult(outcome: .success, exitCode: 0, stderr: "", duration: 0))
    }

    func runStreaming(script: String, address: String, username: String?, timeout: TimeInterval?,
                      onChunk: @escaping @Sendable (String) -> Void) async -> SecureShellStreamResult {
        lock.withLock { scripts.append(script); inFlight += 1; peakInFlight = max(peakInFlight, inFlight) }
        defer { lock.withLock { inFlight -= 1 } }
        guard let reply = replies[address] else {
            return SecureShellStreamResult(outcome: .unreachable, exitCode: 255, stderr: "ssh: connect to host \(address) port 22: Operation timed out", duration: 0)
        }
        if reply.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(reply.delay * 1_000_000_000)) }
        if Task.isCancelled {
            return SecureShellStreamResult(outcome: .cancelled, exitCode: 15, stderr: "", duration: 0)
        }
        for chunk in reply.chunks { onChunk(chunk) }
        return reply.result
    }

    func copyFile(localPath: String, address: String, remotePath: String, username: String?) async -> (exitCode: Int32, stderr: String) {
        lock.withLock { copies.append((address, remotePath)) }
        return (copyExit, copyExit == 0 ? "" : "scp: Permission denied (publickey).")
    }
}

/// Collects runner events in order, safely from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [CommandRunner.Event] = []
    func append(_ e: CommandRunner.Event) { lock.withLock { events.append(e) } }

    func output(for serial: String) -> String {
        events.compactMap { if case .output(let s, let c) = $0, s == serial { return c } else { return nil } }.joined()
    }

    func finished(for serial: String) -> SecureShellStreamResult? {
        events.compactMap { if case .finished(let s, let r) = $0, s == serial { return r } else { return nil } }.first
    }

    func cancelled(_ serial: String) -> Bool {
        events.contains { if case .cancelled(let s) = $0 { return s == serial } else { return false } }
    }
}

final class CommandRunnerTests: XCTestCase {
    func target(_ serial: String, _ ip: String) -> CommandRunner.Target {
        CommandRunner.Target(computer: RosterComputer(serial: serial, hostname: "host-\(serial)"), ip: ip)
    }

    func testStreamsPerHostAndClassifies() async {
        let executor = FakeExecutor(replies: [
            "10.0.0.1": FakeExecutor.ok("hello ", "world\n"),
            "10.0.0.2": FakeExecutor.Reply(chunks: ["partial"], result: SecureShellStreamResult(outcome: .commandFailed, exitCode: 3, stderr: "boom", duration: 0)),
            "10.0.0.3": FakeExecutor.Reply(chunks: [], result: SecureShellStreamResult(outcome: .authFailed, exitCode: 255, stderr: "Permission denied (publickey).", duration: 0)),
        ])
        let runner = CommandRunner(executor: executor, concurrency: 4)
        let log = EventLog()
        await runner.run(script: "uptime", on: [target("A", "10.0.0.1"), target("B", "10.0.0.2"), target("C", "10.0.0.3"), target("D", "10.0.0.4")]) { log.append($0) }

        XCTAssertEqual(log.output(for: "A"), "hello world\n")
        XCTAssertEqual(log.finished(for: "A")?.outcome, .success)
        XCTAssertEqual(log.output(for: "B"), "partial")
        XCTAssertEqual(log.finished(for: "B")?.outcome, .commandFailed)
        XCTAssertEqual(log.finished(for: "B")?.exitCode, 3)
        XCTAssertEqual(log.finished(for: "C")?.outcome, .authFailed)
        XCTAssertEqual(log.finished(for: "D")?.outcome, .unreachable)
        XCTAssertEqual(executor.scripts, Array(repeating: "uptime", count: 4))
    }

    func testConcurrencyGateIsHonoured() async {
        var replies: [String: FakeExecutor.Reply] = [:]
        for i in 0..<12 {
            replies["10.0.1.\(i)"] = FakeExecutor.Reply(chunks: [], result: SecureShellStreamResult(outcome: .success, exitCode: 0, stderr: "", duration: 0), delay: 0.05)
        }
        let executor = FakeExecutor(replies: replies)
        let runner = CommandRunner(executor: executor, concurrency: 3)
        let targets = (0..<12).map { target("T\($0)", "10.0.1.\($0)") }
        let log = EventLog()
        await runner.run(script: "true", on: targets) { log.append($0) }
        XCTAssertEqual(executor.peakInFlight, 3)
        XCTAssertEqual(log.events.filter { if case .finished = $0 { return true } else { return false } }.count, 12)
    }

    func testCancellationStopsPendingWork() async {
        var replies: [String: FakeExecutor.Reply] = [:]
        for i in 0..<6 {
            replies["10.0.2.\(i)"] = FakeExecutor.Reply(chunks: ["x"], result: SecureShellStreamResult(outcome: .success, exitCode: 0, stderr: "", duration: 0), delay: 0.3)
        }
        let executor = FakeExecutor(replies: replies)
        let runner = CommandRunner(executor: executor, concurrency: 2)
        let targets = (0..<6).map { target("T\($0)", "10.0.2.\($0)") }
        let log = EventLog()

        let task = Task { await runner.run(script: "sleep 1", on: targets) { log.append($0) } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await task.value

        let finished = log.events.filter { if case .finished = $0 { return true } else { return false } }.count
        let cancelled = log.events.filter { if case .cancelled = $0 { return true } else { return false } }.count
        XCTAssertEqual(finished + cancelled, 6, "every target is accounted for")
        XCTAssertGreaterThanOrEqual(cancelled, 4, "the ones that had not started, and the two in flight, are cancelled")
    }

    func testInstallPackageCopiesThenInstalls() async {
        let executor = FakeExecutor(replies: ["10.0.3.1": FakeExecutor.ok("installer: The install was successful.\n")])
        let runner = CommandRunner(executor: executor, concurrency: 1)
        let log = EventLog()
        await runner.installPackage(localPath: "/tmp/Fleet Mate's.pkg", on: [target("P", "10.0.3.1")]) { log.append($0) }
        XCTAssertEqual(executor.copies.count, 1)
        XCTAssertTrue(executor.copies[0].1.hasPrefix("/private/tmp/FleetMate-"))
        let script = executor.scripts[0]
        XCTAssertTrue(script.contains("sudo /usr/sbin/installer -pkg '/private/tmp/FleetMate-"))
        XCTAssertTrue(script.contains("trap 'rm -f"))
        XCTAssertTrue(script.contains("'Fleet Mate'\\''s.pkg'"), script)
        XCTAssertTrue(log.output(for: "P").hasPrefix("Copying Fleet Mate's.pkg to host-P"))
        XCTAssertEqual(log.finished(for: "P")?.outcome, .success)
    }

    func testInstallPackageStopsWhenCopyFails() async {
        let executor = FakeExecutor(replies: ["10.0.3.1": FakeExecutor.ok()])
        executor.copyExit = 1
        let runner = CommandRunner(executor: executor, concurrency: 1)
        let log = EventLog()
        await runner.installPackage(localPath: "/tmp/x.pkg", on: [target("P", "10.0.3.1")]) { log.append($0) }
        XCTAssertTrue(executor.scripts.isEmpty, "no install without a copy")
        XCTAssertEqual(log.finished(for: "P")?.outcome, .authFailed)
    }

    func testMachineProbeServiceClassifies() async {
        let executor = FakeExecutor(replies: [
            "10.0.4.1": FakeExecutor.ok("user=alice\nos=15.6\nssh_port=listening\n"),
            "10.0.4.2": FakeExecutor.Reply(chunks: [], result: SecureShellStreamResult(outcome: .authFailed, exitCode: 255, stderr: "Permission denied (publickey).", duration: 0)),
            "10.0.4.3": FakeExecutor.Reply(chunks: ["garbage"], result: SecureShellStreamResult(outcome: .commandFailed, exitCode: 1, stderr: "zsh: oops", duration: 0)),
        ])
        let service = MachineProbeService(executor: executor, concurrency: 2)
        let results = OutcomeLog()
        await service.probeAll([target("A", "10.0.4.1"), target("B", "10.0.4.2"), target("C", "10.0.4.3"), target("D", "10.0.4.4")]) { serial, outcome in
            results.set(serial, outcome)
        }
        if case .info(let info) = results.get("A") {
            XCTAssertEqual(info.consoleUser, "alice")
            XCTAssertEqual(info.hostname, "host-A")
        } else { XCTFail("A should parse") }
        if case .authFailed = results.get("B") {} else { XCTFail("B is auth failed") }
        if case .failed(let why) = results.get("C") { XCTAssertEqual(why, "zsh: oops") } else { XCTFail("C failed") }
        if case .unreachable = results.get("D") {} else { XCTFail("D is unreachable") }

        let single = await service.probe(target("A", "10.0.4.1"))
        if case .info(let info) = single { XCTAssertEqual(info.osVersion, "15.6") } else { XCTFail() }
    }

    final class OutcomeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: MachineProbeService.ProbeOutcome] = [:]
        func set(_ k: String, _ v: MachineProbeService.ProbeOutcome) { lock.withLock { map[k] = v } }
        func get(_ k: String) -> MachineProbeService.ProbeOutcome? { lock.withLock { map[k] } }
    }
}

/// The real process runner against a local shell: this is what the SSH
/// path uses, with `/bin/zsh -s` standing in for `ssh … /bin/zsh -s`.
final class StreamingProcessTests: XCTestCase {

    func testStreamsStdoutAndReturnsExitCode() async {
        let collector = OutputCollector()
        let result = await StreamingProcess.run(
            executable: "/bin/zsh", arguments: ["-s"],
            stdin: "echo one; echo two 1>&2; echo three; exit 4\n",
            timeout: 10) { collector.append($0) }
        XCTAssertEqual(collector.text, "one\nthree\n")
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertEqual(result.stderr, "two")
        XCTAssertEqual(result.outcome, .commandFailed)
    }

    func testScriptOnStdinNeedsNoQuoting() async {
        let collector = OutputCollector()
        let script = """
        X="it's \\"quoted\\" $HOME"
        printf '%s\\n' "$X" | sed 's/quoted/fine/'
        """
        let result = await StreamingProcess.run(executable: "/bin/zsh", arguments: ["-s"], stdin: script, timeout: 10) { collector.append($0) }
        XCTAssertEqual(result.outcome, .success)
        XCTAssertTrue(collector.text.hasPrefix("it's \"fine\" /"), collector.text)
    }

    func testTimeoutTerminatesTheProcess() async {
        let started = Date()
        let result = await StreamingProcess.run(executable: "/bin/zsh", arguments: ["-s"], stdin: "echo start; sleep 30; echo never\n", timeout: 0.5) { _ in }
        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancellationTerminatesTheProcess() async {
        let started = Date()
        let task = Task {
            await StreamingProcess.run(executable: "/bin/zsh", arguments: ["-s"], stdin: "sleep 30\n", timeout: 60) { _ in }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLaunchFailureIsAnError() async {
        let result = await StreamingProcess.run(executable: "/nonexistent/binary", arguments: [], stdin: nil, timeout: 1) { _ in }
        XCTAssertEqual(result.outcome, .error)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertTrue(result.stderr.contains("could not launch"))
    }

    func testLargeOutputDoesNotDeadlock() async {
        let collector = OutputCollector()
        let result = await StreamingProcess.run(
            executable: "/bin/zsh", arguments: ["-s"],
            stdin: "for i in {1..20000}; do echo \"line $i of a reasonably long string to fill the pipe\"; done; echo err >&2\n",
            timeout: 30) { collector.append($0) }
        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(collector.text.components(separatedBy: "\n").count - 1, 20000)
    }

    func testRepeatedRunsDoNotLeakDescriptors() async {
        func openCount() -> Int { (0..<Int32(4096)).filter { fcntl($0, F_GETFD) != -1 }.count }
        _ = await StreamingProcess.run(executable: "/bin/echo", arguments: ["warm"], stdin: nil, timeout: 5) { _ in }
        let before = openCount()
        for _ in 0..<40 {
            _ = await StreamingProcess.run(executable: "/bin/zsh", arguments: ["-s"], stdin: "echo hi\n", timeout: 5) { _ in }
        }
        XCTAssertLessThanOrEqual(openCount(), before + 3)
    }
}

/// Opt-in check against a real fleet host. Set FLEETMATE_LIVE_SSH_HOST to
/// an address the configured key can reach.
final class SecureShellLiveTests: XCTestCase {
    func testLiveStreamingProbeAndClassification() async throws {
        guard let host = ProcessInfo.processInfo.environment["FLEETMATE_LIVE_SSH_HOST"], !host.isEmpty else {
            throw XCTSkip("FLEETMATE_LIVE_SSH_HOST not set")
        }
        let config = try FleetMateConfig.load()
        var ssh = config.secureShell ?? SecureShellConfig()
        if let key = ProcessInfo.processInfo.environment["FLEETMATE_LIVE_SSH_KEY"] { ssh.privateKeyPath = key }
        if let user = ProcessInfo.processInfo.environment["FLEETMATE_LIVE_SSH_USER"] { ssh.defaultUsername = user }
        let service = SecureShellService(config: ssh)

        let collector = OutputCollector()
        let result = await service.runStreaming(script: "hostname; sw_vers -productVersion", address: host) { collector.append($0) }
        XCTAssertEqual(result.outcome, .success, result.stderr)
        XCTAssertFalse(collector.text.isEmpty)

        let probe = await MachineProbeService(executor: service).probe(.init(computer: .adhoc(hostname: host, ip: host), ip: host))
        if case .info(let info) = probe { XCTAssertFalse(info.osVersion.isEmpty) } else { XCTFail("probe did not parse: \(probe)") }

        let wrongUser = await service.runStreaming(script: "true", address: host, username: "definitely-not-a-user") { _ in }
        XCTAssertEqual(wrongUser.outcome, .authFailed, wrongUser.stderr)
    }
}
