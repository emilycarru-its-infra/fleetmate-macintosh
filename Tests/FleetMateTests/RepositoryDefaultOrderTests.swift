import XCTest
@testable import FleetMateCore

final class RepositoryDefaultOrderTests: XCTestCase {
    private func entry(_ path: String, _ provider: RepoProvider, _ scope: String, _ name: String) -> RepositoryDefaultOrder.Entry {
        .init(path: path, provider: provider, scope: scope, name: name)
    }

    func testDevicesLeadsAndGitHubComesLastWithNoRegistry() {
        let entries = [
            entry("/w/GitHub/zed/app", .gitHub, "zed", "app"),
            entry("/w/AzDevOps/Cloud/tf", .azureDevOps, "Cloud", "tf"),
            entry("/w/AzDevOps/Applications/web", .azureDevOps, "Applications", "web"),
            entry("/w/AzDevOps/Devices/Cimian", .azureDevOps, "Devices", "Cimian"),
            entry("/w/GitHub/acme/tool", .gitHub, "acme", "tool"),
        ]
        XCTAssertEqual(RepositoryDefaultOrder.make(listed: [], entries: entries), [
            "/w/AzDevOps/Devices/Cimian", "/w/AzDevOps/Applications/web", "/w/AzDevOps/Cloud/tf",
            "/w/GitHub/acme/tool", "/w/GitHub/zed/app",
        ])
    }

    func testRegistryOrderHoldsWithinAProviderButGitHubStaysLast() {
        let entries = [
            entry("/w/GitHub/acme/tool", .gitHub, "acme", "tool"),
            entry("/w/AzDevOps/Cloud/tf", .azureDevOps, "Cloud", "tf"),
            entry("/w/AzDevOps/Devices/Cimian", .azureDevOps, "Devices", "Cimian"),
            entry("/w/AzDevOps/Devices/Munki", .azureDevOps, "Devices", "Munki"),
        ]
        let listed = ["/w/AzDevOps/Devices/Munki", "/w/GitHub/acme/tool", "/w/AzDevOps/Devices/Cimian"]
        XCTAssertEqual(RepositoryDefaultOrder.make(listed: listed, entries: entries), [
            "/w/AzDevOps/Devices/Munki", "/w/AzDevOps/Devices/Cimian", "/w/AzDevOps/Cloud/tf", "/w/GitHub/acme/tool",
        ])
    }

    func testFolderThatIsNoCheckoutSitsBetweenAndGitHubPathIsLast() {
        let entries = [entry("/w/AzDevOps/Devices/Cimian", .azureDevOps, "Devices", "Cimian")]
        let listed = ["/w/GitHub/acme/untracked", "/w/AzDevOps", "/w/AzDevOps/Devices/Cimian"]
        XCTAssertEqual(RepositoryDefaultOrder.make(listed: listed, entries: entries), [
            "/w/AzDevOps/Devices/Cimian", "/w/AzDevOps", "/w/GitHub/acme/untracked",
        ])
    }
}

final class LaneHostRoutingTests: XCTestCase {
    private let json = """
    {"schema_version": 1, "sections": [{"name": "Devices", "repos": [
      {"path": "/w/AzDevOps/Devices/Cimian", "host": "hubhost"},
      {"path": "/w/AzDevOps/Devices/Local"},
      {"path": "/w/AzDevOps", "kind": "folder", "host": "winhost"}
    ]}]}
    """

    private func route(_ directory: String, selfName: String = "laptop") -> LaneHostRouting.Route? {
        LaneHostRouting.route(directory: directory, registry: AgentAppsRepoRegistry.decode(Data(json.utf8)),
                              selfName: selfName, hub: "hubhost", laneHosts: ["hubhost", "winhost"])
    }

    func testRepositoryOnAnotherHostRoutesThere() {
        XCTAssertEqual(route("/w/AzDevOps/Devices/Cimian"), .init(host: "hubhost", isHub: true))
        XCTAssertNil(route("/w/AzDevOps/Devices/Cimian")?.laneHost)
    }

    func testWorktreeFollowsItsRepositoryAndAFolderMatchesOnlyItself() {
        XCTAssertEqual(route("/w/AzDevOps/Devices/Cimian/.worktrees/fix")?.host, "hubhost")
        XCTAssertEqual(route("/w/AzDevOps")?.laneHost, "winhost")
        XCTAssertNil(route("/w/AzDevOps/Other"))
    }

    func testRunsHereWhenThisMacIsTheHostOrNoHostIsGiven() {
        XCTAssertNil(route("/w/AzDevOps/Devices/Cimian", selfName: "hubhost"))
        XCTAssertNil(route("/w/AzDevOps/Devices/Local"))
        XCTAssertNil(route("/elsewhere"))
    }

    func testHostNotInHostsConfIsNotRoutable() {
        let unknown = LaneHostRouting.route(directory: "/w/AzDevOps/Devices/Cimian",
                                            registry: AgentAppsRepoRegistry.decode(Data(json.utf8)),
                                            selfName: "laptop", hub: "hubhost", laneHosts: ["winhost"])
        XCTAssertNil(unknown)
    }

    func testRemoteCommandFollowsTheAgent() {
        XCTAssertEqual(LaneHostRouting.remoteCommand(for: "claude"), "claude-remote")
        XCTAssertEqual(LaneHostRouting.remoteCommand(for: "codex --sandbox workspace-write"), "codex-remote")
        XCTAssertEqual(LaneHostRouting.remoteCommand(for: "claude-remote"), "claude-remote")
        XCTAssertNil(LaneHostRouting.remoteCommand(for: ""))
        XCTAssertNil(LaneHostRouting.remoteCommand(for: "zsh"))
    }
}
