import XCTest
@testable import FleetMateCore

final class RepoIconStoreTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "repo-icons-\(UUID().uuidString)/repo-icons.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func testMissingFileIsNoChoices() {
        XCTAssertTrue(RepoIconStore(path: path).load().isEmpty)
    }

    func testChoiceRoundTrips() throws {
        let store = RepoIconStore(path: path)
        try store.set(RepoIconChoice(icon: "svg:rocket", tint: "#FF8800"), for: "github:owner/repo")
        try store.set(RepoIconChoice(icon: "sf:hammer"), for: "github:owner/other")
        let loaded = RepoIconStore(path: path).load()
        XCTAssertEqual(loaded["github:owner/repo"], RepoIconChoice(icon: "svg:rocket", tint: "#FF8800"))
        XCTAssertEqual(loaded["github:owner/other"], RepoIconChoice(icon: "sf:hammer", tint: nil))
    }

    func testSettingAgainReplacesTheChoice() throws {
        let store = RepoIconStore(path: path)
        try store.set(RepoIconChoice(icon: "sf:hammer", tint: "#112233"), for: "github:owner/repo")
        try store.set(RepoIconChoice(icon: "sf:leaf"), for: "github:owner/repo")
        XCTAssertEqual(store.load(), ["github:owner/repo": RepoIconChoice(icon: "sf:leaf")])
    }

    func testResetRemovesOnlyThatRepository() throws {
        let store = RepoIconStore(path: path)
        try store.set(RepoIconChoice(icon: "sf:hammer"), for: "github:owner/a")
        try store.set(RepoIconChoice(icon: "sf:leaf"), for: "github:owner/b")
        let after = try store.set(nil, for: "github:owner/a")
        XCTAssertEqual(Array(after.keys), ["github:owner/b"])
        XCTAssertEqual(store.load().keys.sorted(), ["github:owner/b"])
    }

    func testUnreadableFileIsNoChoices() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(RepoIconStore(path: path).load().isEmpty)
    }
}
