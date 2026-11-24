import XCTest
@testable import FleetMateCore

final class PipelineStageReportTests: XCTestCase {
    private let run = PipelineRun(source: .azureDevOps, container: "Proj", repository: "Repo", pipelineName: "CI",
                                  pipelineId: 1, runId: 7, runNumber: "2026.1", status: .failed, branch: "main",
                                  commitSha: "abc123", triggeredBy: nil, startedAt: nil, finishedAt: nil,
                                  webUrl: "https://example.invalid/run/7")

    func testHeaderNamesRunStageAndResult() {
        let stage = PipelineRunLog.Section(id: "s", name: "Build", status: .failed, text: "token ***\\nboom")
        let text = PipelineStageReport.copy(run, stage: stage)
        XCTAssertTrue(text.hasPrefix("Pipeline: CI | Run: 2026.1 | Repository: Proj/Repo | Branch: main | Commit: abc123 | Stage: Build | Result: Failed"))
        XCTAssertTrue(text.contains("token ***"), "masking is kept as the log shows it")
    }

    func testExcerptKeepsTheLinesAroundTheLastError() {
        let lines = (0..<1000).map { $0 == 600 ? "##[error]it broke" : "line \\($0)" }
        let cut = PipelineStageReport.excerpt(lines.joined(separator: "\\n"), limit: 200)
        XCTAssertTrue(cut.trimmed)
        let kept = cut.text.components(separatedBy: "\\n")
        XCTAssertEqual(kept.count, 200)
        XCTAssertTrue(kept.contains("##[error]it broke"))
        XCTAssertEqual(kept.last, "line 620")
    }

    func testPromptCarriesLinkAndFullLogNote() {
        let stage = PipelineRunLog.Section(id: "s", name: "Deploy", status: .failed, text: "x")
        let prompt = PipelineStageReport.prompt(run, stages: [stage], fullLog: "/tmp/full.log")
        XCTAssertTrue(prompt.contains("https://example.invalid/run/7"))
        XCTAssertTrue(prompt.contains("“Deploy” failed."))
        XCTAssertTrue(prompt.hasSuffix("The full log is in /tmp/full.log."))
    }
}
