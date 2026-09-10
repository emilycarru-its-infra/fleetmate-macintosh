import XCTest
@testable import FleetMateCore

final class TrustInferenceTests: XCTestCase {

    func testReadOnlyCommandsAreSafe() {
        for cmd in [
            "hostname", "sw_vers", "uptime", "df -h / | tail -1",
            "sudo /usr/local/munki/managedsoftwareupdate --checkonly",
            "defaults read /Library/Preferences/ManagedInstalls ClientIdentifier",
            "lpstat -p", "system_profiler SPHardwareDataType", "log show --last 1h",
            "ls -la /Applications", "pgrep -x xcreds",
        ] {
            XCTAssertEqual(CommandTrustLevel.inferred(from: cmd), .safe, cmd)
        }
    }

    func testStateChangingCommandsAreCaution() {
        for cmd in [
            "sudo /usr/local/munki/managedsoftwareupdate --auto",
            "sudo softwareupdate --install --all",
            "sudo launchctl bootout gui/501/com.example",
            "sudo profiles renew -type enrollment",
            "sudo defaults write /Library/Preferences/ManagedInstalls ClientIdentifier -string x",
            "sudo tccutil reset Camera",
            "sudo outset --login-once",
        ] {
            XCTAssertEqual(CommandTrustLevel.inferred(from: cmd), .caution, cmd)
        }
    }

    func testDestructiveCommandsAreDestructive() {
        for cmd in [
            "sudo shutdown -r now", "sudo rm -rf /Library/Managed\\ Installs/Cache/*",
            "sudo pmset sleepnow", "sudo lpadmin -x Printer", "sudo pkgutil --forget com.foo",
            "sudo profiles -N", "sudo killall -9 Finder", "sudo sysadminctl -deleteUser bob",
        ] {
            XCTAssertEqual(CommandTrustLevel.inferred(from: cmd), .destructive, cmd)
        }
    }

    func testRankOrdersLevels() {
        XCTAssertLessThan(CommandTrustLevel.safe.rank, CommandTrustLevel.caution.rank)
        XCTAssertLessThan(CommandTrustLevel.caution.rank, CommandTrustLevel.destructive.rank)
        let understated = ManageCommand(label: "x", command: "sudo shutdown -r now", trustLevel: .safe)
        XCTAssertTrue(understated.trustIsUnderstated)
        let overstated = ManageCommand(label: "x", command: "hostname", trustLevel: .destructive)
        XCTAssertFalse(overstated.trustIsUnderstated, "stating more caution than needed is fine")
    }
}

final class PlaceholderTemplateTests: XCTestCase {

    func testDetectFindsUniqueTokensInOrder() throws {
        XCTAssertNil(PlaceholderTemplate.detect(label: "x", command: "echo <not a token> <lower>"))
        let t = try XCTUnwrap(PlaceholderTemplate.detect(
            label: "Reset", command: "sysadminctl -resetPasswordFor <USERNAME> -newPassword <PASSWORD> && echo <USERNAME>"))
        XCTAssertEqual(t.placeholders, ["<USERNAME>", "<PASSWORD>"])
        XCTAssertTrue(t.hasSensitive)
        XCTAssertFalse(t.isComplete(["<USERNAME>": "bob"]))
        XCTAssertTrue(t.isComplete(["<USERNAME>": "bob", "<PASSWORD>": "x"]))
    }

    func testFieldLabels() {
        XCTAssertEqual(PlaceholderTemplate.fieldLabel("<USERNAME>"), "Username")
        XCTAssertEqual(PlaceholderTemplate.fieldLabel("<PACKAGE_IDENTIFIER>"), "Package identifier")
        XCTAssertTrue(PlaceholderTemplate.isSensitive("<API_TOKEN>"))
        XCTAssertTrue(PlaceholderTemplate.isSensitive("<CLIENT_SECRET>"))
        XCTAssertFalse(PlaceholderTemplate.isSensitive("<USERNAME>"))
    }

    func testBareTokensAreSingleQuotedAndEscaped() throws {
        let t = try XCTUnwrap(PlaceholderTemplate.detect(label: "x", command: "id <USERNAME>"))
        XCTAssertEqual(t.resolve(["<USERNAME>": "o'brien"]), "id 'o'\\''brien'")
    }

    func testAuthorQuotesAreKept() throws {
        let single = try XCTUnwrap(PlaceholderTemplate.detect(label: "x", command: "echo '<NAME>'"))
        XCTAssertEqual(single.resolve(["<NAME>": "it's"]), "echo 'it'\\''s'")
        let double = try XCTUnwrap(PlaceholderTemplate.detect(label: "x", command: "echo \"<NAME>\""))
        XCTAssertEqual(double.resolve(["<NAME>": "a\"b$c`d\\e"]), "echo \"a\\\"b\\$c\\`d\\\\e\"")
    }

    func testRedactionHidesOnlySensitiveValues() throws {
        let t = try XCTUnwrap(PlaceholderTemplate.detect(label: "x", command: "login <USERNAME> <PASSWORD>"))
        let preview = t.resolve(["<USERNAME>": "bob", "<PASSWORD>": "hunter2"], redactSensitive: true)
        XCTAssertEqual(preview, "login 'bob' '••••••••'")
        XCTAssertFalse(preview.contains("hunter2"))
    }
}

