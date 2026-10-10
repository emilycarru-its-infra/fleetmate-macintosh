import XCTest
@testable import FleetMateCore

// Every URL and git output below is hand-written for these tests; the hosts,
// organizations and repositories are placeholders.

final class RepoRemoteURLTests: XCTestCase {

    private let azureHost = "azure-devops.example.com"

    func testAzureDevOpsHttpsForms() {
        let expected = RepoKey(provider: .azureDevOps, owner: "example-org", project: "Project", name: "Repo")
        let forms = [
            "https://\(azureHost)/example-org/Project/_git/Repo",
            "https://example-org@\(azureHost)/example-org/Project/_git/Repo",
            "https://\(azureHost)/example-org/Project/_git/Repo.git",
            "https://\(azureHost)/example-org/Project/_git/Repo/",
            "https://example-org.visualstudio.com/Project/_git/Repo",
            "https://example-org.visualstudio.com/DefaultCollection/Project/_git/Repo",
            "git@ssh.\(azureHost):v3/example-org/Project/Repo",
            "example-org@vs-ssh.visualstudio.com:v3/example-org/Project/Repo",
            "ssh://git@ssh.\(azureHost)/v3/example-org/Project/Repo",
        ]
        for form in forms {
            XCTAssertEqual(RepoRemoteURL.parse(form), expected, form)
        }
    }

    func testAzureDevOpsIdsIgnoreCase() {
        let a = RepoRemoteURL.id(for: "https://\(azureHost)/Example-Org/PROJECT/_git/repo")
        let b = RepoRemoteURL.id(for: "git@ssh.\(azureHost):v3/example-org/project/Repo")
        XCTAssertEqual(a, "azdo:example-org/project/repo")
        XCTAssertEqual(a, b)
    }

    func testAzureDevOpsShortFormUsesRepoAsProject() {
        let key = RepoRemoteURL.parse("https://\(azureHost)/example-org/_git/Tools")
        XCTAssertEqual(key, RepoKey(provider: .azureDevOps, owner: "example-org", project: "Tools", name: "Tools"))
    }

    func testAzureDevOpsPercentEncodedProject() {
        let key = RepoRemoteURL.parse("https://\(azureHost)/example-org/My%20Project/_git/Repo")
        XCTAssertEqual(key?.project, "My Project")
        XCTAssertEqual(key?.displayName, "My Project/Repo")
    }

    func testGitHubForms() {
        let expected = "github:example-org/example-repo"
        let forms = [
            "https://github.com/example-org/example-repo",
            "https://github.com/example-org/example-repo.git",
            "https://github.com/Example-Org/Example-Repo/",
            "git@github.com:example-org/example-repo.git",
            "ssh://git@github.com/example-org/example-repo.git",
            "https://user:secret@github.com/example-org/example-repo.git",
        ]
        for form in forms {
            XCTAssertEqual(RepoRemoteURL.id(for: form), expected, form)
        }
    }

    func testOtherHostsAndLocalPaths() {
        XCTAssertEqual(RepoRemoteURL.parse("https://git.example.com/group/sub/repo.git"),
                       RepoKey(provider: .other, owner: "git.example.com", name: "group/sub/repo"))
        XCTAssertEqual(RepoRemoteURL.parse("/srv/git/tool.git"),
                       RepoKey(provider: .other, owner: "/srv/git", name: "tool"))
        XCTAssertEqual(RepoRemoteURL.parse("file:///srv/git/tool.git")?.id, "other:/srv/git/tool")
        XCTAssertNil(RepoRemoteURL.parse(""))
        XCTAssertNil(RepoRemoteURL.parse("not a url"))
    }

    func testCatalogEntryAndCheckoutShareId() {
        let repo = GitRepository(
            id: "0", name: "Repo", url: nil, defaultBranch: "refs/heads/main",
            project: .init(id: nil, name: "Project"), webUrl: "https://\(azureHost)/example-org/Project/_git/Repo",
            remoteUrl: "https://example-org@\(azureHost)/example-org/Project/_git/Repo",
            sshUrl: "git@ssh.\(azureHost):v3/example-org/Project/Repo", isDisabled: false
        )
        let entry = RepoCatalogService.catalogRepo(from: repo, organization: "example-org", project: "Project")
        XCTAssertEqual(entry?.cloneUrl, "https://\(azureHost)/example-org/Project/_git/Repo", "user part stripped")
        XCTAssertEqual(entry?.defaultBranch, "main")
        XCTAssertEqual(entry?.id, RepoRemoteURL.id(for: "git@ssh.\(azureHost):v3/example-org/project/repo"))
    }

