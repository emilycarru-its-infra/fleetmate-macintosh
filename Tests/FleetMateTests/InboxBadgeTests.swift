import XCTest
@testable import FleetMateCore

final class InboxBadgeTests: XCTestCase {
    func testZeroAndNegativeShowNoBadge() {
        XCTAssertNil(InboxBadge.text(count: 0))
        XCTAssertNil(InboxBadge.text(count: -3))
    }

    func testCountsShowAsTheNumber() {
        XCTAssertEqual(InboxBadge.text(count: 1), "1")
        XCTAssertEqual(InboxBadge.text(count: 42), "42")
        XCTAssertEqual(InboxBadge.text(count: 999), "999")
    }

    func testCountsAboveTheCapAreCapped() {
        XCTAssertEqual(InboxBadge.text(count: 1000), "999+")
        XCTAssertEqual(InboxBadge.text(count: 25_000), "999+")
    }

    private func dock(_ count: Int, ready: Bool = true, enabled: Bool = true,
                      tickets: Bool = true, helper: Bool = false) -> String? {
        InboxBadge.dockLabel(unreadCount: count, inboxReady: ready, enabled: enabled,
                             ticketsOn: tickets, isHelper: helper)
    }

    func testDockShowsTheCountWhenEverythingAllowsIt() {
        XCTAssertEqual(dock(7), "7")
        XCTAssertEqual(dock(1500), "999+")
    }

    func testDockClearsAtZero() {
        XCTAssertNil(dock(0))
    }

    func testDockClearsWhenTheSettingIsOff() {
        XCTAssertNil(dock(7, enabled: false))
    }

    func testDockClearsWhileTheInboxIsIncomplete() {
        XCTAssertNil(dock(7, ready: false))
    }

    func testDockClearsWithTicketsSwitchedOff() {
        XCTAssertNil(dock(7, tickets: false))
    }

    func testHelperNeverBadges() {
        XCTAssertNil(dock(7, helper: true))
    }

    func testSettingDefaultsOnAndRoundTrips() {
        let name = "InboxBadgeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(InboxBadge.isDockBadgeEnabled(in: defaults))
        defaults.set(false, forKey: InboxBadge.dockSettingKey)
        XCTAssertFalse(InboxBadge.isDockBadgeEnabled(in: defaults))
        defaults.set(true, forKey: InboxBadge.dockSettingKey)
        XCTAssertTrue(InboxBadge.isDockBadgeEnabled(in: defaults))
    }
}
