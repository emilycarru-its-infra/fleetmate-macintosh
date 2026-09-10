import Foundation

/// Opens interactive sessions to a machine: SSH in Terminal.app, Screen
/// Sharing through its URL scheme. The command lines and scripts are built
/// as values so they can be tested; launching is the last step.
public struct RemoteSessionLauncher: Sendable {
    public struct Session: Sendable {
        public var title: String
        public var address: String

        public init(title: String, address: String) {
            self.title = title
            self.address = address
        }
    }

    public var sshKeyPath: String
    public var sshUser: String
    /// Terminal.app settings set to apply; empty keeps Terminal's default profile.
    public var terminalTheme: String
    public var screenSharingUser: String

    public init(config: ManageConfig) {
        self.sshKeyPath = config.resolvedSshKeyPath
        self.sshUser = config.resolvedSshUser
        self.terminalTheme = config.terminalTheme.trimmingCharacters(in: .whitespaces)
        self.screenSharingUser = config.resolvedScreenSharingUser
    }

    public init(sshKeyPath: String, sshUser: String, terminalTheme: String = "", screenSharingUser: String? = nil) {
        self.sshKeyPath = sshKeyPath
        self.sshUser = sshUser
        self.terminalTheme = terminalTheme
        self.screenSharingUser = screenSharingUser ?? sshUser
    }

    // MARK: - Command lines

    /// The interactive ssh command a Terminal tab runs.
    public func sshCommandLine(address: String) -> String {
        var parts = ["ssh"]
        if !sshKeyPath.isEmpty {
            parts.append("-i \(Self.shellSingleQuoted(sshKeyPath))")
        }
        parts.append("-o StrictHostKeyChecking=no")
        parts.append("-o UserKnownHostsFile=/dev/null")
        parts.append("-o ServerAliveInterval=15")
        parts.append(Self.shellSingleQuoted("\(sshUser)@\(address)"))
        return parts.joined(separator: " ")
    }

    /// AppleScript that opens one Terminal tab per session, titled, sized,
    /// and themed when a theme is set.
    public func terminalScript(for sessions: [Session]) -> String {
        var lines = ["tell application \"Terminal\"", "    activate"]
        for session in sessions {
            let command = Self.appleScriptEscaped(sshCommandLine(address: session.address))
            let title = Self.appleScriptEscaped("SSH - \(session.title)")
            lines.append("    set t to do script \"\(command)\"")
            if !terminalTheme.isEmpty {
                lines.append("    try")
                lines.append("        set current settings of t to settings set \"\(Self.appleScriptEscaped(terminalTheme))\"")
                lines.append("    end try")
            }
            lines.append("    set custom title of t to \"\(title)\"")
            lines.append("    set number of columns of t to 120")
            lines.append("    set number of rows of t to 35")
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// `vnc://user:password@address` when a password is given, else
    /// `vnc://user@address`, so Screen Sharing pre-fills what it can.
    public func screenSharingURL(address: String, password: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = address
        components.user = screenSharingUser.isEmpty ? nil : screenSharingUser
        if let password, !password.isEmpty {
            components.password = password
        }
        return components.url
    }

    // MARK: - Launching

    /// Open SSH sessions in Terminal, one tab each.
    public func openTerminal(sessions: [Session]) {
        guard !sessions.isEmpty else { return }
        let script = terminalScript(for: sessions)
        Task.detached(priority: .userInitiated) {
            let result = await ProcessRunner.run("/usr/bin/osascript", ["-e", script])
            if !result.succeeded {
                dbg.warn("Terminal launch failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))", category: "manage")
            }
        }
    }

    /// Open Screen Sharing to an address. The password never touches the
    /// command line: `open` receives the URL as an argument, and the app
    /// takes it from there.
    public func openScreenSharing(address: String, password: String?) {
        guard let url = screenSharingURL(address: address, password: password) else { return }
        Task.detached(priority: .userInitiated) {
            let result = await ProcessRunner.run("/usr/bin/open", [url.absoluteString])
            if !result.succeeded {
                dbg.warn("Screen Sharing launch failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))", category: "manage")
            }
        }
    }

    // MARK: - Quoting

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// The Screen Sharing password, kept in the login Keychain under FleetMate's
/// service name. Never written to disk or logs.
public enum ScreenSharingCredentialStore {
    public static func load() -> String? {
        KeychainService.shared.get(.manageScreenSharingPassword)
    }

    public static func save(_ password: String) throws {
        try KeychainService.shared.save(password, for: .manageScreenSharingPassword)
    }

    public static func clear() throws {
        try KeychainService.shared.delete(.manageScreenSharingPassword)
    }

    public static var isSet: Bool { load() != nil }
}
