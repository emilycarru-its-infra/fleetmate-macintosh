import XCTest
@testable import FleetMateCore

final class DiffPatchTests: XCTestCase {

    func testParseGitDiff() {
        let text = """
        diff --git a/hello.txt b/hello.txt
        index e69de29..4b825dc 100644
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,3 +1,3 @@
         line one
        -old line
        +new line
         line three
        """
        let patch = DiffParser.parse(text)
        XCTAssertEqual(patch.files.count, 1)
        let file = patch.files[0]
        XCTAssertEqual(file.displayPath, "hello.txt")
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.insertions, 1)
        XCTAssertEqual(file.deletions, 1)
        let kinds = file.hunks[0].lines.map(\.kind)
        XCTAssertEqual(kinds, [.context, .deletion, .addition, .context])
        XCTAssertEqual(file.hunks[0].lines[1].oldLine, 2)
        XCTAssertEqual(file.hunks[0].lines[2].newLine, 2)
    }

    func testParseBareHunksLikeGitHubPatch() {
        // GitHub's /pulls/{n}/files `patch` field: hunks only, no file header.
        let patch = """
        @@ -10,2 +10,3 @@ func demo() {
         kept
        +added
         also kept
        """
        let file = DiffParser.parseBareHunks(patch, fileName: "Sources/App/Demo.swift")
        XCTAssertEqual(file.displayPath, "Sources/App/Demo.swift")
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.insertions, 1)
        XCTAssertEqual(file.deletions, 0)
        XCTAssertEqual(file.hunks[0].newStart, 10)
    }

    func testDiffBuilderFromTwoStrings() {
        let old = "alpha\nbeta\ngamma\ndelta\nepsilon"
        let new = "alpha\nbeta2\ngamma\ndelta\nepsilon\nzeta"
        let file = DiffBuilder.build(fileName: "config.yaml", old: old, new: new)
        XCTAssertEqual(file.displayPath, "config.yaml")
        XCTAssertEqual(file.insertions, 2)  // beta2 + zeta
        XCTAssertEqual(file.deletions, 1)   // beta
        XCTAssertFalse(file.hunks.isEmpty)
        // Every changed line carries the right marker with sane line numbers.
        let additions = file.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        XCTAssertTrue(additions.allSatisfy { $0.newLine != nil && $0.oldLine == nil })
    }

    func testDiffBuilderIdenticalContentHasNoHunks() {
        let same = "one\ntwo\nthree"
        let file = DiffBuilder.build(fileName: "same.txt", old: same, new: same)
        XCTAssertTrue(file.hunks.isEmpty)
        XCTAssertEqual(file.insertions, 0)
        XCTAssertEqual(file.deletions, 0)
    }
}