    func testDisabledAzureRepositoryIsSkipped() {
        let repo = GitRepository(id: "0", name: "Old", url: nil, defaultBranch: nil, project: nil, webUrl: nil,
                                 remoteUrl: "https://\(azureHost)/example-org/Project/_git/Old", sshUrl: nil, isDisabled: true)
        XCTAssertNil(RepoCatalogService.catalogRepo(from: repo, organization: "example-org", project: "Project"))
    }

    func testGitHubNextLink() {
        let header = "<https://api.github.com/user/repos?page=2>; rel=\"next\", <https://api.github.com/user/repos?page=5>; rel=\"last\""
        XCTAssertEqual(RepoCatalogService.nextLink(header)?.absoluteString, "https://api.github.com/user/repos?page=2")
        XCTAssertNil(RepoCatalogService.nextLink("<https://api.github.com/user/repos?page=1>; rel=\"prev\""))
        XCTAssertNil(RepoCatalogService.nextLink(nil))
    }

    func testDefaultClonePath() {
        let azure = RepoKey(provider: .azureDevOps, owner: "example-org", project: "Project", name: "Repo")
        let github = RepoKey(provider: .gitHub, owner: "example-org", name: "example-repo")
        XCTAssertEqual(RepoManager.defaultClonePath(for: azure, root: "/work"), "/work/AzDevOps/Project/Repo")
        XCTAssertEqual(RepoManager.defaultClonePath(for: github, root: "/work"), "/work/GitHub/example-org/example-repo")
    }
}

final class RepoResolverTests: XCTestCase {

    private func record(_ key: RepoKey, path: String? = nil, tracked: Bool = false) -> RepoRecord {
        RepoRecord(key: key, catalog: nil, local: path.map { RepoRegistryEntry(key: key, path: $0, tracked: tracked) })
    }

    private lazy var records: [RepoRecord] = [
        record(RepoKey(provider: .azureDevOps, owner: "example-org", project: "Devices", name: "Tools"), path: "/work/AzDevOps/Devices/Tools"),
        record(RepoKey(provider: .azureDevOps, owner: "example-org", project: "Systems", name: "Portal")),
        record(RepoKey(provider: .gitHub, owner: "example-org", name: "tools")),
        record(RepoKey(provider: .gitHub, owner: "someone", name: "dotfiles"), path: "/work/GitHub/someone/dotfiles"),
    ]

    func testResolvesByUniqueName() throws {
        XCTAssertEqual(try RepoResolver.resolve("portal", in: records).key.name, "Portal")
        XCTAssertEqual(try RepoResolver.resolve("DOTFILES", in: records).key.owner, "someone")
    }

    func testResolvesByScopeAndName() throws {
        XCTAssertEqual(try RepoResolver.resolve("Devices/Tools", in: records).key.provider, .azureDevOps)
        XCTAssertEqual(try RepoResolver.resolve("example-org/tools", in: records).key.provider, .gitHub)
        XCTAssertEqual(try RepoResolver.resolve("example-org/Devices/Tools", in: records).key.project, "Devices")
    }

    func testResolvesById() throws {
        XCTAssertEqual(try RepoResolver.resolve("github:example-org/tools", in: records).key.provider, .gitHub)
        XCTAssertEqual(try RepoResolver.resolve("AZDO:example-org/devices/tools", in: records).key.provider, .azureDevOps)
    }

    func testResolvesByPath() throws {
        XCTAssertEqual(try RepoResolver.resolve("/work/GitHub/someone/dotfiles/", in: records).key.name, "dotfiles")
    }

    func testAmbiguousNameListsCandidates() {
        XCTAssertThrowsError(try RepoResolver.resolve("tools", in: records)) { error in
            guard case RepoError.ambiguous(let arg, let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(arg, "tools")
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates.contains { $0.contains("Devices/Tools") })
            XCTAssertTrue(candidates.contains { $0.contains("example-org/tools") })
        }
    }

    func testUnknownNameIsNotFound() {
        XCTAssertThrowsError(try RepoResolver.resolve("missing", in: records)) { error in
            XCTAssertEqual(error as? RepoError, .notFound("missing"))
        }
    }

