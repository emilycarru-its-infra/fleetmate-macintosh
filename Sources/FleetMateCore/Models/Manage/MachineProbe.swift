import Foundation

/// What one SSH probe learned about a machine: who is at the console, what
/// it is running, and whether remote access is ready.
public struct MachineInfo: Hashable, Sendable {
    public var hostname: String
    public var ip: String

    // Console session
    public var consoleUser: String
    public var email: String

    // OS
    public var osVersion: String
    public var uptime: String

    // Security and remote access
    public var xcredsRunning: Bool
    public var sshRemoteLogin: String
    public var sshPortListening: Bool
    public var screenSharingState: String
    public var screenSharingPortListening: Bool

    /// Remote Desktop Info fields from /Library/Preferences/com.apple.RemoteDesktop.plist.
    public var ardText: [String]

    /// Running applications (user-visible, top names).
    public var topApps: [String]

    /// Munki client identifier, when set.
    public var clientIdentifier: String

    public var fetchedAt: Date

    public var screenSharingReady: Bool { screenSharingState == "running" && screenSharingPortListening }
    public var sshReady: Bool { sshPortListening }
    public var hasConsoleUser: Bool { !consoleUser.isEmpty && consoleUser != "loginwindow" }

    public init(hostname: String, ip: String, consoleUser: String = "", email: String = "",
                osVersion: String = "", uptime: String = "", xcredsRunning: Bool = false,
                sshRemoteLogin: String = "", sshPortListening: Bool = false,
                screenSharingState: String = "", screenSharingPortListening: Bool = false,
                ardText: [String] = [], topApps: [String] = [], clientIdentifier: String = "",
                fetchedAt: Date = Date()) {
        self.hostname = hostname
        self.ip = ip
        self.consoleUser = consoleUser
        self.email = email
        self.osVersion = osVersion
        self.uptime = uptime
        self.xcredsRunning = xcredsRunning
        self.sshRemoteLogin = sshRemoteLogin
        self.sshPortListening = sshPortListening
        self.screenSharingState = screenSharingState
        self.screenSharingPortListening = screenSharingPortListening
        self.ardText = ardText
        self.topApps = topApps
        self.clientIdentifier = clientIdentifier
        self.fetchedAt = fetchedAt
    }
}

/// The probe script that produces `MachineInfo`, and the parser for its
/// key=value output.
public enum MachineProbe {
    /// Sent over stdin to the remote zsh. Every line it prints is `key=value`.
    public static let script = """
        CU=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/{print $3}')
        echo "user=$CU"
        echo "os=$(sw_vers -productVersion 2>/dev/null || echo '')"
        echo "uptime=$(uptime | sed 's/.*up //' | sed 's/, [0-9]* user.*//' | xargs)"
        if pgrep -if "xcreds" >/dev/null 2>&1; then echo "xcreds=yes"; else echo "xcreds=no"; fi
        echo "ssh_remote_login=$(sudo systemsetup -getremotelogin 2>/dev/null | awk -F': ' '{print $2}')"
        if sudo lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1; then echo "ssh_port=listening"; else echo "ssh_port=not-listening"; fi
        if sudo launchctl print system/com.apple.screensharing 2>/dev/null | grep -q 'state = running'; then echo "screen_sharing=running"; else echo "screen_sharing=not-running"; fi
        if sudo lsof -nP -iTCP:5900 -sTCP:LISTEN >/dev/null 2>&1; then echo "screen_sharing_port=listening"; else echo "screen_sharing_port=not-listening"; fi
        echo "email=$(dscl . -read /Users/$CU EMailAddress 2>/dev/null | awk '/EMailAddress:/{getline; print $1}')"
        echo "client_identifier=$(defaults read /Library/Preferences/ManagedInstalls ClientIdentifier 2>/dev/null || echo '')"
        P=/Library/Preferences/com.apple.RemoteDesktop.plist
        for i in 1 2 3 4 5 6 7 8; do
            echo "text${i}=$(sudo defaults read $P Text${i} 2>/dev/null || echo '')"
        done
        echo "apps=$(ps -axo args | grep -o '/Applications/[^/]*.app' | sed 's|/Applications/||;s|.app$||' | sort -u | head -10 | tr '\\n' ',')"
        """

    /// Parse the probe's key=value lines. Unknown keys are ignored; missing
    /// keys read as empty, so a partial probe still yields usable info.
    public static func parse(hostname: String, ip: String, raw: String, fetchedAt: Date = Date()) -> MachineInfo {
        var d: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            d[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let apps = (d["apps"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let ard = (1...8).map { d["text\($0)"] ?? "" }

        return MachineInfo(
            hostname: hostname,
            ip: ip,
            consoleUser: d["user"] ?? "",
            email: d["email"] ?? "",
            osVersion: d["os"] ?? "",
            uptime: d["uptime"] ?? "",
            xcredsRunning: d["xcreds"] == "yes",
            sshRemoteLogin: d["ssh_remote_login"] ?? "",
            sshPortListening: d["ssh_port"] == "listening",
            screenSharingState: d["screen_sharing"] ?? "",
            screenSharingPortListening: d["screen_sharing_port"] == "listening",
            ardText: ard,
            topApps: apps,
            clientIdentifier: d["client_identifier"] ?? "",
            fetchedAt: fetchedAt
        )
    }

    /// True when the probe produced at least one recognised key.
    public static func looksLikeProbeOutput(_ raw: String) -> Bool {
        raw.contains("user=") || raw.contains("os=") || raw.contains("ssh_port=")
    }
}
