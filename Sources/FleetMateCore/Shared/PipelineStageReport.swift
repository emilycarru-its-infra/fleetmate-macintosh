import Foundation

/// The text a pipeline stage is copied or sent to an agent as. It carries
/// only what the run and its log already show: the provider's masking
/// (`***`) is kept, and nothing is looked up or added.
public enum PipelineStageReport {
    /// How many lines of a stage an agent prompt carries.
    public static let excerptLines = 200

    /// A line naming the run and, when given, the stage and its result.
    public static func header(_ run: PipelineRun, stage: PipelineRunLog.Section? = nil) -> String {
        var parts = ["Pipeline: \(run.pipelineName)", "Run: \(run.runNumber)"]
        parts.append("Repository: " + (run.repository.map { "\(run.container)/\($0)" } ?? run.container))
        if let branch = run.branch { parts.append("Branch: \(branch)") }
        if let sha = run.commitSha { parts.append("Commit: \(sha)") }
        if let stage {
            parts.append("Stage: \(stage.name)")
            parts.append("Result: \(stage.status.displayName)")
        } else {
            parts.append("Result: \(run.status.displayName)")
        }
        return parts.joined(separator: " | ")
    }

    /// One stage: its header line, then its whole log.
    public static func copy(_ run: PipelineRun, stage: PipelineRunLog.Section) -> String {
        header(run, stage: stage) + "\n\n" + stage.text
    }

    /// Several stages, one after another.
    public static func copy(_ run: PipelineRun, stages: [PipelineRunLog.Section]) -> String {
        stages.map { copy(run, stage: $0) }.joined(separator: "\n\n")
    }

    /// The stages that failed.
    public static func failed(_ sections: [PipelineRunLog.Section]) -> [PipelineRunLog.Section] {
        sections.filter { $0.status == .failed }
    }

    /// At most `limit` lines of a log, around its last error: the lines
    /// leading up to it and a few after. With no error line, its tail.
    public static func excerpt(_ text: String, limit: Int = excerptLines) -> (text: String, trimmed: Bool) {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > limit else { return (text, false) }
        let error = lines.lastIndex { line in
            line.contains("##[error]") || line.range(of: "error", options: .caseInsensitive) != nil
        }
        let end = min(lines.count, (error ?? lines.count - 1) + 1 + 20)
        let start = max(0, end - limit)
        return (lines[start..<end].joined(separator: "\n"), true)
    }

    /// A short prompt for an agent: what failed, the run's link, and each
    /// stage's log cut down by ``excerpt(_:limit:)``. `fullLog` says where
    /// the whole text is.
    public static func prompt(_ run: PipelineRun, stages: [PipelineRunLog.Section], fullLog: String?) -> String {
        let names = stages.map(\.name)
        var out = names.isEmpty
            ? "Pipeline run \(run.pipelineName) \(run.runNumber) ended \(run.status.displayName.lowercased())."
            : "Pipeline run \(run.pipelineName) \(run.runNumber): " + names.map { "“\($0)”" }.joined(separator: ", ")
                + (stages.allSatisfy { $0.status == .failed } ? " failed." : ".")
        out += " Find the cause and propose a fix.\n\n" + header(run) + "\nRun: \(run.webUrl)\n"
        for stage in stages {
            let cut = excerpt(stage.text)
            out += "\n" + header(run, stage: stage) + "\n"
            if cut.trimmed { out += "(last \(excerptLines) lines around the error)\n" }
            out += "```\n" + cut.text + "\n```\n"
        }
        if let fullLog { out += "\nThe full log is in \(fullLog)." }
        return out
    }
}
