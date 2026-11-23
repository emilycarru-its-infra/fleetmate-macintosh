import XCTest
@testable import FleetMateCore

final class AgentFolderPolicyTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("folder-policy-\(UUID().uuidString)")
        for dir in ["Developer/AzDevOps/Devices/Tool", "Developer/GitHub/work-org/listed", "Developer/GitHub/work-org/hidden",
                    "Developer/GitHub/other/repo", "Developer/Personal/notes", "Developer/AzDevOpsShadow"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    private func registry(zone: String? = AgentFolderPolicy.workZone) -> AgentAppsRepoRegistry {
        AgentAppsRepoRegistry(sections: [.init(name: "Work", repos: [
            .init(path: path("Developer/GitHub/work-org/listed").path),
            .init(path: path("Developer/GitHub/work-org/hidden").path, agents: false),
            .init(path: path("Developer/Personal/notes").path),
        ])], zone: zone)
    }

    private func allows(_ relative: String, registry: AgentAppsRepoRegistry? = nil, denied: [String] = []) -> Bool {
        AgentFolderPolicy.allows(path(relative), home: home.path, registry: registry ?? self.registry(), denied: denied)
    }

    func testTheWorkRootAndListedAgentReposAreAllowed() {
        XCTAssertTrue(allows("Developer/AzDevOps/Devices/Tool"))
        XCTAssertTrue(allows("Developer/GitHub/work-org/listed"))
        XCTAssertFalse(allows("Developer/GitHub/other/repo"))
    }

    func testARepoNotOfferedToAgentsIsDenied() {
        XCTAssertFalse(allows("Developer/GitHub/work-org/hidden"))
    }

    func testOnlyAWorkZoneRegistryCounts() {
        XCTAssertFalse(allows("Developer/GitHub/work-org/listed", registry: registry(zone: "personal")))
        XCTAssertFalse(allows("Developer/GitHub/work-org/listed", registry: registry(zone: nil)))
        XCTAssertTrue(allows("Developer/AzDevOps/Devices/Tool", registry: registry(zone: nil)), "the work root still counts")
    }

    func testDeniedFoldersWinOverTheRegistry() {
        XCTAssertFalse(allows("Developer/Personal/notes"))
        XCTAssertFalse(allows("Developer/GitHub/work-org/listed", denied: [path("Developer/GitHub/work-org").path]))
        XCTAssertFalse(allows("Developer/GitHub/work-org/listed", denied: ["~/Developer/GitHub/work-org"]))
    }

    func testWholeComponentsCaseInsensitiveAndCanonical() throws {
        XCTAssertFalse(allows("Developer/AzDevOpsShadow"), "not a string prefix")
        XCTAssertTrue(allows("developer/azdevops/devices/tool"), "case does not matter on APFS")
        XCTAssertFalse(allows("Developer/AzDevOps/../GitHub/other/repo"))
        XCTAssertFalse(allows("Developer/AzDevOps/Missing"), "a folder that cannot be canonicalized is denied")
    }

    func testSymlinksAreJudgedByWhereTheyLead() throws {
        let intoWork = path("Developer/GitHub/other/link-to-work")
        try FileManager.default.createSymbolicLink(at: intoWork, withDestinationURL: path("Developer/AzDevOps/Devices/Tool"))
        let outOfWork = path("Developer/AzDevOps/link-to-personal")
        try FileManager.default.createSymbolicLink(at: outOfWork, withDestinationURL: path("Developer/Personal/notes"))
        XCTAssertTrue(allows("Developer/GitHub/other/link-to-work"))
        XCTAssertFalse(allows("Developer/AzDevOps/link-to-personal"))
    }

    func testTheZoneIsReadFromTheFile() {
        let json = #"{"schema_version":1,"app":{"zone":"ecu"},"sections":[{"name":"A","repos":[{"path":"/x"}]}]}"#
        XCTAssertEqual(AgentAppsRepoRegistry.decode(Data(json.utf8))?.zone, "ecu")
    }
}
