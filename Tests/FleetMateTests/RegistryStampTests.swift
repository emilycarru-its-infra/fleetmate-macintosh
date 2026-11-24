import XCTest
@testable import FleetMateCore

final class RegistryStampTests: XCTestCase {
    func testAStampChangesWhenAnyFileIsRewrittenOrAppears() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tracked = folder.appendingPathComponent("repos.json").path
        let rendered = folder.appendingPathComponent("app.json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: tracked))
        let before = RegistryStamp(files: [tracked, rendered])
        XCTAssertEqual(before, RegistryStamp(files: [tracked, rendered]), "nothing changed")

        try Data("{}".utf8).write(to: URL(fileURLWithPath: rendered))
        let appeared = RegistryStamp(files: [tracked, rendered])
        XCTAssertNotEqual(before, appeared, "a rendered registry that appears is a change")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: rendered)
        XCTAssertNotEqual(appeared, RegistryStamp(files: [tracked, rendered]), "a rewritten rendered registry is a change")
        XCTAssertEqual(RegistryStamp(files: [nil]), RegistryStamp(files: [nil]), "no path is no change")
    }
}
