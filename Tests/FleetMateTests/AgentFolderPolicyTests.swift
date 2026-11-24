import XCTest
@testable import FleetMateCore

final class AgentFolderPolicyTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("folder-policy-\(UUID().uuidString)")
        for dir in ["Developer/AzDevOps/Devices/Tool", "Developer/AzDevOps/Private/Keys",
                    "Developer/GitHub/work-org/listed", "Developer/GitHub/work-org/hidden",
                    "Developer/GitHub/other/repo", "Developer/Personal/notes", "Developer/AzDevOpsShadow",
                    "Developer/GitHub/mixed/denied-child"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    private var registry: AgentFolderPolicy.WorkRegistry {
        AgentFolderPolicy.WorkRegistry(agentRepos: [path("Developer/GitHub/work-org/listed").path,
                                                    path("Developer/GitHub/mixed").path,
                                                    path("Developer/Personal/notes").path],
                                       hiddenRepos: [path("Developer/GitHub/work-org/hidden").path])
    }

    private func allows(_ relative: String, registry: AgentFolderPolicy.WorkRegistry?? = .none,
                        denied: [String] = []) -> Bool {
        let chosen: AgentFolderPolicy.WorkRegistry? = registry ?? self.registry
        return AgentFolderPolicy.allows(path(relative), home: home.path, registry: chosen, denied: denied)
    }

    func testTheWorkRootAndListedAgentReposAreAllowed() {
        XCTAssertTrue(allows("Developer/AzDevOps/Devices/Tool"))
        XCTAssertTrue(allows("Developer/GitHub/work-org/listed"))
        XCTAssertFalse(allows("Developer/GitHub/other/repo"))
    }

    func testARepoHiddenFromAgentsIsDeniedAndSoIsItsParent() {
        XCTAssertFalse(allows("Developer/GitHub/work-org/hidden"))
        let parent = AgentFolderPolicy.WorkRegistry(agentRepos: [path("Developer/GitHub/work-org").path],
                                                    hiddenRepos: [path("Developer/GitHub/work-org/hidden").path])
        XCTAssertFalse(allows("Developer/GitHub/work-org", registry: parent), "a parent would expose the hidden repo")
        XCTAssertTrue(allows("Developer/GitHub/work-org/listed", registry: parent))
    }

    func testOnlyAWorkZoneRegistryCounts() {
        let file = { (zone: String) in
            Data(#"{"schema_version":1,"app":{"zone":"\#(zone)"},"sections":[{"repos":[{"path":"/x"},{"path":"/y","surfaces":{"agents":false}}]}]}"#.utf8)
        }
        XCTAssertEqual(AgentFolderPolicy.workRegistry(from: file(AgentFolderPolicy.workZone)),
                       AgentFolderPolicy.WorkRegistry(agentRepos: ["/x"], hiddenRepos: ["/y"]))
        XCTAssertNil(AgentFolderPolicy.workRegistry(from: file("personal")))
        XCTAssertNil(AgentFolderPolicy.workRegistry(from: Data(#"{"schema_version":2,"app":{"zone":"ecu"}}"#.utf8)))
        XCTAssertFalse(allows("Developer/GitHub/work-org/listed", registry: .some(nil)))
        XCTAssertTrue(allows("Developer/AzDevOps/Devices/Tool", registry: .some(nil)), "the work root still counts")
    }

    func testDeniedFoldersBlockBothWays() {
        XCTAssertFalse(allows("Developer/Personal/notes"), "the registry cannot allow a denied folder")
        XCTAssertFalse(allows("Developer/GitHub/work-org/listed", denied: ["~/Developer/GitHub/work-org"]))
        XCTAssertFalse(allows("Developer/AzDevOps", denied: [path("Developer/AzDevOps/Private").path]),
                       "a work root with a denied folder inside")
        XCTAssertTrue(allows("Developer/AzDevOps/Devices/Tool", denied: [path("Developer/AzDevOps/Private").path]))
        XCTAssertFalse(allows("Developer/GitHub/mixed", denied: [path("Developer/GitHub/mixed/denied-child").path]),
                       "a registry entry above a denied folder")
        XCTAssertFalse(allows("Developer"), "above the personal tree")
    }

    func testWholeComponentsAndCanonicalPaths() {
        XCTAssertFalse(allows("Developer/AzDevOpsShadow"), "not a string prefix")
        XCTAssertFalse(allows("Developer/AzDevOps/../GitHub/other/repo"))
        XCTAssertFalse(allows("Developer/AzDevOps/Missing"), "a folder that cannot be canonicalized is denied")
        // canonicalPath gives the on-disk spelling, so another case of an
        // existing folder matches on a volume that folds case, and not on one
        // that tells case apart.
        let folds = !AgentFolderPolicy.volumeIsCaseSensitive(path("Developer").pathComponents)
        XCTAssertEqual(allows("developer/azdevops/devices/tool"), folds)
    }

    func testSymlinksAreJudgedByWhereTheyLead() throws {
        try FileManager.default.createSymbolicLink(at: path("Developer/GitHub/other/link-to-work"),
                                                   withDestinationURL: path("Developer/AzDevOps/Devices/Tool"))
        try FileManager.default.createSymbolicLink(at: path("Developer/AzDevOps/link-to-personal"),
                                                   withDestinationURL: path("Developer/Personal/notes"))
        XCTAssertTrue(allows("Developer/GitHub/other/link-to-work"))
        XCTAssertFalse(allows("Developer/AzDevOps/link-to-personal"))
    }
}

final class AgentFolderPolicyRegistryFileTests: XCTestCase {
    func testThePolicyReadsTheRegistryWhereTheAppDoesUnderXDGConfigHome() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("folder-policy-xdg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let repo = home.appendingPathComponent("Developer/GitHub/work-org/listed")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let config = base.appendingPathComponent("xdg")
        let reposDir = config.appendingPathComponent("agent-apps/repos")
        try FileManager.default.createDirectory(at: reposDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
        let json = #"{"schema_version":1,"app":{"zone":"ecu"},"sections":[{"name":"W","repos":[{"path":"\#(repo.path)"}]}]}"#
        let written = reposDir.appendingPathComponent("example.app.json")
        try Data(json.utf8).write(to: written)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: written.path)
        let env = ["XDG_CONFIG_HOME": config.path]
        let file = AgentAppsRepoRegistry.defaultPath(bundleIdentifier: "example.app", environment: env, home: home.path)
        XCTAssertEqual(URL(fileURLWithPath: file).resolvingSymlinksInPath(), written.resolvingSymlinksInPath(),
                       "a private XDG_CONFIG_HOME wins over ~/.config")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: written.path)
        XCTAssertTrue(AgentAppsRepoRegistry.defaultPath(bundleIdentifier: "example.app", environment: env, home: home.path)
                        .hasPrefix(home.path), "a file others can write does not count")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: written.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: config.path)
        XCTAssertTrue(AgentAppsRepoRegistry.defaultPath(bundleIdentifier: "example.app", environment: env, home: home.path)
                        .hasPrefix(home.path), "a folder others can write does not count")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
        XCTAssertEqual(AgentAppsRepoRegistry.decode(Data(json.utf8))?.agentPaths, [repo.path], "the app reads the same repos")
        XCTAssertTrue(AgentFolderPolicy.allows(repo, home: home.path, registryFile: URL(fileURLWithPath: file), denied: []))
        let unused = home.appendingPathComponent(".config/agent-apps/repos/example.app.json")
        XCTAssertFalse(AgentFolderPolicy.allows(repo, home: home.path, registryFile: unused, denied: []),
                       "no file where XDG_CONFIG_HOME does not point")
        let work = home.appendingPathComponent("Developer/AzDevOps/Tool")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertFalse(AgentFolderPolicy.allows(work, home: home.path, registryFile: unused, denied: []),
                       "no valid registry: nothing, not even the work root")
    }
}
