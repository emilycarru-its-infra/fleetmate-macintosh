import XCTest
@testable import FleetMateCore

final class TicketBrowserUrlTests: XCTestCase {
    func testExplicitBrowserLinkBypassesHandoffWhileSharedLinkStaysUnmarked() {
        var config = FleetMateConfig()
        config.tdxBaseUrl = "https://support.example.invalid/TDWebApi"
        config.tdxAppId = 31
        config.tdxTicketingAppId = 44
        let shared = "https://support.example.invalid/TDNext/Apps/44/Tickets/TicketDet?TicketID=12345"
        XCTAssertEqual(config.tdxTicketWebUrl(12345), shared)
        XCTAssertEqual(config.tdxTicketBrowserUrl(12345), shared + "&ticketsmate=browser")
    }
}