    func testMergeJoinsCatalogAndRegistry() {
        let key = RepoKey(provider: .gitHub, owner: "example-org", name: "tools")
        let catalog = [CatalogRepo(key: key, cloneUrl: "https://github.com/example-org/tools.git", defaultBranch: "main")]
        let local = RepoKey(provider: .gitHub, owner: "Example-Org", name: "Tools")
        let registry = [RepoRegistryEntry(key: local, path: "/work/tools", tracked: true)]
        let merged = RepoRecord.merge(catalog: catalog, registry: registry)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isTracked)
        XCTAssertEqual(merged[0].defaultBranch, "main")
        XCTAssertEqual(merged[0].key.owner, "example-org", "the catalog's spelling wins")
    }
}

final class RepoRegistryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("repo-registry-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: RepoRegistryStore {
        RepoRegistryStore(registryPath: directory.appendingPathComponent("repos.json").path,
                          catalogPath: directory.appendingPathComponent("repos-catalog.json").path)
    }

    func testMissingFileLoadsDefaults() throws {
        let document = try store.load()
        XCTAssertEqual(document.settings, .default)
        XCTAssertTrue(document.repos.isEmpty)
    }

    func testRoundTrip() throws {
        let key = RepoKey(provider: .azureDevOps, owner: "example-org", project: "Project", name: "Repo")
        let entry = RepoRegistryEntry(key: key, path: "/work/AzDevOps/Project/Repo", tracked: true,
                                      remoteUrl: "https://azure-devops.example.com/example-org/Project/_git/Repo",
                                      defaultBranch: "main", addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.update { doc in
            doc.repos[key.id] = entry
            doc.settings.scanRoots = ["~/Code"]
            doc.settings.gitHubOwners = ["example-org"]
        }
        let loaded = try store.load()
        XCTAssertEqual(loaded.repos[key.id], entry)
        XCTAssertEqual(loaded.settings.scanRoots, ["~/Code"])
        XCTAssertEqual(loaded.settings.gitHubOwners, ["example-org"])
        XCTAssertEqual(loaded.trackedEntries.map(\.key), [key])
    }

    func testPartialSettingsFallBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"settings": {"cloneRoot": "~/Code"}}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("repos.json"))
        let loaded = try store.load()
        XCTAssertEqual(loaded.settings.cloneRoot, "~/Code")
        XCTAssertEqual(loaded.settings.scanDepth, RepoSettings.default.scanDepth)
        XCTAssertEqual(loaded.version, 1)
    }

    func testCatalogCacheRoundTrip() throws {
        let catalog = RepoCatalog(repos: [
            CatalogRepo(key: RepoKey(provider: .gitHub, owner: "example-org", name: "example-repo"),
                        cloneUrl: "https://github.com/example-org/example-repo.git", defaultBranch: "refs/heads/main", isArchived: true)
        ], errors: ["GitHub example-owner: HTTP 404"], fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.saveCatalog(catalog)
        let loaded = try XCTUnwrap(store.loadCatalog())
        XCTAssertEqual(loaded.repos, catalog.repos)
        XCTAssertEqual(loaded.repos[0].defaultBranch, "main")
        XCTAssertEqual(loaded.errors, catalog.errors)
    }
}

final class GitOutputParserTests: XCTestCase {

    private let oid = String(repeating: "a", count: 40)
    private let oid2 = String(repeating: "b", count: 40)

