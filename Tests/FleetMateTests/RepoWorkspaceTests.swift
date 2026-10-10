import XCTest
@testable import FleetMateCore

final class RepoFileTreeTests: XCTestCase {

    private let paths = [
        "README.md",
        "Sources/App/main.swift",
        "Sources/App/Views/Editor.swift",
        "Sources/Core/Model.swift",
        "Package.swift",
        ".gitignore",
        "docs/guide.md",
        "Sources/App/file10.swift",
        "Sources/App/file2.swift",
    ]

    func testFoldersFirstThenFilesInFinderOrder() {
        let tree = RepoFileTree.build(paths)
        XCTAssertEqual(tree.map(\.name), ["docs", "Sources", ".gitignore", "Package.swift", "README.md"])
        let app = tree[1].children?.first
        XCTAssertEqual(app?.path, "Sources/App")
        XCTAssertEqual(app?.children?.map(\.name), ["Views", "file2.swift", "file10.swift", "main.swift"])
        XCTAssertEqual(app?.children?.first?.children?.first?.path, "Sources/App/Views/Editor.swift")
    }

    func testFilesHaveNoChildrenAndFoldersDo() {
        let tree = RepoFileTree.build(paths)
        XCTAssertTrue(tree[0].isFolder)
        XCTAssertNil(tree.last?.children)
        XCTAssertEqual(RepoFileTree.fileCount(tree), paths.count)
    }

    func testIgnoresEmptyAndDuplicateSeparators() {
        let tree = RepoFileTree.build(["", "a//b.txt", "a/b.txt"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].children?.map(\.path), ["a/b.txt"])
    }

    func testFilterKeepsMatchingFilesAndTheirFolders() {
        let tree = RepoFileTree.build(paths)
        let filtered = RepoFileTree.filter(tree, matching: "editor")
        XCTAssertEqual(RepoFileTree.fileCount(filtered), 1)
        XCTAssertEqual(RepoFileTree.folderPaths(filtered), ["Sources", "Sources/App", "Sources/App/Views"])
    }

    func testFilterOnFolderNameKeepsItsContents() {
        let tree = RepoFileTree.build(paths)
        let filtered = RepoFileTree.filter(tree, matching: "DOCS")
        XCTAssertEqual(filtered.map(\.path), ["docs"])
        XCTAssertEqual(filtered[0].children?.map(\.path), ["docs/guide.md"])
    }

    func testFilterMatchesThroughThePath() {
        let tree = RepoFileTree.build(paths)
        let filtered = RepoFileTree.filter(tree, matching: "core/mod")
        XCTAssertEqual(RepoFileTree.fileCount(filtered), 1)
    }

    func testVisibleRowsDescendOnlyIntoExpandedFolders() {
        let tree = RepoFileTree.build(paths)
        let collapsed = RepoFileTree.visibleRows(tree, expanded: [])
        XCTAssertEqual(collapsed.map(\.node.path), ["docs", "Sources", ".gitignore", "Package.swift", "README.md"])
        XCTAssertTrue(collapsed.allSatisfy { $0.depth == 0 && !$0.isExpanded })

        let open = RepoFileTree.visibleRows(tree, expanded: ["Sources", "Sources/Core", "Sources/App/Views"])
        XCTAssertEqual(open.map(\.node.path), [
            "docs", "Sources", "Sources/App", "Sources/Core", "Sources/Core/Model.swift",
            ".gitignore", "Package.swift", "README.md",
        ], "a folder inside a collapsed one stays hidden even when marked expanded")
        XCTAssertEqual(open.first { $0.node.path == "Sources/Core/Model.swift" }?.depth, 2)
        XCTAssertEqual(open.first { $0.node.path == "Sources" }?.isExpanded, true)
    }

    func testEmptyFilterReturnsTheTree() {
        let tree = RepoFileTree.build(paths)
        XCTAssertEqual(RepoFileTree.filter(tree, matching: "  "), tree)
        XCTAssertTrue(RepoFileTree.filter(tree, matching: "absent").isEmpty)
    }
}

final class RepoRecordGroupTests: XCTestCase {

    private func record(_ provider: RepoProvider, _ owner: String, _ project: String?, _ name: String, path: String? = nil) -> RepoRecord {
        let key = RepoKey(provider: provider, owner: owner, project: project, name: name)
        let local = path.map { RepoRegistryEntry(key: key, path: $0, tracked: true) }
        return RepoRecord(key: key, catalog: nil, local: local)
    }

