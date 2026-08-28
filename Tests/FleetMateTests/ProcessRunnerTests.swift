import XCTest
@testable import FleetMateCore

final class ProcessRunnerTests: XCTestCase {

    /// Number of descriptors this process currently holds open.
    private func openFileDescriptorCount() -> Int {
        var count = 0
        for fd in Int32(0)..<Int32(8192) where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// The regression this type exists for.
    ///
    /// Building a `Process` with two `Pipe`s and reading them inline leaks the
    /// two read descriptors per spawn — `Process` closes only the write ends,
    /// and `readDataToEndOfFile()` reads to EOF without closing. A GUI app
    /// inherits `RLIMIT_NOFILE` of 256, so a poller calling `gh auth token`
    /// on a timer exhausted the table after a few hundred spawns and then
    /// failed to launch anything for the rest of the process's life.
    func testRepeatedSpawnsDoNotLeakFileDescriptors() {
        // Warm up first: the first spawn pulls in lazily-initialised machinery
        // that legitimately opens descriptors, and that is not a leak.
        _ = ProcessRunner.runSync("/bin/echo", ["warmup"])

        let before = openFileDescriptorCount()
        for _ in 0..<100 {
            _ = ProcessRunner.runSync("/bin/echo", ["hello"])
        }
        let after = openFileDescriptorCount()

        // The old pattern grew by 2 per spawn — 200 for this loop. Allow a
        // small allowance for unrelated runtime activity, but nothing that
        // scales with the number of spawns.
        XCTAssertLessThanOrEqual(
            after - before, 10,
            "descriptors grew by \(after - before) over 100 spawns — the pipe read ends are leaking again"
        )
    }

    func testCapturesStdoutAndExitCode() {
        let result = ProcessRunner.runSync("/bin/echo", ["hello"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCapturesStderrAndNonZeroExit() {
        let result = ProcessRunner.runSync("/bin/sh", ["-c", "echo problem >&2; exit 3"])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.stderr.contains("problem"))
    }

    /// Reading the two streams in sequence deadlocks once the one read second
    /// fills its ~64 KB pipe buffer. Draining concurrently is what prevents it.
    func testLargeOutputOnBothStreamsDoesNotDeadlock() {
        let script = "yes abcdefghij | head -c 300000; yes klmnopqrst | head -c 300000 >&2"
        let result = ProcessRunner.runSync("/bin/sh", ["-c", script])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.stderr.count, 300_000)
    }

    /// A missing tool reports a launch failure rather than trapping, and must
    /// not leak the descriptors it opened on the way to failing.
    func testMissingExecutableReportsLaunchFailure() {
        let before = openFileDescriptorCount()
        for _ in 0..<50 {
            let result = ProcessRunner.runSync("/nonexistent/tool-that-is-not-here", [])
            XCTAssertEqual(result.exitCode, -1)
            XCTAssertTrue(result.stderr.contains("could not launch"))
        }
        let after = openFileDescriptorCount()
        XCTAssertLessThanOrEqual(
            after - before, 10,
            "descriptors leaked on the launch-failure path"
        )
    }

    func testResolveFindsAbsolutePathsAndPassesThroughUnknownNames() {
        XCTAssertEqual(ProcessRunner.resolve("/bin/echo"), "/bin/echo")
        XCTAssertEqual(ProcessRunner.resolve("echo"), "/bin/echo")
        // Not installed anywhere we look — hand the bare name to the env fallback.
        XCTAssertEqual(ProcessRunner.resolve("tool-that-is-not-here"), "tool-that-is-not-here")
    }
}
