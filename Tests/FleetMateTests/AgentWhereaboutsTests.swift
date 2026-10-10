import XCTest
@testable import FleetMateCore

final class AgentWhereaboutsTests: XCTestCase {
    let home = "/Users/someone"
    let opened = Date(timeIntervalSince1970: 1_800_000_000)

    private var place: AgentWhereabouts {
        AgentWhereabouts(
            module: "Development", segment: "Repos",
            selection: .init(kind: "repository", id: "github/acme/widgets", title: "acme/widgets",
                             fields: ["path": "\(home)/Developer/GitHub/acme/widgets"]),
            workingDirectory: "\(home)/Developer/GitHub/acme/widgets",
            trackedRepositories: [
                .init(name: "acme/widgets", path: "\(home)/Developer/GitHub/acme/widgets",
                      remote: "https://github.com/acme/widgets.git", defaultBranch: "main"),
            ],
            backends: [.init(system: "GitHub", state: "signed in", user: "octo"),
                       .init(system: "Snipe-IT", state: "not signed in")])
    }

    func testWhereYouAreSection() {
        let md = place.markdown(openedAt: opened, home: home)
        XCTAssertTrue(md.hasPrefix("## Where you are\n"))
        XCTAssertTrue(md.contains("- Working directory: `~/Developer/GitHub/acme/widgets` — the acme/widgets checkout"))
        XCTAssertTrue(md.contains("- FleetMate module: Development › Repos"))
        XCTAssertTrue(md.contains("- Selected repository: acme/widgets (`github/acme/widgets`)"))
        XCTAssertTrue(md.contains("- acme/widgets — `~/Developer/GitHub/acme/widgets` ← https://github.com/acme/widgets.git (default branch main)"))
        XCTAssertTrue(md.contains("- GitHub: signed in as octo"))
        XCTAssertTrue(md.contains("- Snipe-IT: not signed in"))
        XCTAssertTrue(md.contains("$FLEETMATE_CONTEXT"))
    }

    func testEmptyPlace() {
        let md = AgentWhereabouts(module: "Tickets").markdown(openedAt: opened, home: home)
        XCTAssertTrue(md.contains("- FleetMate module: Tickets\n"))
        XCTAssertTrue(md.contains("- Nothing selected"))
        XCTAssertTrue(md.contains("- none yet"))
        XCTAssertFalse(md.contains("Working directory"))
    }

    func testSectionGoesAboveTheRules() {
        let brief = AgentBrief.markdown(dump: nil, cliPath: nil, cliVersion: nil)
        let combined = AgentBrief.inserting(place.markdown(openedAt: opened, home: home), into: brief)
        let whereIdx = combined.range(of: "## Where you are")!.lowerBound
        let rulesIdx = combined.range(of: "## Operate systems")!.lowerBound
        XCTAssertTrue(whereIdx < rulesIdx)
        XCTAssertTrue(combined.hasPrefix("# FleetMate agent brief"))
    }

    func testSessionBriefFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentBriefStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# FleetMate agent brief\n\nIntro.\n\n## Operate\n".write(toFile: store.briefPath, atomically: true, encoding: .utf8)
        let paths = store.writeSessionBrief(id: "abc", whereabouts: place, openedAt: opened)
        let md = try String(contentsOfFile: paths.briefPath, encoding: .utf8)
        XCTAssertTrue(md.contains("## Where you are"))
        let toml = try String(contentsOfFile: paths.codexValuePath, encoding: .utf8)
        XCTAssertTrue(toml.hasPrefix("\"# FleetMate agent brief\\n"))
        store.removeSessionBrief(id: "abc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.briefPath))
    }

    func testRoundTripsAsJSON() throws {
        let data = try JSONEncoder().encode(place)
        XCTAssertEqual(try JSONDecoder().decode(AgentWhereabouts.self, from: data), place)
    }
}