    func testStatusHeaderAndChanges() {
        let records = [
            "# branch.oid \(oid)",
            "# branch.head feature/example",
            "# branch.upstream origin/feature/example",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 \(oid) \(oid2) Sources/Staged.swift",
            "1 .M N... 100644 100644 100644 \(oid) \(oid) Sources/Modified file.swift",
            "1 MM N... 100644 100644 100644 \(oid) \(oid2) both.txt",
            "1 A. N... 000000 100644 100644 \(String(repeating: "0", count: 40)) \(oid2) added.txt",
            "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 new/name.txt",
            "old/name.txt",
            "u UU N... 100644 100644 100644 100644 \(oid) \(oid2) \(oid) conflict.txt",
            "? notes/todo.md",
            "! build/output.log",
        ]
        let snapshot = GitOutputParser.status(records.joined(separator: "\0") + "\0")

        XCTAssertEqual(snapshot.headOid, oid)
        XCTAssertEqual(snapshot.branch, "feature/example")
        XCTAssertEqual(snapshot.upstream, "origin/feature/example")
        XCTAssertEqual(snapshot.ahead, 2)
        XCTAssertEqual(snapshot.behind, 1)
        XCTAssertEqual(snapshot.changes.count, 8)

        XCTAssertEqual(snapshot.changes[1].path, "Sources/Modified file.swift", "spaces in paths survive")
        let rename = snapshot.changes[4]
        XCTAssertEqual(rename.kind, .renamed)
        XCTAssertEqual(rename.path, "new/name.txt")
        XCTAssertEqual(rename.originalPath, "old/name.txt")
        XCTAssertEqual(snapshot.changes[5].kind, .unmerged)
        XCTAssertEqual(snapshot.changes[6].kind, .untracked)
        XCTAssertEqual(snapshot.changes[7].kind, .ignored)

        // Staged: M., MM, A., R., UU. Unstaged: .M, MM, UU.
        XCTAssertEqual(snapshot.stagedCount, 5)
        XCTAssertEqual(snapshot.unstagedCount, 3)
        XCTAssertEqual(snapshot.untrackedCount, 1)
        XCTAssertEqual(snapshot.conflictedCount, 1)
        XCTAssertFalse(snapshot.isClean)
    }

    func testStatusDetachedInitialAndClean() {
        let output = ["# branch.oid (initial)", "# branch.head (detached)", "! ignored.log"].joined(separator: "\0") + "\0"
        let snapshot = GitOutputParser.status(output)
        XCTAssertNil(snapshot.headOid)
        XCTAssertNil(snapshot.branch)
        XCTAssertNil(snapshot.upstream)
        XCTAssertEqual(snapshot.ahead, 0)
        XCTAssertTrue(snapshot.isClean, "ignored files do not make a checkout dirty")
    }

    func testFileChangeJSONRoundTrip() throws {
        let change = RepoFileChange(path: "a.txt", kind: .changed, indexStatus: "M", worktreeStatus: ".")
        let data = try JSONEncoder().encode(change)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["staged"] as? Bool, true)
        XCTAssertEqual(object?["indexStatus"] as? String, "M")
        XCTAssertEqual(try JSONDecoder().decode(RepoFileChange.self, from: data), change)
    }

    func testWorktrees() {
        let output = """
        worktree /work/example-repo
        HEAD \(oid)
        branch refs/heads/main

        worktree /work/example-repo/.worktrees/feature
        HEAD \(oid2)
        branch refs/heads/feature/example
        locked

        worktree /work/example-repo/.worktrees/review
        HEAD \(oid)
        detached
        prunable gitdir file points to non-existent location

        """
        let worktrees = GitOutputParser.worktrees(output)
        XCTAssertEqual(worktrees.count, 3)
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[1].branch, "feature/example")
        XCTAssertTrue(worktrees[1].isLocked)
        XCTAssertNil(worktrees[2].branch)
        XCTAssertTrue(worktrees[2].isDetached)
        XCTAssertTrue(worktrees[2].isPrunable)
    }

    func testLog() {
        let output = [
            [oid, "aaaaaaa", "Example Author", "author@example.com", "2026-01-02T03:04:05-08:00", "Add the first thing"],
            [oid2, "bbbbbbb", "Other Author", "other@example.com", "2026-01-01T00:00:00Z", "Subject with \u{1f}? no"],
        ].map { $0.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}\n") + "\u{1e}\n"
        let commits = GitOutputParser.log(output)
        XCTAssertEqual(commits.count, 1, "a malformed record is dropped, not misparsed")
        XCTAssertEqual(commits[0].shortSha, "aaaaaaa")
        XCTAssertEqual(commits[0].subject, "Add the first thing")
        XCTAssertNotNil(commits[0].date)
    }

    func testGrep() {
        let output = "Sources/App.swift\u{0}12\u{0}5\u{0}let needle = 1\nREADME.md\u{0}3\u{0}1\u{0}needle: with: colons\n"
        let matches = GitOutputParser.grep(output)
        XCTAssertEqual(matches, [
            RepoGrepMatch(path: "Sources/App.swift", line: 12, column: 5, text: "let needle = 1"),
            RepoGrepMatch(path: "README.md", line: 3, column: 1, text: "needle: with: colons"),
        ])
    }

    func testPaths() {
        XCTAssertEqual(GitOutputParser.paths("a.txt\u{0}dir/b c.txt\u{0}"), ["a.txt", "dir/b c.txt"])
    }
}

