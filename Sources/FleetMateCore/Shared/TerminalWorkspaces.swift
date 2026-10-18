import Foundation

/// Saved terminal workspaces: named sets of sessions in sections, kept in
/// `~/.fleetmate/terminal-workspaces.json` (the same file and shape on
/// Windows, under `%USERPROFILE%\.fleetmate`), so they can be edited by hand.
/// One may be named to open when FleetMate starts.
///
///     {
///       "openAtLaunch": "Daily",
///       "workspaces": [{
///         "name": "Daily",
///         "show": true,
///         "fullWindow": false,
///         "sections": [{
///           "name": "Repos",
///           "collapsed": false,
///           "sessions": [{ "name": "fleetmate", "command": "codex", "directory": "~/src/fleetmate" }]
///         }]
///       }]
///     }
public struct TerminalWorkspaceFile: Codable, Equatable, Sendable {
    /// The workspace opened at launch, by name (case-insensitive); nil opens none.
    public var openAtLaunch: String?
    public var workspaces: [TerminalWorkspace]

    public init(openAtLaunch: String? = nil, workspaces: [TerminalWorkspace] = []) {
        self.openAtLaunch = openAtLaunch
        self.workspaces = workspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openAtLaunch = try container.decodeIfPresent(String.self, forKey: .openAtLaunch)
        workspaces = try container.decodeIfPresent([TerminalWorkspace].self, forKey: .workspaces) ?? []
    }

    public func workspace(named name: String) -> TerminalWorkspace? {
        workspaces.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The workspace to open at launch, when it names one that exists.
    public var launchWorkspace: TerminalWorkspace? { openAtLaunch.flatMap(workspace(named:)) }

    /// Add `workspace`, or replace the one with its name in place.
    public mutating func upsert(_ workspace: TerminalWorkspace) {
        if let index = workspaces.firstIndex(where: { $0.name.caseInsensitiveCompare(workspace.name) == .orderedSame }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    /// The workspace generated from Repos, by its mark or else its name.
    public var baselineIndex: Int? {
        workspaces.firstIndex { $0.source == TerminalWorkspaceBaseline.source }
            ?? workspaces.firstIndex { $0.name.caseInsensitiveCompare(TerminalWorkspaceBaseline.name) == .orderedSame }
    }

    public mutating func remove(named name: String) {
        workspaces.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let launch = openAtLaunch, launch.caseInsensitiveCompare(name) == .orderedSame { openAtLaunch = nil }
    }
}

public struct TerminalWorkspace: Codable, Equatable, Sendable {
    public var name: String
    /// "repos" for the workspace FleetMate generated from the Repos tab, so
    /// Add Missing Repos finds it after a rename; nil for the person's own.
    public var source: String?
    /// Show the terminal when the workspace opens. Default true.
    public var show: Bool?
    /// Open the terminal filling the window rather than split.
    public var fullWindow: Bool?
    public var sections: [Section]

    public init(name: String, show: Bool? = nil, fullWindow: Bool? = nil, sections: [Section]) {
        self.name = name
        self.show = show
        self.fullWindow = fullWindow
        self.sections = sections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        show = try container.decodeIfPresent(Bool.self, forKey: .show)
        fullWindow = try container.decodeIfPresent(Bool.self, forKey: .fullWindow)
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
    }

    public var sessionCount: Int { sections.reduce(0) { $0 + $1.sessions.count } }

    public struct Section: Codable, Equatable, Sendable {
        public var name: String
        public var collapsed: Bool?
        public var sessions: [Session]

        public init(name: String, collapsed: Bool? = nil, sessions: [Session]) {
            self.name = name
            self.collapsed = collapsed
            self.sessions = sessions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed)
            sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        /// The session's name in the list; nil takes the program's own title.
        public var name: String?
        /// What it runs: "codex", "claude", any command; nil or "" is the login shell.
        public var command: String?
        /// Where it starts; "~" is the home folder. Nil is the default start folder.
        public var directory: String?

        public init(name: String? = nil, command: String? = nil, directory: String? = nil) {
            self.name = name
            self.command = command
            self.directory = directory
        }
    }
}

public enum TerminalWorkspaceStore {
    public static var defaultPath: String { AppEdition.current.supportPath("terminal-workspaces.json") }

    /// The file's workspaces; an empty file when it does not exist yet.
    public static func load(from path: String = defaultPath) throws -> TerminalWorkspaceFile {
        guard FileManager.default.fileExists(atPath: path) else { return TerminalWorkspaceFile() }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return TerminalWorkspaceFile() }
        return try JSONDecoder().decode(TerminalWorkspaceFile.self, from: data)
    }

    public static func save(_ file: TerminalWorkspaceFile, to path: String = defaultPath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    /// `path` with the home folder written as `~`, so a saved workspace reads
    /// the same on another account.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}
