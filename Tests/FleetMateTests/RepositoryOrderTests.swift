import XCTest
@testable import FleetMateCore

final class RepositoryOrderTests: XCTestCase {
    private let registryJSON = """
    {
      "schema_version": 1,
      "app": { "id": "example.app" },
      "sections": [
        { "name": "Tools", "repos": [
          { "path": "/work/tools/zeta", "name": "zeta" },
          { "path": "/work/tools/alpha", "name": "alpha", "surfaces": { "agents": false } }
        ] },
        { "name": "Apps", "repos": [
          { "path": "/work/apps/beta" },
          { "path": "/work/tools/zeta/" },
          { "path": "  " }
        ] }
      ]
    }
    """

    func testRegistryFlattensSectionsThenRepos() throws {
        let registry = try XCTUnwrap(AgentAppsRepoRegistry.decode(Data(registryJSON.utf8)))
        XCTAssertEqual(registry.orderedPaths, ["/work/tools/zeta", "/work/tools/alpha", "/work/apps/beta"])
        XCTAssertEqual(registry.agentPaths, ["/work/tools/zeta", "/work/apps/beta"])
        XCTAssertEqual(registry.sectionByPath["/work/apps/beta"], "Apps")
    }

    func testRegistryOfAnotherSchemaOrEmptyIsIgnored() {
        XCTAssertNil(AgentAppsRepoRegistry.decode(Data(#"{"schema_version": 2, "sections": [{"repos": [{"path": "/a"}]}]}"#.utf8)))
        XCTAssertNil(AgentAppsRepoRegistry.decode(Data(#"{"schema_version": 1, "sections": []}"#.utf8)))
        XCTAssertNil(AgentAppsRepoRegistry.decode(Data("not json".utf8)))
    }

    func testRegistryPathFollowsXDGConfigHome() {
        XCTAssertEqual(AgentAppsRepoRegistry.defaultPath(bundleIdentifier: "example.app", environment: [:], home: "/Users/a"),
                       "/Users/a/.config/agent-apps/repos/example.app.json")
        XCTAssertEqual(AgentAppsRepoRegistry.defaultPath(bundleIdentifier: "example.app",
                                                         environment: ["XDG_CONFIG_HOME": "/cfg"], home: "/Users/a"),
                       "/Users/a/.config/agent-apps/repos/example.app.json", "a folder that does not exist does not count")
        XCTAssertEqual(AgentAppsRepoRegistry.defaultPath(bundleIdentifier: "example.app",
                                                         environment: ["XDG_CONFIG_HOME": "relative"], home: "/Users/a"),
                       "/Users/a/.config/agent-apps/repos/example.app.json")
    }

    func testRankSortsKnownFirstAndKeepsTheRestInPlace() {
        let rank = RepositoryOrderRank(orderedPaths: ["/w/c", "/w/a"], names: ["/w/c": "Proj/C"])
        XCTAssertEqual(rank.sorted(["x", "/w/a", "y", "/W/C/"]) { rank.rank(path: $0) }, ["/W/C/", "/w/a", "x", "y"])
        XCTAssertEqual(rank.rank(name: "proj/c"), 0)
        XCTAssertNil(rank.rank(name: "Proj/A"))
    }

    func testSidebarFollowsRepositoryOrder() {
        let records = [
            record(.azureDevOps, "org", "Devices", "alpha", "/w/devices/alpha"),
            record(.azureDevOps, "org", "Devices", "beta", "/w/devices/beta"),
            record(.gitHub, "acme", nil, "zeta", "/w/acme/zeta"),
            record(.azureDevOps, "org", "Apps", "gamma", "/w/apps/gamma"),
        ]
        let order = RepositoryOrderRank(orderedPaths: ["/w/acme/zeta", "/w/devices/beta", "/w/apps/gamma"])
        let sections = RepoSidebarOrganizer.sections(records, statuses: [:], sort: .repositoryOrder, order: order)
        XCTAssertEqual(sections.map(\.title), ["GitHub", "Azure DevOps"])
        XCTAssertEqual(sections[1].groups.map(\.scope), ["Devices", "Apps"])
        XCTAssertEqual(sections[1].groups[0].records.map(\.key.name), ["beta", "alpha"])
        XCTAssertEqual(RepoSidebarOrganizer.flat(records, statuses: [:], sort: .repositoryOrder, order: order).map(\.key.name),
                       ["zeta", "beta", "gamma", "alpha"])
        // With no order, Repository Order falls back to the name.
        XCTAssertEqual(RepoSidebarOrganizer.flat(records, statuses: [:], sort: .repositoryOrder).map(\.key.name),
                       ["alpha", "beta", "gamma", "zeta"])
    }

    func testRepositoryFilterFollowsRepositoryOrderByName() {
        let entries = [
            RepositoryFilterEntry(scope: .init(source: .azureDevOps, container: "Devices", repository: "alpha"), count: 1),
            RepositoryFilterEntry(scope: .init(source: .azureDevOps, container: "Devices", repository: "beta"), count: 1),
            RepositoryFilterEntry(scope: .init(source: .azureDevOps, container: "Apps", repository: "gamma"), count: 1),
        ]
        let order = RepositoryOrderRank(orderedPaths: ["/w/b", "/w/g"], names: ["/w/b": "Devices/beta", "/w/g": "Apps/gamma"])
        let groups = RepositoryFilterProvider.groups(entries, order: order)
        XCTAssertEqual(groups[0].containers.map(\.name), ["Devices", "Apps"])
        XCTAssertEqual(groups[0].containers[0].entries.compactMap(\.scope.repository), ["beta", "alpha"])
        XCTAssertEqual(RepositoryFilterProvider.groups(entries)[0].containers.map(\.name), ["Apps", "Devices"])
    }

    private func record(_ provider: RepoProvider, _ owner: String, _ project: String?, _ name: String, _ path: String) -> RepoRecord {
        let key = RepoKey(provider: provider, owner: owner, project: project, name: name)
        return RepoRecord(key: key, catalog: nil, local: RepoRegistryEntry(key: key, path: path, tracked: true))
    }
}
