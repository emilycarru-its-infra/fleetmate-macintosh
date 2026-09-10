import XCTest
@testable import FleetMateCore

final class ScanLabImportTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ManageStateStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scanlab-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ca.ecuad.scanlab.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ManageStateStore(root: root)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// What ScanLab wrote: JSONEncoder defaults, so dates are seconds since 2001.
    private func seedDefaults(groups: String? = nil, history: String? = nil) {
        if let groups { defaults.set(Data(groups.utf8), forKey: ScanLabImport.customGroupsKey) }
        if let history { defaults.set(Data(history.utf8), forKey: ScanLabImport.historyKey) }
    }

    private func importer(libraryPath: String? = nil) -> ScanLabImport {
        ScanLabImport(defaults: defaults, scanLabLibraryPath: libraryPath ?? root.appendingPathComponent("absent.yaml").path, store: store)
    }

    func testNothingToImportIsEmptyReport() {
        XCTAssertFalse(importer().hasSource)
        let report = importer().run()
        XCTAssertTrue(report.isEmpty)
    }

    func testGroupsAreAddedAndDuplicatesByNameSkipped() {
        seedDefaults(groups: """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Loaners","devices":[
            {"id":"22222222-2222-2222-2222-222222222222","hostname":"loaner-1","ip":"10.15.9.1"},
            {"id":"33333333-3333-3333-3333-333333333333","hostname":"10.15.9.2","ip":"10.15.9.2"}]},
         {"id":"44444444-4444-4444-4444-444444444444","name":"Kiosks","devices":[]}]
        """)
        store.saveCustomGroups([CustomGroup(name: "kiosks")])

        XCTAssertTrue(importer().hasSource)
        let report = importer().run()
        XCTAssertEqual(report.groupsAdded, 1)
        XCTAssertEqual(report.groupsSkipped, 1)
        let groups = store.loadCustomGroups()
        XCTAssertEqual(groups.map(\.name), ["kiosks", "Loaners"])
        XCTAssertEqual(groups[1].id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(groups[1].devices.map(\.ip), ["10.15.9.1", "10.15.9.2"])
        XCTAssertNil(groups[1].devices[0].serial)

        XCTAssertEqual(importer().run().groupsAdded, 0, "a second run adds nothing")
    }

    func testHistoryMergesNewestFirstWithoutDuplicates() {
        let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)
        seedDefaults(history: """
        [{"id":"55555555-5555-5555-5555-555555555555","label":"Uptime","command":"uptime","date":800000000},
         {"id":"66666666-6666-6666-6666-666666666666","label":"Hostname","command":"hostname","date":700000000}]
        """)
        _ = store.addHistory([], label: "Hostname", command: "hostname")

        let report = importer().run()
        XCTAssertEqual(report.historyAdded, 1)
        let history = store.loadHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.command).sorted(), ["hostname", "uptime"])
        XCTAssertEqual(history.first { $0.command == "uptime" }?.date, reference)
    }

    func testLibraryImportsOnlyWhatTheBundledLibraryLacks() throws {
        let theirs = root.appendingPathComponent("scanlab-commands.yaml").path
        try CommandLibrary.save([
            CommandCategory(name: "System", commands: [
                ManageCommand(label: "Hostname", command: "hostname", trustLevel: .safe),
                ManageCommand(label: "My custom check", command: "echo mine", trustLevel: .safe),
            ]),
            CommandCategory(name: "Studio Tools", commands: [
                ManageCommand(label: "Reset tablet driver", command: "sudo killall -9 TabletDriver", trustLevel: .destructive),
            ]),
        ], to: theirs)

        let report = importer(libraryPath: theirs).run()
        XCTAssertEqual(report.commandsAdded, 2)
        XCTAssertEqual(report.categoriesAdded, 1)
        XCTAssertEqual(report.libraryPath, store.commandsPath)

        let mine = store.loadCommandLibrary().categories
        XCTAssertTrue(mine.contains { $0.name == "Studio Tools" })
        let system = try XCTUnwrap(mine.first { $0.name == "System" })
        XCTAssertEqual(system.commands.filter { $0.label == "Hostname" }.count, 1, "bundled command is not duplicated")
        XCTAssertTrue(system.commands.contains { $0.label == "My custom check" })

        XCTAssertEqual(importer(libraryPath: theirs).run().commandsAdded, 0, "a second run adds nothing")
    }

    func testReportSummaryReadsNaturally() {
        var report = ScanLabImport.Report()
        report.groupsAdded = 2
        report.groupsSkipped = 1
        report.historyAdded = 1
        report.commandsAdded = 3
        report.categoriesAdded = 1
        XCTAssertEqual(report.summary, "2 groups added (1 already present), 1 history entry added, 3 commands added in 1 new category")
    }
}
