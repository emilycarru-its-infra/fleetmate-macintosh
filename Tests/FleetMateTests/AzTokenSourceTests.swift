import XCTest
@testable import FleetMateCore

/// Each resource's token is fetched on its own and within a time limit, so a
/// stalled `az` for one resource never leaves the others waiting.
final class AzTokenSourceTests: XCTestCase {
    private static func output(_ token: String) -> ProcessOutput {
        ProcessOutput(stdout: token + "\n", stderr: "", exitCode: 0)
    }

    func testAStalledResourceDoesNotBlockAnother() async throws {
        let source = AzTokenSource(azPath: "az", timeout: .seconds(30)) { args in
            if args.contains("https://slow.example.com") {
                try? await Task.sleep(for: .seconds(5))
                return Self.output("slow")
            }
            return Self.output("fast")
        }

        let slow = Task { try await source.token(forResource: "https://slow.example.com") }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        let fast = try await source.token(forResource: "https://fast.example.com")

        XCTAssertEqual(fast, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        slow.cancel()
    }

    func testAStallEndsInAnError() async {
        let source = AzTokenSource(azPath: "az", timeout: .milliseconds(200)) { _ in
            try? await Task.sleep(for: .seconds(10))
            return Self.output("late")
        }

        do {
            _ = try await source.token(forResource: "https://stalled.example.com")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("did not answer"), "\(error)")
        }
    }

    func testCachesUntilInvalidated() async throws {
        let calls = Counter()
        let source = AzTokenSource(azPath: "az", timeout: .seconds(5)) { _ in
            let n = await calls.next()
            return Self.output("token-\(n)")
        }

        let first = try await source.token(forResource: "https://cached.example.com")
        let second = try await source.token(forResource: "https://cached.example.com")
        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(second, "token-1")
        await source.invalidate()
        let third = try await source.token(forResource: "https://cached.example.com")
        XCTAssertEqual(third, "token-2")
    }

    func testAFailedAzCallReportsWhy() async {
        let source = AzTokenSource(azPath: "az", timeout: .seconds(5)) { _ in
            ProcessOutput(stdout: "", stderr: "Please run 'az login'", exitCode: 1)
        }
        do {
            _ = try await source.token(forScope: "api://example/.default")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("az login"), "\(error)")
        }
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

/// A provider that failed the load has no count to show.
final class PullRequestQueueFailureTests: XCTestCase {
    func testAFailedProviderIsReportedAndOthersAreNot() {
        let queue = PullRequestQueue(errors: [PullRequestQueueError(source: .gitHub, message: "API rate limit exceeded")])
        XCTAssertTrue(queue.failed(.gitHub))
        XCTAssertFalse(queue.failed(.azureDevOps))
        XCTAssertTrue(queue.failed())
    }

    func testAQueueWithNoErrorsHasNoFailures() {
        XCTAssertFalse(PullRequestQueue().failed())
    }
}