    func testGroupsByProjectThenOwnerInProviderOrder() {
        let records = [
            record(.gitHub, "zeta", nil, "tool"),
            record(.azureDevOps, "org", "Beta", "service"),
            record(.gitHub, "alpha", nil, "b-app"),
            record(.gitHub, "alpha", nil, "a-app"),
            record(.azureDevOps, "org", "Alpha", "site"),
        ]
        let groups = RepoRecordGroup.groups(records)
        XCTAssertEqual(groups.map(\.title), ["Azure DevOps · Alpha", "Azure DevOps · Beta", "GitHub · alpha", "GitHub · zeta"])
        XCTAssertEqual(groups[2].records.map(\.key.name), ["a-app", "b-app"])
    }

    func testFilterMatchesNameAndLocalPath() {
        let records = [
            record(.gitHub, "owner", nil, "widget"),
            record(.gitHub, "owner", nil, "gadget", path: "/tmp/checkouts/special"),
        ]
        XCTAssertEqual(RepoRecordGroup.groups(records, matching: "WIDG").flatMap(\.records).map(\.key.name), ["widget"])
        XCTAssertEqual(RepoRecordGroup.groups(records, matching: "special").flatMap(\.records).map(\.key.name), ["gadget"])
        XCTAssertTrue(RepoRecordGroup.groups(records, matching: "nothing").isEmpty)
    }
}

final class GitCommitStagedTests: XCTestCase {

    private var root: URL!
    private var copy: GitWorkingCopy!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-commit-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        copy = GitWorkingCopy(path: root.path)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "dev@example.com"], ["config", "user.name", "Dev"], ["config", "commit.gpgsign", "false"]] {
            let result = await copy.git(args)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        try copy.writeFile("a.txt", contents: Data("a\n".utf8))
        try copy.writeFile("b.txt", contents: Data("b\n".utf8))
        _ = try await copy.commit(message: "Initial", protectedBranches: [], allowProtected: true)
        _ = try await copy.switchBranch("feature/work")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCommitsOnlyTheIndexIncludingARename() async throws {
        let moved = await copy.git(["mv", "a.txt", "renamed.txt"])
        XCTAssertTrue(moved.succeeded, moved.stderr)
        try copy.writeFile("b.txt", contents: Data("changed\n".utf8))

        let commit = try await copy.commitStaged(message: "Rename a", protectedBranches: ["main"])
        XCTAssertEqual(commit.subject, "Rename a")

        let status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 0)
        XCTAssertEqual(status.changes.map(\.path), ["b.txt"], "the unstaged edit stays behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        let tracked = try await copy.listFiles()
        XCTAssertEqual(Set(tracked), ["renamed.txt", "b.txt"])
    }

    func testRefusesProtectedBranchAndEmptyIndex() async throws {
        do {
            try await copy.commitStaged(message: "Nothing", protectedBranches: [])
            XCTFail("an empty index should not commit")
        } catch {
            XCTAssertEqual(error as? RepoError, .nothingToCommit)
        }
        _ = try await copy.switchBranch("main")
        try copy.writeFile("a.txt", contents: Data("edit\n".utf8))
        try await copy.stage(["a.txt"])
        do {
            try await copy.commitStaged(message: "On main", protectedBranches: ["main"])
            XCTFail("main should be refused")
        } catch {
            XCTAssertEqual(error as? RepoError, .protectedBranch("main"))
        }
    }
}

final class RepoTextAndDiffTests: XCTestCase {

    func testTextFilesDecodeAndBinaryFilesDoNot() {
        XCTAssertEqual(RepoTextFile.decode(Data("héllo\n".utf8)), "héllo\n")
        XCTAssertEqual(RepoTextFile.decode(Data()), "")
        XCTAssertNil(RepoTextFile.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertNil(RepoTextFile.decode(Data([0xFF, 0xFE, 0xFD])), "invalid UTF-8 is not edited")
    }
}

final class CodeHighlighterTests: XCTestCase {

    private func spans(_ source: String, _ language: CodeLanguage) -> [(CodeTokenKind, String)] {
        CodeHighlighter.tokens(in: source, language: language).map { ($0.kind, (source as NSString).substring(with: $0.range)) }
    }