/// Exercises `GitWorkingCopy` against a repository created in a temporary
/// folder, so staging, discarding and the branch guard run real git.
final class GitWorkingCopyTests: XCTestCase {

    private var root: URL!
    private var copy: GitWorkingCopy!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-working-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        copy = GitWorkingCopy(path: root.path)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "dev@example.com"], ["config", "user.name", "Dev"], ["config", "commit.gpgsign", "false"]] {
            let result = await copy.git(args)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
        try write("tracked.txt", "one\n")
        try write(".gitignore", "*.log\n")
        _ = try await copy.commit(message: "Initial", protectedBranches: [], allowProtected: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String) throws {
        try copy.writeFile(name, contents: Data(text.utf8))
    }

    func testProtectedBranchIsRefused() async throws {
        try write("tracked.txt", "two\n")
        do {
            _ = try await copy.commit(message: "Change", protectedBranches: ["main"])
            XCTFail("commit on main should be refused")
        } catch {
            XCTAssertEqual(error as? RepoError, .protectedBranch("main"))
        }
        _ = try await copy.switchBranch("feature/example")
        let commit = try await copy.commit(message: "Change", protectedBranches: ["main"])
        XCTAssertEqual(commit.subject, "Change")
        let branch = await copy.currentBranch()
        XCTAssertEqual(branch, "feature/example")
    }

    func testStageUnstageDiscardAndDiff() async throws {
        try write("tracked.txt", "two\n")
        try write("new.txt", "fresh\n")
        try write("debug.log", "ignored\n")

        var status = try await copy.statusSnapshot()
        XCTAssertEqual(status.unstagedCount, 1)
        XCTAssertEqual(status.untrackedCount, 1, "ignored files are not untracked")

        let files = try await copy.listFiles()
        XCTAssertEqual(Set(files), [".gitignore", "tracked.txt", "new.txt"])

        try await copy.stage(["tracked.txt"])
        status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 1)
        let stagedDiff = try await copy.fileDiff("tracked.txt", staged: true)
        XCTAssertTrue(stagedDiff.contains("+two"))
        let untrackedDiff = try await copy.fileDiff("new.txt")
        XCTAssertTrue(untrackedDiff.contains("+fresh"))

        try await copy.unstage(["tracked.txt"])
        status = try await copy.statusSnapshot()
        XCTAssertEqual(status.stagedCount, 0)

        try await copy.discard(["tracked.txt", "new.txt"])
        status = try await copy.statusSnapshot()
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(String(decoding: try copy.readFile("tracked.txt"), as: UTF8.self), "one\n")
    }

    func testGrepAndLog() async throws {
        let matches = try await copy.grep("one")
        XCTAssertEqual(matches.first?.path, "tracked.txt")
        let none = try await copy.grep("absent-text")
        XCTAssertEqual(none, [])
        let log = try await copy.log(limit: 5)
        XCTAssertEqual(log.map(\.subject), ["Initial"])
    }

    func testPathsOutsideTheCheckoutAreRefused() {
        XCTAssertThrowsError(try copy.confinedPath("../outside.txt"))
        XCTAssertThrowsError(try copy.confinedPath("/etc/hosts"))
        XCTAssertThrowsError(try copy.confinedPath(".git/config"))
        XCTAssertEqual(try copy.confinedPath("dir/../tracked.txt"), "tracked.txt")
        XCTAssertThrowsError(try copy.confinedPath(".GIT/hooks/pre-commit"))
        XCTAssertThrowsError(try copy.confinedPath("sub/.Git/config"))
    }

    func testPathspecMagicInAFileNameIsLiteral() async throws {
        try copy.writeFile("tracked.txt", contents: Data("changed\n".utf8))
        _ = try? await copy.discard([":(top)"])
        XCTAssertEqual(String(decoding: try copy.readFile("tracked.txt"), as: UTF8.self), "changed\n")
    }

    func testNewFilesUnderASymlinkOutOfTheCheckoutAreRefused() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(atPath: (copy.path as NSString).appendingPathComponent("escape"),
                                                   withDestinationPath: outside.path)
        XCTAssertThrowsError(try copy.confinedPath("escape/new-file.txt"))
        XCTAssertThrowsError(try copy.writeFile("escape/deeper/new-file.txt", contents: Data("x".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("deeper").path))
        XCTAssertEqual(try copy.confinedPath("brand/new/file.txt"), "brand/new/file.txt")
    }
}
