import Foundation

/// A terminal title (OSC 0 or OSC 2) read as the name of the task in the
/// session. Claude Code and Codex title the terminal with their session's
/// name behind a status glyph: a Braille spinner frame while working, a
/// star or dot while idle. A shell's own title (`user@host: ~/src`, a path,
/// the program's bare name) names no task and is ignored, so the row keeps
/// its label instead.
public struct TerminalTitle: Equatable, Sendable {
    /// The task, without the status glyph; nil when the title names none.
    public var task: String?
    /// True for a spinner frame, false for an idle mark, nil when there is no glyph.
    public var working: Bool?

    public init(task: String?, working: Bool?) {
        self.task = task
        self.working = working
    }

    public static let maxLength = 120

    /// Titles that are only the program's or the shell's own name.
    static let programNames: Set<String> = [
        "claude", "claude code", "codex", "openai codex", "zsh", "-zsh", "bash", "-bash",
        "fish", "sh", "login", "terminal", "shell",
    ]

    /// Marks agents draw ahead of the title when idle.
    static let idleMarks: Set<Character> = ["✳", "✻", "✽", "✶", "✢", "✦", "✧", "·", "•", "●", "○", "*"]

    public static func parse(_ raw: String) -> TerminalTitle {
        var text = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var working: Bool?
        while let first = text.first {
            if first.unicodeScalars.allSatisfy({ (0x2800...0x28FF).contains($0.value) }) {
                working = true
            } else if idleMarks.contains(first) {
                if working == nil { working = false }
            } else {
                break
            }
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return TerminalTitle(task: namesTask(text) ? text : nil, working: working)
    }

    static func namesTask(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if programNames.contains(text.lowercased()) { return false }
        if text.hasPrefix("/") || text.hasPrefix("~") { return false }
        // user@host: path, user@host path — what a shell's prompt sets.
        if text.range(of: #"^[^\s@]+@[^\s:]+(:|\s|$)"#, options: .regularExpression) != nil { return false }
        return true
    }
}

/// The automatic and manual names of a session, and which one shows.
public enum TerminalSessionName {
    /// A name the person typed wins; then what the agent wrote to its session
    /// file, the task in the terminal title, the row's label (the
    /// repository's name), and last what it runs.
    public static func resolve(custom: String?, agent: String?, task: String?, label: String?, fallback: String) -> String {
        for candidate in [custom, agent, task, label] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return fallback
    }
}

/// A folder as a short path for a session row: its components below the
/// nearest repository root (Settings › Repositories), joined with " · ", so
/// `~/src/Cloud/Vantage` under the root `~/src` reads "Cloud · Vantage".
/// Hidden components such as `.worktrees` are left out.
public enum TerminalBreadcrumb {
    public static let separator = " · "

    public static func make(_ path: String, roots: [String], home: String = NSHomeDirectory()) -> String {
        let full = trimmed(TerminalWorkspaceStore.expand(path, home: home))
        let expandedRoots = roots.map { trimmed(TerminalWorkspaceStore.expand($0, home: home)) }
            .filter { !$0.isEmpty && $0 != "/" }
            .sorted { $0.count > $1.count }
        var components: [String]
        if let root = expandedRoots.first(where: { full == $0 || full.hasPrefix($0 + "/") }) {
            components = full == root ? [(root as NSString).lastPathComponent]
                : full.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        } else if !home.isEmpty, full == trimmed(home) {
            return "~"
        } else if !home.isEmpty, full.hasPrefix(trimmed(home) + "/") {
            components = ["~"] + full.dropFirst(trimmed(home).count + 1).split(separator: "/").map(String.init)
        } else {
            components = full.split(separator: "/").map(String.init)
        }
        let shown = components.filter { !$0.hasPrefix(".") }
        return shown.isEmpty ? full : shown.joined(separator: separator)
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// How an agent session picks its last conversation back up after a relaunch.
public enum AgentResume {
    /// `command` changed to resume the latest conversation in the folder it
    /// starts in, or nil when it does not start Claude Code or Codex (a
    /// shell, a remote wrapper that keeps its own session, a subcommand).
    public static func command(_ command: String) -> String? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first else { return nil }
        let rest = Set(words.dropFirst())
        switch (program as NSString).lastPathComponent {
        case "claude":
            if let next = words.dropFirst().first, AgentBrief.claudeNonSessionSubcommands.contains(next) { return nil }
            if !rest.isDisjoint(with: ["--continue", "-c", "--resume", "-r", "-p", "--print"]) { return nil }
            return command + " --continue"
        case "codex":
            if let next = words.dropFirst().first, !next.hasPrefix("-") { return nil }
            return command + " resume --last"
        default:
            return nil
        }
    }
}
