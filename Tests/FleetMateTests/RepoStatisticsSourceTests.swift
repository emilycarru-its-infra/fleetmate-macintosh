import XCTest
@testable import FleetMateCore

final class RepoStatisticsSourceTests: XCTestCase {
    private var directory: URL!
    private var copy: GitWorkingCopy!
    private var manager: RepoManager!
    private var record: RepoRecord!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        copy = GitWorkingCopy(path: directory.path)
        manager = RepoManager(store: RepoRegistryStore(
            registryPath: directory.appendingPathComponent("registry.json").path,
            catalogPath: directory.appendingPathComponent("catalog.json").path
        ))
        let key = RepoKey(provider: .gitHub, owner: "example-org", name: "sample")
        record = RepoRecord(key: key, catalog: nil, local: RepoRegistryEntry(key: key, path: directory.path, tracked: true))
        try await git(["init", "-q", "-b", "main"])
        try await git(["config", "user.name", "Example Author"])
        try await git(["config", "user.email", "author@example.com"])
        try await git(["config", "commit.gpgsign", "false"])
        try await commit("base.txt", contents: "base\n", date: "2026-01-01T12:00:00Z")
        try await git(["checkout", "-q", "-b", "remote-history"])
        try await commit("remote.txt", contents: "remote one\nremote two\n", date: "2026-02-01T12:00:00Z")
        try await git(["update-ref", RepoStatistics.insightsRef, "HEAD"])
        try await git(["checkout", "-q", "main"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStaleLocalMainDoesNotLimitInsights() async throws {
        let report = try await manager.stats(for: record, since: nil, ref: RepoStatistics.insightsRef)
        XCTAssertEqual(report.totals.commits, 2)
        XCTAssertEqual(report.totals.added, 3)
        XCTAssertEqual(report.timeline.reduce(0) { $0 + $1.commits }, 2)
        XCTAssertTrue(report.files.contains { $0.path == "remote.txt" })
        let checkoutReport = try await manager.stats(for: record, since: nil)
        XCTAssertEqual(checkoutReport.totals.commits, 1)
    }

    func testFeatureBranchDoesNotEnterSingleOrCombinedInsights() async throws {
        // This local branch also shadows Git's short spelling of the remote ref.
        try await git(["checkout", "-q", "-b", "origin/main"])
        try await commit("feature.txt", contents: String(repeating: "local\n", count: 100), date: "2026-03-01T12:00:00Z")
        let report = try await manager.stats(for: record, since: nil, ref: RepoStatistics.insightsRef)
        let summary = await manager.statsSummary(for: [record], since: nil, ref: RepoStatistics.insightsRef)
        XCTAssertEqual(report.totals.added, 3)
        XCTAssertFalse(report.files.contains { $0.path == "feature.txt" })
        XCTAssertEqual(summary.combined.totals.commits, 2)
        XCTAssertEqual(summary.combined.totals.added, 3)
        XCTAssertEqual(summary.rows.first?.lastCommit, date("2026-02-01T12:00:00Z"))
    }

    func testMissingOriginMainReportsErrorWithoutHeadFallback() async throws {
        try await git(["update-ref", "-d", RepoStatistics.insightsRef])
        do {
            _ = try await manager.stats(for: record, since: nil, ref: RepoStatistics.insightsRef)
            XCTFail("Missing origin/main must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("origin/main"))
        }
        let summary = await manager.statsSummary(for: [record], since: nil, ref: RepoStatistics.insightsRef)
        XCTAssertEqual(summary.combined.totals.commits, 0)
        XCTAssertTrue(summary.rows.first?.error?.contains("origin/main") == true)
        XCTAssertNil(summary.rows.first?.lastCommit)
    }

    func testQuietPeriodDoesNotUseLocalHeadLastCommit() async throws {
        let summary = await manager.statsSummary(
            for: [record], since: date("2026-04-01T00:00:00Z"),
            until: date("2026-05-01T00:00:00Z"), ref: RepoStatistics.insightsRef
        )
        XCTAssertEqual(summary.combined.totals.commits, 0)
        XCTAssertNil(summary.rows.first?.lastCommit)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func git(_ arguments: [String]) async throws {
        let result = await copy.git(arguments)
        guard result.succeeded else { throw RepoError.gitFailed(command: arguments[0], message: result.stderr) }
    }

    private func commit(_ path: String, contents: String, date: String) async throws {
        try copy.writeFile(path, contents: Data(contents.utf8))
        try await git(["add", "--", path])
        let result = await copy.git(["commit", "-q", "-m", "Update example file"], extraEnvironment: [
            "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
        ])
        guard result.succeeded else { throw RepoError.gitFailed(command: "commit", message: result.stderr) }
    }
}
