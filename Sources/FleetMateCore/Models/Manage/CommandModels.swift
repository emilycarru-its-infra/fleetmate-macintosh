import Foundation

/// How much damage a library command can do. Drives the confirmation shown
/// before a fleet run and the badge next to the command.
public enum CommandTrustLevel: String, CaseIterable, Hashable, Sendable, Codable {
    case safe
    case caution
    case destructive

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .caution: "Caution"
        case .destructive: "Destructive"
        }
    }

    public var warningTitle: String {
        switch self {
        case .safe: "Run command?"
        case .caution: "Run caution command?"
        case .destructive: "Run destructive command?"
        }
    }

    public var warningMessage: String {
        switch self {
        case .safe:
            "This command is marked safe."
        case .caution:
            "This command may change machine state or affect logged-in users. Test on a small target set first."
        case .destructive:
            "This command can delete data, restart machines, reset services, or make fleet-wide changes. Confirm your target set before running it."
        }
    }

    /// Ordering for "understated trust" checks: safe < caution < destructive.
    public var rank: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .destructive: 2
        }
    }

    /// Classify a macOS shell command by pattern. Used when a library entry
    /// states no trust level, and by the audit to catch entries that state a
    /// weaker level than the command warrants.
    public static func inferred(from command: String) -> CommandTrustLevel {
        let lower = command.lowercased()
        if destructivePatterns.contains(where: { lower.contains($0) }) { return .destructive }
        if cautionPatterns.contains(where: { lower.contains($0) }) { return .caution }
        return .safe
    }

    static let destructivePatterns = [
        "rm -rf",
        "rm -r ",
        "shutdown -r",
        "shutdown -h",
        "reboot",
        "pmset sleepnow",
        "lpadmin -x",
        "profiles -n",
        "profiles remove",
        "sysadminctl -adduser",
        "sysadminctl -deleteuser",
        "pkgutil --forget",
        "killall -9",
        "diskutil erase",
        "launchctl bootout system",
        "tccutil reset all",
    ]

    static let cautionPatterns = [
        "softwareupdate --install",
        "softwareupdate -i",
        "managedsoftwareupdate --installonly",
        "managedsoftwareupdate --auto",
        "launchctl bootout",
        "launchctl kickstart",
        "keystroke \"q\" using {control down, command down}",
        "pmset schedule cancelall",
        "pmset restoredefaults",
        "profiles renew",
        "systemsetup -setremotelogin",
        "tccutil reset",
        "networksetup -removeallpreferredwirelessnetworks",
        "networksetup -setdnsservers",
        "sudo \"$rum\"",
        "outset --login",
        "outset --login-once",
        "outset --on-demand",
        "outset --boot",
        "touch /private/tmp/.io.macadmins.outset.ondemand.launchd",
        "chown -r root:wheel /usr/local/outset",
        "chmod -r 755 /usr/local/outset",
        "defaults write",
        "defaults delete",
        "installer -pkg",
        "cupsenable",
        "cupsdisable",
        "cancel -a",
        "killall",
        "pkill",
        "kill ",
    ]
}

/// One entry of the command library.
public struct ManageCommand: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var label: String
    public var command: String
    public var trustLevel: CommandTrustLevel
    /// False when the YAML stated no trust and the level was inferred.
    public var trustWasStated: Bool

    public init(id: UUID = UUID(), label: String, command: String,
                trustLevel: CommandTrustLevel? = nil) {
        self.id = id
        self.label = label
        self.command = command
        if let trustLevel {
            self.trustLevel = trustLevel
            self.trustWasStated = true
        } else {
            self.trustLevel = CommandTrustLevel.inferred(from: command)
            self.trustWasStated = false
        }
    }

    /// The trust the command's text warrants, regardless of what the library says.
    public var inferredTrust: CommandTrustLevel { CommandTrustLevel.inferred(from: command) }

    /// True when the stated level is weaker than the pattern inference.
    public var trustIsUnderstated: Bool { trustLevel.rank < inferredTrust.rank }
}

/// A named group of library commands.
public struct CommandCategory: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var commands: [ManageCommand]

    public init(id: UUID = UUID(), name: String, commands: [ManageCommand]) {
        self.id = id
        self.name = name
        self.commands = commands
    }
}

/// One line of the run history.
public struct CommandHistoryEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var label: String
    public var command: String
    public var date: Date

    public init(id: UUID = UUID(), label: String, command: String, date: Date = Date()) {
        self.id = id
        self.label = label
        self.command = command
        self.date = date
    }
}

public enum CommandAuditSeverity: String, Sendable, Comparable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: CommandAuditSeverity, rhs: CommandAuditSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Something the library audit found.
public struct CommandAuditIssue: Hashable, Sendable {
    public var severity: CommandAuditSeverity
    public var category: String
    public var label: String
    public var message: String

    public init(severity: CommandAuditSeverity, category: String, label: String = "", message: String) {
        self.severity = severity
        self.category = category
        self.label = label
        self.message = message
    }

    public var description: String {
        let where_ = label.isEmpty ? category : "\(category) / \(label)"
        return "[\(severity.rawValue)] \(where_): \(message)"
    }
}