final class MachineProbeTests: XCTestCase {

    static let raw = """
    user=alice
    os=15.6.1
    uptime=3 days, 4:12
    xcreds=yes
    ssh_remote_login=On
    ssh_port=listening
    screen_sharing=running
    screen_sharing_port=listening
    email=alice@example.edu
    client_identifier=Shared/Curriculum/Foundation
    text1=B1122
    text2=
    text3=Foundation
    text4=
    text5=
    text6=
    text7=
    text8=
    apps=Safari,Terminal,Adobe Photoshop 2025,
    """

    func testParseFillsEveryField() {
        let info = MachineProbe.parse(hostname: "B1122-01", ip: "10.15.2.50", raw: Self.raw)
        XCTAssertEqual(info.consoleUser, "alice")
        XCTAssertEqual(info.osVersion, "15.6.1")
        XCTAssertEqual(info.uptime, "3 days, 4:12")
        XCTAssertTrue(info.xcredsRunning)
        XCTAssertTrue(info.sshReady)
        XCTAssertTrue(info.screenSharingReady)
        XCTAssertEqual(info.email, "alice@example.edu")
        XCTAssertEqual(info.clientIdentifier, "Shared/Curriculum/Foundation")
        XCTAssertEqual(info.ardText, ["B1122", "", "Foundation", "", "", "", "", ""])
        XCTAssertEqual(info.topApps, ["Safari", "Terminal", "Adobe Photoshop 2025"])
        XCTAssertTrue(info.hasConsoleUser)
    }

    func testPartialOutputStillParses() {
        let info = MachineProbe.parse(hostname: "h", ip: "1.2.3.4", raw: "os=14.7\nsudo: a password is required\nuser=loginwindow")
        XCTAssertEqual(info.osVersion, "14.7")
        XCTAssertFalse(info.hasConsoleUser)
        XCTAssertFalse(info.screenSharingReady)
        XCTAssertTrue(MachineProbe.looksLikeProbeOutput("os=14.7"))
        XCTAssertFalse(MachineProbe.looksLikeProbeOutput("Permission denied (publickey)."))
    }

    func testValuesContainingEqualsSurvive() {
        let info = MachineProbe.parse(hostname: "h", ip: "1.2.3.4", raw: "text1=key=value")
        XCTAssertEqual(info.ardText[0], "key=value")
    }

    func testProbeScriptIsWellFormedZsh() {
        XCTAssertTrue(MachineProbe.script.contains("echo \"user=$CU\""))
        XCTAssertTrue(MachineProbe.script.contains("client_identifier="))
        XCTAssertFalse(MachineProbe.script.contains("\t"), "tabs would be mangled by some remote shells")
    }
}

final class SecureShellClassificationTests: XCTestCase {

    func testExitCodesAndStderrClassify() {
        XCTAssertEqual(SecureShellService.classify(exitCode: 0, stderr: ""), .success)
        XCTAssertEqual(SecureShellService.classify(exitCode: 1, stderr: "no such file"), .commandFailed)
        XCTAssertEqual(SecureShellService.classify(exitCode: 255, stderr: "macadmins@10.15.2.50: Permission denied (publickey)."), .authFailed)
        XCTAssertEqual(SecureShellService.classify(exitCode: 255, stderr: "ssh: connect to host 10.15.2.50 port 22: Operation timed out"), .unreachable)
        XCTAssertEqual(SecureShellService.classify(exitCode: 255, stderr: "ssh: connect to host 10.15.2.50 port 22: Connection refused"), .unreachable)
        XCTAssertEqual(SecureShellService.classify(exitCode: 255, stderr: "ssh: Could not resolve hostname foo.local: nodename nor servname provided"), .unreachable)
        XCTAssertEqual(SecureShellService.classify(exitCode: 255, stderr: "kex_exchange_identification: read: Connection reset by peer"), .unreachable)
        XCTAssertEqual(SecureShellService.classify(exitCode: 255, stderr: "something odd"), .error)
    }

    func testRunStatusMapsOutcomes() {
        XCTAssertEqual(CommandRunStatus(outcome: .success, exitCode: 0), .success)
        XCTAssertEqual(CommandRunStatus(outcome: .commandFailed, exitCode: 3), .failed(3))
        XCTAssertEqual(CommandRunStatus(outcome: .unreachable, exitCode: 255), .offline)
        XCTAssertEqual(CommandRunStatus(outcome: .authFailed, exitCode: 255), .authFailed)
        XCTAssertEqual(CommandRunStatus(outcome: .timeout, exitCode: 15), .timeout)
        XCTAssertEqual(CommandRunStatus(outcome: .cancelled, exitCode: 15), .cancelled)
        XCTAssertTrue(CommandRunStatus.failed(1).isTerminal)
        XCTAssertFalse(CommandRunStatus.running.isTerminal)
        XCTAssertEqual(CommandRunStatus.failed(7).label, "Exit 7")
    }

    func testFormattedResultBlock() {
        var result = CommandRunResult(computer: RosterComputer(serial: "C1", hostname: "B1122-01"), ip: "10.15.2.50")
        result.status = .failed(2)
        result.output = "line\n"
        result.errorOutput = "bad\n"
        XCTAssertEqual(result.formatted(), "B1122-01 (10.15.2.50) - exit 2\nline\nstderr:\nbad")
    }
}
