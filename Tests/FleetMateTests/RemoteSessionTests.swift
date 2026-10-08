import XCTest
@testable import FleetMateCore

final class RemoteSessionTests: XCTestCase {
    let launcher = RemoteSessionLauncher(sshKeyPath: "/Users/op/.ssh/id_rsa.fleetadmin", sshUser: "fleetadmin", terminalTheme: "Homebrew")

    func testSshCommandLineQuotesKeyAndTarget() {
        let line = launcher.sshCommandLine(address: "192.168.2.50")
        XCTAssertEqual(line, "ssh -i '/Users/op/.ssh/id_rsa.fleetadmin' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=15 'fleetadmin@192.168.2.50'")

        let odd = RemoteSessionLauncher(sshKeyPath: "/keys/it's mine", sshUser: "ops")
        XCTAssertTrue(odd.sshCommandLine(address: "h").contains("-i '/keys/it'\\''s mine'"))

        let noKey = RemoteSessionLauncher(sshKeyPath: "", sshUser: "ops")
        XCTAssertFalse(noKey.sshCommandLine(address: "h").contains("-i"))
    }

    func testTerminalScriptOpensOneTabPerSessionWithThemeAndTitle() {
        let script = launcher.terminalScript(for: [
            .init(title: "LAB-01", address: "192.168.2.50"),
            .init(title: "LAB-02", address: "192.168.2.51"),
        ])
        XCTAssertTrue(script.hasPrefix("tell application \"Terminal\"\n    activate\n"))
        XCTAssertTrue(script.hasSuffix("end tell"))
        XCTAssertEqual(script.components(separatedBy: "do script").count - 1, 2)
        XCTAssertTrue(script.contains("set current settings of t to settings set \"Homebrew\""))
        XCTAssertTrue(script.contains("set custom title of t to \"SSH - LAB-02\""))
        // Shell single quotes inside the AppleScript string need no escaping; double quotes and backslashes do.
        XCTAssertTrue(script.contains("do script \"ssh -i '/Users/op/.ssh/id_rsa.fleetadmin'"))
    }

    func testTerminalScriptSkipsThemeWhenNoneIsSet() {
        let plain = RemoteSessionLauncher(sshKeyPath: "/k", sshUser: "u")
        let script = plain.terminalScript(for: [.init(title: "x", address: "1.2.3.4")])
        XCTAssertFalse(script.contains("settings set"))
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(RemoteSessionLauncher.appleScriptEscaped("say \"hi\" \\ bye"), "say \\\"hi\\\" \\\\ bye")
        let quoted = RemoteSessionLauncher(sshKeyPath: "/k\"ey", sshUser: "u")
        let script = quoted.terminalScript(for: [.init(title: "a\"b", address: "h")])
        XCTAssertTrue(script.contains("/k\\\"ey"))
        XCTAssertTrue(script.contains("SSH - a\\\"b"))
    }

    func testScreenSharingURLCarriesUserAndEncodedPassword() throws {
        let url = try XCTUnwrap(launcher.screenSharingURL(address: "192.168.2.50", password: "p@ss/word:1"))
        XCTAssertEqual(url.scheme, "vnc")
        XCTAssertEqual(url.host, "192.168.2.50")
        XCTAssertEqual(url.user, "fleetadmin")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.password, "p@ss/word:1")
        XCTAssertEqual(url.password, "p%40ss%2Fword:1", "URL.password keeps the percent-encoding; reserved characters are encoded")
        XCTAssertFalse(url.absoluteString.contains("p@ss/word:1"))

        let noPassword = try XCTUnwrap(launcher.screenSharingURL(address: "192.168.2.50", password: nil))
        XCTAssertEqual(noPassword.absoluteString, "vnc://fleetadmin@192.168.2.50")

        let custom = RemoteSessionLauncher(sshKeyPath: "/k", sshUser: "u", screenSharingUser: "viewer")
        XCTAssertEqual(custom.screenSharingURL(address: "h", password: "")?.absoluteString, "vnc://viewer@h")
    }

    func testLauncherFromConfigUsesResolvedValues() {
        var config = ManageConfig()
        config.sshUser = " lab "
        config.terminalTheme = " Ocean "
        let l = RemoteSessionLauncher(config: config)
        XCTAssertEqual(l.sshUser, "lab")
        XCTAssertEqual(l.screenSharingUser, "lab")
        XCTAssertEqual(l.terminalTheme, "Ocean")
        XCTAssertTrue(l.sshKeyPath.hasSuffix("/.ssh/id_rsa.fleetadmin"))
    }

    func testKeychainKeyIsPinned() {
        XCTAssertEqual(KeychainService.Key.manageScreenSharingPassword.rawValue, "ManageScreenSharingPassword")
    }
}
