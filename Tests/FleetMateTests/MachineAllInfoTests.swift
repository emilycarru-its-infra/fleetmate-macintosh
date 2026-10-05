import XCTest
@testable import FleetMateCore

final class MachineAllInfoTests: XCTestCase {
    func testAllInfoListsRosterAndProbeFacts() {
        let computer = RosterComputer(serial: "SERIAL01", location: "Room 101", asset: "A100", fleet: "Lab", hostname: "lab-mac-01")
        let info = MachineInfo(hostname: "lab-mac-01", ip: "10.0.0.5", consoleUser: "student",
                               osVersion: "15.5", uptime: "2 days", sshPortListening: true,
                               screenSharingState: "running", screenSharingPortListening: true,
                               topApps: ["Safari", "Finder"], clientIdentifier: "lab-client")
        let text = computer.allInfo(ip: "10.0.0.5", status: "Online", info: info)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("IP: 10.0.0.5"))
        XCTAssertTrue(lines.contains("Serial: SERIAL01"))
        XCTAssertTrue(lines.contains("Asset: A100"))
        XCTAssertTrue(lines.contains("Status: Online"))
        XCTAssertTrue(lines.contains("Console user: student"))
        XCTAssertTrue(lines.contains("OS: macOS 15.5"))
        XCTAssertTrue(lines.contains("Remote access: SSH ready, Screen Sharing ready"))
        XCTAssertTrue(lines.contains("Client identifier: lab-client"))
        XCTAssertTrue(lines.contains("Apps: Safari, Finder"))
    }

    func testAllInfoWithoutProbeOmitsProbeLines() {
        let computer = RosterComputer(serial: "SERIAL02")
        let text = computer.allInfo(ip: nil, status: "Offline", info: nil)
        XCTAssertFalse(text.contains("Console user"))
        XCTAssertFalse(text.contains("IP:"))
        XCTAssertTrue(text.contains("Status: Offline"))
    }
}
