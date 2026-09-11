import Foundation

public enum CommandRunStatus: Hashable, Sendable {
    case pending
    case running
    case success
    case failed(Int32)
    case offline
    case timeout
    case authFailed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: false
        default: true
        }
    }

    /// Why the row is in this state, for a tooltip. Queued rows are the
    /// ones waiting for one of the concurrent SSH slots to free up.
    public var explanation: String {
        switch self {
        case .pending: "Waiting for a free SSH slot; machines run a few at a time"
        case .running: "SSH session open, output streaming"
        case .success: "Exited 0"
        case .failed(let code): "The command exited \(code)"
        case .offline: "Nothing answered on port 22 when the command was sent"
        case .timeout: "The command was stopped after the per-host time limit"
        case .authFailed: "The host answered but rejected the configured key or user"
        case .cancelled: "Stopped before it finished"
        }
    }

    public var label: String {
        switch self {
        case .pending: "Queued"
        case .running: "Running"
        case .success: "Success"
        case .failed(let code): "Exit \(code)"
        case .offline: "Offline"
        case .timeout: "Timeout"
        case .authFailed: "SSH auth failed"
        case .cancelled: "Cancelled"
        }
    }

    public var icon: String {
        switch self {
        case .pending: "clock"
        case .running: "arrow.clockwise.circle"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .offline: "wifi.slash"
        case .timeout: "clock.badge.xmark"
        case .authFailed: "key.slash"
        case .cancelled: "stop.circle"
        }
    }

    /// Map a classified SSH outcome onto a run status.
    public init(outcome: SecureShellOutcome, exitCode: Int32) {
        switch outcome {
        case .success: self = .success
        case .commandFailed: self = .failed(exitCode)
        case .unreachable: self = .offline
        case .timeout: self = .timeout
        case .authFailed: self = .authFailed
        case .cancelled: self = .cancelled
        case .error: self = .failed(exitCode)
        }
    }
}

/// Per-host result of one fleet command run.
public struct CommandRunResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let computer: RosterComputer
    public let ip: String
    public var status: CommandRunStatus
    public var output: String
    public var errorOutput: String
    public var exitCode: Int32?
    public var startTime: Date
    public var endTime: Date?

    public init(computer: RosterComputer, ip: String, status: CommandRunStatus = .pending,
                startTime: Date = Date()) {
        self.id = UUID()
        self.computer = computer
        self.ip = ip
        self.status = status
        self.output = ""
        self.errorOutput = ""
        self.exitCode = nil
        self.startTime = startTime
        self.endTime = nil
    }

    public var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    /// Plain-text block for copy and hand-off.
    public func formatted() -> String {
        var lines = ["\(computer.displayName) (\(ip)) - \(status.label.lowercased())"]
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { lines.append(out) }
        let err = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty {
            lines.append("stderr:")
            lines.append(err)
        }
        return lines.joined(separator: "\n")
    }
}