    func testDetectsByExtensionThenShebang() {
        XCTAssertEqual(CodeLanguage.detect(path: "Sources/App/main.swift", source: ""), .swift)
        XCTAssertEqual(CodeLanguage.detect(path: "infra/main.tf", source: ""), .hcl)
        XCTAssertEqual(CodeLanguage.detect(path: "build.ps1", source: ""), .powershell)
        XCTAssertEqual(CodeLanguage.detect(path: "scripts/run", source: "#!/usr/bin/env python3\nprint(1)"), .python)
        XCTAssertEqual(CodeLanguage.detect(path: "hooks/post-merge", source: "#!/bin/bash\n"), .shell)
        XCTAssertEqual(CodeLanguage.detect(path: "README.md", source: "# Title"), .plainText)
        XCTAssertEqual(CodeLanguage.detect(path: "data", source: "<?xml version=\"1.0\"?>"), .xml)
    }

    func testCommentsStringsKeywordsAndNumbers() {
        let source = "let x = \"a // not a comment\" // note \"quoted\"\nreturn 42"
        let found = spans(source, .swift)
        XCTAssertEqual(found.map(\.0), [.keyword, .string, .comment, .keyword, .number])
        XCTAssertEqual(found[1].1, "\"a // not a comment\"")
        XCTAssertEqual(found[2].1, "// note \"quoted\"")
    }

    func testKeywordsInsideStringsAndCommentsAreNotColoured() {
        let found = spans("echo \"if then\" # for done\nfi", .shell)
        XCTAssertEqual(found.map(\.0), [.string, .comment, .keyword])
        XCTAssertEqual(found.last?.1, "fi")
    }

    func testPlainTextAndOversizedSourcesAreNotColoured() {
        XCTAssertTrue(CodeHighlighter.tokens(in: "if 1", language: .plainText).isEmpty)
        let big = String(repeating: "x", count: CodeHighlighter.sizeLimit + 1)
        XCTAssertTrue(CodeHighlighter.tokens(in: big, language: .swift).isEmpty)
    }

    func testBlockCommentsSpanLines() {
        let found = spans("/* one\ntwo */ let", .swift)
        XCTAssertEqual(found.map(\.0), [.comment, .keyword])
    }
}

final class GitIndexLockTests: XCTestCase {

    func testRecognisesLockErrors() {
        XCTAssertTrue(GitIndexLock.matches(message: "fatal: Unable to create '/x/.git/index.lock': File exists."))
        XCTAssertTrue(GitIndexLock.matches(message: "Another git process seems to be running in this repository"))
        XCTAssertFalse(GitIndexLock.matches(message: "nothing to commit"))
    }

    func testLockPathForCheckoutAndLinkedWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(GitIndexLock.lockPath(checkout: main.path), main.path + "/.git/index.lock")

        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/linked\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitIndexLock.lockPath(checkout: linked.path), main.path + "/.git/worktrees/linked/index.lock")
    }

    func testRemovesAStaleLock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("index.lock").path
        FileManager.default.createFile(atPath: lock, contents: Data())
        try await GitIndexLock.removeStale(at: lock)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
        try await GitIndexLock.removeStale(at: lock)
    }
}

final class GitPaneSupportTests: XCTestCase {

    func testStatusEntriesSplitStagedAndUnstagedSides() {
        let snapshot = GitStatusSnapshot(changes: [
            RepoFileChange(path: "both.txt", kind: .changed, indexStatus: "M", worktreeStatus: "M"),
            RepoFileChange(path: "new.txt", kind: .untracked, indexStatus: "?", worktreeStatus: "?"),
            RepoFileChange(path: "moved.txt", originalPath: "old.txt", kind: .renamed, indexStatus: "R", worktreeStatus: "."),
            RepoFileChange(path: "debug.log", kind: .ignored, indexStatus: "!", worktreeStatus: "!"),
        ])
        let entries = GitStatusEntry.entries(from: snapshot)
        XCTAssertEqual(entries.map(\.id), ["staged:both.txt", "work:both.txt", "work:new.txt", "staged:moved.txt"])
        XCTAssertEqual(entries[3].kind, .renamed(from: "old.txt"))
        XCTAssertEqual(entries[2].kind, .untracked)
    }

