import XCTest
@testable import FleetMateCore

final class InboxHelperIdentityTests: XCTestCase {
    func testHelperResolvesTheAppItNamesInInfoPlist() {
        let info: [String: Any] = [AppIdentity.mainBundleIdentifierKey: "example.ticketsmate"]
        XCTAssertEqual(AppIdentity.mainBundleIdentifier(info: info, bundleIdentifier: "example.ticketsmate.inbox-agent"),
                       "example.ticketsmate")
    }

    func testAppResolvesItsOwnBundleIdentifier() {
        XCTAssertEqual(AppIdentity.mainBundleIdentifier(info: [:], bundleIdentifier: "example.fleetmate"), "example.fleetmate")
        XCTAssertNil(AppIdentity.mainBundleIdentifier(info: nil, bundleIdentifier: nil))
    }

    func testBlankNameFallsBackToBundleIdentifier() {
        let info: [String: Any] = [AppIdentity.mainBundleIdentifierKey: "  "]
        XCTAssertEqual(AppIdentity.mainBundleIdentifier(info: info, bundleIdentifier: "example.app"), "example.app")
    }

    func testHelperIdentifierIsTheJobLabel() {
        XCTAssertEqual(AppIdentity.inboxHelperIdentifier(main: "example.app"), "example.app.inbox-agent")
    }

    func testTicketsMateKeepsTheAppsDomainInsideTheHelper() {
        let info: [String: Any] = [AppIdentity.mainBundleIdentifierKey: "example.ticketsmate"]
        let main = AppIdentity.mainBundleIdentifier(info: info, bundleIdentifier: "example.ticketsmate.inbox-agent")
        XCTAssertEqual(AppEdition.ticketsMate.preferencesDomain(bundleIdentifier: main), "example.ticketsmate")
    }

    func testFailedPrintMeansNoJob() {
        XCTAssertEqual(InboxHelperJob.state(launchctlPrintOutput: "", exitStatus: 113), .notLoaded)
        XCTAssertTrue(InboxHelperJob.needsReload(.notLoaded))
    }

    func testJobRunningTheAppExecutableIsLegacy() {
        let output = """
        gui/501/example.app.inbox-agent = {
        \tstate = running
        \tprogram identifier = Contents/MacOS/TicketsMate (mode: 2)
        }
        """
        XCTAssertEqual(InboxHelperJob.state(launchctlPrintOutput: output, exitStatus: 0), .legacyProgram)
        XCTAssertTrue(InboxHelperJob.needsReload(.legacyProgram))
    }

    func testJobRunningTheHelperIsCurrent() {
        let output = """
        gui/501/example.app.inbox-agent = {
        \tprogram identifier = Contents/Library/LoginItems/TicketsMate Inbox Helper.app/Contents/MacOS/TicketsMate Inbox Helper (mode: 2)
        }
        """
        XCTAssertEqual(InboxHelperJob.state(launchctlPrintOutput: output, exitStatus: 0), .current)
        XCTAssertFalse(InboxHelperJob.needsReload(.current))
    }

    func testUnrecognisedOutputNeverForcesAReload() {
        XCTAssertEqual(InboxHelperJob.state(launchctlPrintOutput: "state = running", exitStatus: 0), .current)
    }

    func testHelperBundleName() {
        XCTAssertEqual(InboxHelperJob.helperBundleName(displayName: "TicketsMate"), "TicketsMate Inbox Helper.app")
    }
}
