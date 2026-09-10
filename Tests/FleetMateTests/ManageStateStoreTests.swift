import XCTest
@testable import FleetMateCore

final class ManageStateStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetmate-manage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHistoryRoundTripsNewestFirstAndTrims() {
        let store = ManageStateStore(root: root)
        XCTAssertEqual(store.loadHistory(), [])
        var history: [CommandHistoryEntry] = []
        for i in 0..<(ManageStateStore.historyLimit + 5) {
            history = store.addHistory(history, label: "cmd \(i)", command: "echo \(i)")
        }
        XCTAssertEqual(history.count, ManageStateStore.historyLimit)
        XCTAssertEqual(history.first?.label, "cmd \(ManageStateStore.historyLimit + 4)")
        let reloaded = store.loadHistory()
        XCTAssertEqual(reloaded.map(\.id), history.map(\.id))
        store.clearHistory()
        XCTAssertEqual(store.loadHistory(), [])
    }

    func testCustomGroupsRoundTrip() {
        let store = ManageStateStore(root: root)
        var group = CustomGroup(name: "Loaners")
        group.devices.append(AdhocDevice(hostname: "loaner-1", ip: "10.15.9.1"))
        group.devices.append(AdhocDevice(hostname: "", ip: "10.15.9.2", serial: "C02X"))
        store.saveCustomGroups([group])
        let back = store.loadCustomGroups()
        XCTAssertEqual(back, [group])
        XCTAssertEqual(back[0].devices[1].hostname, "10.15.9.2")
        XCTAssertEqual(back[0].room.displayName, "Loaners")
        XCTAssertEqual(back[0].room.computers.map(\.isAdhoc), [true, true])
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "not json".write(to: ManageStateStore(root: root).historyURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(ManageStateStore(root: root).loadHistory(), [])
    }

    func testCommandLibraryIsSeededThenMerged() throws {
        let store = ManageStateStore(root: root)
        let first = store.loadCommandLibrary()
        XCTAssertTrue(first.changed, "first load seeds the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.commandsPath))
        XCTAssertEqual(first.categories.count, CommandLibrary.loadBundled().count)

        // Operator edits one command and removes a whole category.
        var edited = first.categories
        edited[0].commands[0].command = "hostname -f"
        edited.removeLast()
        try CommandLibrary.save(edited, to: store.commandsPath)

        let second = store.loadCommandLibrary()
        XCTAssertTrue(second.changed, "the removed category comes back")
        XCTAssertEqual(second.categories[0].commands[0].command, "hostname -f", "the edit is kept")
        XCTAssertEqual(second.categories.count, first.categories.count)

        let third = store.loadCommandLibrary()
        XCTAssertFalse(third.changed)
    }

    func testCustomLibraryPathIsNotMerged() throws {
        let store = ManageStateStore(root: root)
        let custom = root.appendingPathComponent("mine.yaml").path
        try CommandLibrary.save([CommandCategory(name: "Only", commands: [
            ManageCommand(label: "One", command: "true", trustLevel: .safe)])], to: custom)
        let loaded = store.loadCommandLibrary(path: custom)
        XCTAssertFalse(loaded.changed)
        XCTAssertEqual(loaded.categories.map(\.name), ["Only"])
    }
}