    func testRefsLogAndBranchesParse() {
        let refs = RepoGitRef.parse("HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0")
        XCTAssertEqual(refs, [
            RepoGitRef(name: "main", kind: .localBranch, isHead: true),
            RepoGitRef(name: "origin/main", kind: .remoteBranch),
            RepoGitRef(name: "v1.0", kind: .tag),
        ])
        let log = "aaa\u{1f}Dev\u{1f}2026-01-02T03:04:05Z\u{1f}bbb ccc\u{1f}\u{1f}Merge\u{1e}\nbbb\u{1f}Dev\u{1f}2026-01-01T03:04:05Z\u{1f}\u{1f}\u{1f}Root\u{1e}"
        let commits = GitCommit.parseLog(log)
        XCTAssertEqual(commits.map(\.subject), ["Merge", "Root"])
        XCTAssertEqual(commits[0].parents, ["bbb", "ccc"])
        XCTAssertEqual(commits[1].parents, [])
        let branches = GitBranch.parse("main|origin/main|*\nfeature/x||\n")
        XCTAssertEqual(branches, [GitBranch(name: "main", isCurrent: true, upstreamName: "origin/main"), GitBranch(name: "feature/x", isCurrent: false)])
    }

    func testGraphPutsABranchOnItsOwnLane() {
        let date = Date()
        let commits = [
            GitCommit(sha: "m", subject: "Merge", author: "", date: date, parents: ["a", "b"]),
            GitCommit(sha: "b", subject: "Side", author: "", date: date, parents: ["a"]),
            GitCommit(sha: "a", subject: "Root", author: "", date: date, parents: []),
        ]
        let graph = CommitGraphBuilder.build(commits)
        XCTAssertEqual(graph.laneCount, 2)
        XCTAssertEqual(graph.rows.map(\.dotColumn), [0, 1, 0])
    }
}

final class GitPaneOperationsTests: XCTestCase {

    private var root: URL!
    private var copy: GitWorkingCopy!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        copy = GitWorkingCopy(path: root.path)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "dev@example.com"], ["config", "user.name", "Dev"], ["config", "commit.gpgsign", "false"]] {
            let result = await copy.git(args)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        let lines = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try copy.writeFile("file.txt", contents: Data(lines.utf8))
        _ = try await copy.commit(message: "Initial", protectedBranches: [], allowProtected: true)
        _ = try await copy.switchBranch("feature/pane")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStagesOneHunkOfTwo() async throws {
        var lines = (1...30).map { "line \($0)" }
        lines[1] = "changed near the top"
        lines[27] = "changed near the bottom"
        try copy.writeFile("file.txt", contents: Data((lines.joined(separator: "\n") + "\n").utf8))

        let patch = DiffParser.parse(try await copy.combinedDiff("file.txt"))
        let file = try XCTUnwrap(patch.files.first)
        XCTAssertEqual(file.hunks.count, 2)
        try await copy.applyPatch(file.patch(forHunk: file.hunks[0]), cached: true, reverse: false)

        let staged = try await copy.diff(staged: true)
        XCTAssertTrue(staged.contains("+changed near the top"))
        XCTAssertFalse(staged.contains("+changed near the bottom"))

        let entries = try await copy.statusEntries()
        XCTAssertEqual(entries.map(\.id), ["staged:file.txt", "work:file.txt"])
    }

    func testCommitWithBodyHistoryShowAndProtection() async throws {
        try copy.writeFile("file.txt", contents: Data("new\n".utf8))
        try await copy.stage(["file.txt"])
        let commit = try await copy.commit(subject: "Replace the file", body: "Why it changed.", amend: false, runHooks: true, protectedBranches: ["main"])
        XCTAssertEqual(commit.subject, "Replace the file")
        let message = await copy.git(["log", "-1", "--format=%B"]).stdout
        XCTAssertTrue(message.contains("Why it changed."))

        let history = try await copy.history()
        XCTAssertEqual(history.map(\.subject), ["Replace the file", "Initial"])
        XCTAssertTrue(history[0].refs.contains(RepoGitRef(name: "feature/pane", kind: .localBranch, isHead: true)))
        let shown = try await copy.show(history[0].sha)
        XCTAssertTrue(shown.contains("+new"))

        try await copy.createBranch("feature/other", at: history[1].sha)
        let branches = try await copy.branchList()
        XCTAssertEqual(Set(branches.map(\.name)), ["main", "feature/pane", "feature/other"])

        _ = try await copy.switchBranch("main")
        do {
            try await copy.commit(subject: "Amend main", body: nil, amend: true, runHooks: true, protectedBranches: ["main"])
            XCTFail("amending main should be refused")
        } catch {
            XCTAssertEqual(error as? RepoError, .protectedBranch("main"))
        }
        XCTAssertThrowsError(try copy.confinedPath("../x"))
        do {
            try await copy.checkoutCommit("--orphan")
            XCTFail("an option is not a commit")
        } catch {}
    }
}
