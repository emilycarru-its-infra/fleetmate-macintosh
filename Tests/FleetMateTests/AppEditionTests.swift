import XCTest
@testable import FleetMateCore

final class AppEditionTests: XCTestCase {
    func testMissingOrUnknownValueIsFleetMate() {
        XCTAssertEqual(AppEdition(infoValue: nil), .fleetMate)
        XCTAssertEqual(AppEdition(infoValue: "Something"), .fleetMate)
        XCTAssertEqual(AppEdition(infoValue: "TicketsMate"), .ticketsMate)
    }

    func testEditionsKeepSeparateSettings() {
        XCTAssertEqual(AppEdition.fleetMate.supportDirectory, "~/.fleetmate")
        XCTAssertEqual(AppEdition.ticketsMate.supportDirectory, "~/.ticketsmate")
        XCTAssertTrue(AppEdition.ticketsMate.supportPath("config.yaml").hasSuffix("/.ticketsmate/config.yaml"))
    }

    func testTicketsMateLogsApartFromFleetMate() {
        XCTAssertEqual(AppEdition.fleetMate.logDirectory, "~/.fleetmate")
        XCTAssertEqual(AppEdition.ticketsMate.logDirectory, "~/Library/Logs/TicketsMate")
    }

    func testFleetMateKeepsItsDomainWhateverTheBundle() {
        XCTAssertEqual(AppEdition.fleetMate.preferencesDomain(bundleIdentifier: nil), AppEdition.fleetMateDomain)
        XCTAssertEqual(AppEdition.fleetMate.preferencesDomain(bundleIdentifier: "example.other"), AppEdition.fleetMateDomain)
    }

    func testTicketsMateUsesItsBundleIdentifier() {
        XCTAssertEqual(AppEdition.ticketsMate.preferencesDomain(bundleIdentifier: "example.ticketsmate"), "example.ticketsmate")
        XCTAssertTrue(AppEdition.ticketsMate.isTicketsOnly)
        XCTAssertFalse(AppEdition.fleetMate.isTicketsOnly)
    }
}
