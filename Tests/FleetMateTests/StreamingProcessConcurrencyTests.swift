import XCTest
@testable import FleetMateCore

/// `StreamingProcess` must never hold a thread while a child runs: a
/// session that parks a cooperative-pool thread in a blocking read pins
/// one thread per child, and once every pool thread is pinned the kernel
/// stops handing threads to the global queues that carry the stdin write
/// and the timeout. Ten sessions on an 8-core laptop left every remote
/// shell waiting for a script that never arrived, with no timeout to end
/// it. These tests run more sessions than there are cores.
final class StreamingProcessConcurrencyTests: XCTestCase {

    private var manySessions: Int { ProcessInfo.processInfo.activeProcessorCount * 2 + 2 }

    func testMoreSessionsThanCoresAllFinishWithTheirScript() async throws {
        let count = manySessions
        let results = try await TimeBox.run(seconds: 30) { () -> [Int: SecureShellStreamResult] in
            await withTaskGroup(of: (Int, SecureShellStreamResult, String).self) { group in
                for i in 0..<count {
                    group.addTask {
                        let output = OutputBox()
                        let result = await StreamingProcess.run(
                            executable: "/bin/cat", arguments: [], stdin: "session-\(i)\n", timeout: 20
                        ) { output.append($0) }
                        return (i, result, output.text)
                    }
                }
                var all: [Int: SecureShellStreamResult] = [:]
                for await (i, result, text) in group {
                    XCTAssertEqual(text, "session-\(i)\n", "session \(i) echoed its own script")
                    all[i] = result
                }
                return all
            }
        }
        let finished = try XCTUnwrap(results, "every session finished inside the box")
        XCTAssertEqual(finished.count, count)
        XCTAssertTrue(finished.values.allSatisfy { $0.outcome == .success && $0.exitCode == 0 })
    }

    func testTimeoutTerminatesTheChildAndReportsIt() async throws {
        let started = Date()
        let result = try await TimeBox.run(seconds: 30) {
            await StreamingProcess.run(executable: "/bin/sleep", arguments: ["60"], stdin: nil, timeout: 0.5) { _ in }
        }
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.outcome, .timeout)
        XCTAssertNotEqual(outcome.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTimeoutStillFiresWhileMoreSessionsThanCoresAreRunning() async throws {
        let count = manySessions
        let started = Date()
        let results = try await TimeBox.run(seconds: 40) { () -> [SecureShellStreamResult] in
            await withTaskGroup(of: SecureShellStreamResult.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        await StreamingProcess.run(executable: "/bin/sleep", arguments: ["60"], stdin: nil, timeout: 1) { _ in }
                    }
                }
                var all: [SecureShellStreamResult] = []
                for await result in group { all.append(result) }
                return all
            }
        }
        let finished = try XCTUnwrap(results)
        XCTAssertEqual(finished.count, count)
        XCTAssertTrue(finished.allSatisfy { $0.outcome == .timeout })
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testStderrIsCollectedAndClassified() async throws {
        let result = await StreamingProcess.run(
            executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"], stdin: nil, timeout: 10
        ) { _ in }
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.outcome, .commandFailed)
    }

    func testAChildThatExitsBeforeReadingItsScriptDoesNotCrashUs() async throws {
        let big = String(repeating: "x", count: 200_000) + "\n"
        let result = await StreamingProcess.run(executable: "/usr/bin/true", arguments: [], stdin: big, timeout: 10) { _ in }
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCancellationStopsTheChild() async throws {
        let task = Task {
            await StreamingProcess.run(executable: "/bin/sleep", arguments: ["60"], stdin: nil, timeout: 60) { _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = try await TimeBox.run(seconds: 15) { await task.value }
        XCTAssertEqual(try XCTUnwrap(result).outcome, .cancelled)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        func append(_ s: String) { lock.withLock { buffer += s } }
        var text: String { lock.withLock { buffer } }
    }
}
