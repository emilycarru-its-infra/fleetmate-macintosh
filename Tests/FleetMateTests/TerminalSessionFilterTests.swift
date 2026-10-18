import XCTest
@testable import FleetMateCore

final class TerminalSessionFilterTests: XCTestCase {
    private func traits(agent: Bool = false, running: Bool = false, paused: Bool = false,
                        _ text: [String] = [], at seconds: TimeInterval? = nil) -> TerminalSessionTraits {
        TerminalSessionTraits(isAgent: agent, isRunning: running, isPaused: paused, searchable: text,
                              lastActivity: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    func testNoFilterMatchesEverything() {
        let filter = TerminalSessionFilter()
        XCTAssertFalse(filter.isFiltering)
        XCTAssertTrue(filter.matches(traits()))
    }

    func testTogglesIntersect() {
        let filter = TerminalSessionFilter(active: true, paused: true)
        XCTAssertTrue(filter.matches(traits(agent: true, paused: true)))
        XCTAssertFalse(filter.matches(traits(agent: true)))
        XCTAssertFalse(filter.matches(traits(paused: true)))
    }

    func testSearchMatchesEveryWordAcrossFields() {
        let filter = TerminalSessionFilter(query: "  Fleet main ")
        XCTAssertTrue(filter.isFiltering)
        XCTAssertTrue(filter.matches(traits(["fleetmate", "~/src/main"])))
        XCTAssertFalse(filter.matches(traits(["fleetmate", "~/src/other"])))
    }

    func testSearchCombinesWithToggles() {
        let filter = TerminalSessionFilter(running: true, query: "codex")
        XCTAssertTrue(filter.matches(traits(running: true, ["Codex"])))
        XCTAssertFalse(filter.matches(traits(["Codex"])))
    }

    func testOrderByRecentActivity() {
        let items = [traits(at: 10), traits(), traits(at: 30), traits(at: 20)]
        XCTAssertEqual(TerminalSessionFilter.order(items, by: .manual), [0, 1, 2, 3])
        XCTAssertEqual(TerminalSessionFilter.order(items, by: .recentFirst), [2, 3, 0, 1])
        XCTAssertEqual(TerminalSessionFilter.order(items, by: .recentLast), [1, 0, 3, 2])
    }
}
