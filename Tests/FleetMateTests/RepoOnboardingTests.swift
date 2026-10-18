import XCTest
@testable import FleetMateCore

// Folder names, owners and remotes below are placeholders made up for these
// tests.

final class RepoDiscoveryScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A folder with a `.git` directory: all discovery looks for.
    @discardableResult
    private func checkout(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return url.path
    }

    private func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private func names(_ paths: [String]) -> [String] {
        paths.map { String($0.dropFirst(root.path.count + 1)) }.sorted()
    }

    func testFindsNestedClonesAndStopsAtACheckout() throws {
        try checkout("GitHub/owner-a/one")
        try checkout("AzDevOps/Project/two")
        try checkout("AzDevOps/Project/two/nested/inner")
        let found = RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 4, skip: [])
        XCTAssertEqual(names(found), ["AzDevOps/Project/two", "GitHub/owner-a/one"])
    }

    func testDepthLimit() throws {
        try checkout("a/b/c/d/deep")
        try checkout("a/shallow")
        XCTAssertEqual(names(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 2, skip: [])), ["a/shallow"])
        XCTAssertEqual(names(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 5, skip: [])), ["a/b/c/d/deep", "a/shallow"])
    }

    func testBuiltInSkipRulesApplyWhateverTheSettingsSay() throws {
        for junk in ["node_modules/pkg", "bin/Debug/thing", "obj/x", ".build/checkouts/dep", "work/.worktrees/feature", "DerivedData/y", ".hidden/z"] {
            try checkout(junk)
        }
        try checkout("work/real")
        XCTAssertEqual(names(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 5, skip: [])), ["work/real"])
    }

    func testConfiguredSkipIsHonoured() throws {
        try checkout("archive/old")
        try checkout("live/new")
        XCTAssertEqual(names(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 4, skip: ["Archive"])), ["live/new"])
    }

    func testACheckoutWithASkippedNameIsStillFound() throws {
        try checkout("owner/build")
        try checkout("owner/build-tools")
        XCTAssertEqual(names(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 4, skip: [])), ["owner/build", "owner/build-tools"])
    }

    func testLinkedWorktreeIsNotReported() throws {
        try checkout("main-clone")
        try folder("linked")
        try "gitdir: /somewhere/main-clone/.git/worktrees/linked\n"
            .write(to: root.appendingPathComponent("linked/.git"), atomically: true, encoding: .utf8)
        try folder("submodule")
        try "gitdir: ../main-clone/.git/modules/submodule\n"
            .write(to: root.appendingPathComponent("submodule/.git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(names(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 3, skip: [])), ["main-clone", "submodule"])
    }

    func testMissingRootsAreIgnoredAndTrailingSlashesTolerated() throws {
        try checkout("one")
        let found = RepoDiscovery.findCheckouts(roots: [root.path + "/", root.appendingPathComponent("absent").path], maxDepth: 2, skip: [])
        XCTAssertEqual(found.count, 1)
    }

    func testCodeWorkspaceFoldersInsideTheRootAreProposed() throws {
        try checkout("deep/a/b/c/d/far")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("mono/.git"), withIntermediateDirectories: true)
        try folder("mono/packages/app")
        try checkout("walked")
        let workspace = """
        {
          // Folders open together
          "folders": [
            { "path": "deep/a/b/c/d/far" },
            /* a subfolder of a repository */
            { "path": "\(root.path)/mono/packages/app" },
            { "path": "walked" },
            { "path": "does-not-exist" },
          ],
          "settings": { "url": "https://example.com/a//b" },
        }
        """
        try workspace.write(to: root.appendingPathComponent("team.code-workspace"), atomically: true, encoding: .utf8)

        let result = RepoDiscovery.scan(roots: [root.path], maxDepth: 2, skip: [])
        XCTAssertEqual(result.workspaceFiles.count, 1)
        XCTAssertEqual(names(result.checkouts), ["mono", "walked"])
        XCTAssertEqual(result.workspaceCheckouts.count, 1, "only the clone the walk could not reach is a proposal")
        XCTAssertTrue(result.workspaceCheckouts[0].hasSuffix("/deep/a/b/c/d/far"))
        XCTAssertEqual(RepoDiscovery.findCheckouts(roots: [root.path], maxDepth: 2, skip: []).count, 2, "proposals are never part of a plain scan")
    }

    func testWorkspaceFoldersOutsideTheRootsAreRejected() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("repo-scan-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("secret/.git"), withIntermediateDirectories: true)
        // A sibling whose name starts with the root's name is still outside.
        let sibling = URL(fileURLWithPath: root.path + "-sibling")
        defer { try? FileManager.default.removeItem(at: sibling) }
        try FileManager.default.createDirectory(at: sibling.appendingPathComponent(".git"), withIntermediateDirectories: true)
        // A symlink inside the root that leads out of it.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside.appendingPathComponent("secret"))
        let workspace = """
        {"folders": [
          {"path": "\(outside.path)/secret"},
          {"path": "../\(sibling.lastPathComponent)"},
          {"path": "escape"},
          {"path": "~/Developer"},
          {"path": "//fileserver/share/repo"},
          {"path": "\\\\fileserver\\share\\repo"},
          {"path": "vscode-remote://ssh-remote+box/home/repo"},
          {"path": "$HOME/repo"}
        ]}
        """
        try workspace.write(to: root.appendingPathComponent("team.code-workspace"), atomically: true, encoding: .utf8)
        let result = RepoDiscovery.scan(roots: [root.path], maxDepth: 3, skip: [])
        XCTAssertEqual(result.workspaceFiles.count, 1)
        XCTAssertEqual(result.checkouts, [])
        XCTAssertEqual(result.workspaceCheckouts, [])
    }

    func testWorkspaceFilesInsideACheckoutOrDeeperAreNotRead() throws {
        try checkout("clone")
        try checkout("target-repo")
        try #"{"folders": [{"path": "../target-repo"}]}"#
            .write(to: root.appendingPathComponent("clone/planted.code-workspace"), atomically: true, encoding: .utf8)
        try folder("group")
        try #"{"folders": [{"path": "../target-repo"}]}"#
            .write(to: root.appendingPathComponent("group/nested.code-workspace"), atomically: true, encoding: .utf8)
        let result = RepoDiscovery.scan(roots: [root.path], maxDepth: 0, skip: [])
        XCTAssertEqual(result.workspaceFiles, [])
        XCTAssertEqual(result.workspaceCheckouts, [])
    }

    func testPlainLocalPathRules() {
        for good in ["repo", "../repo", "/Users/someone/Code/repo", "a/b:c"] {
            XCTAssertTrue(RepoDiscovery.isPlainLocalPath(good), good)
        }
        for bad in ["", "~/repo", "//host/share", "\\\\host\\share", "\\\\?\\C:\\x", "\\\\.\\pipe\\x", "C:/repo", "file:///repo", "%USERPROFILE%/repo", "$HOME/repo"] {
            XCTAssertFalse(RepoDiscovery.isPlainLocalPath(bad), bad)
        }
    }

    func testOriginIsReadFromConfigWithoutGit() throws {
        let path = try checkout("owner/one")
        let config = """
        [core]
        \trepositoryformatversion = 0
        \tfsmonitor = /tmp/should-never-run
        [remote "upstream"]
        \turl = https://github.com/someone-else/one.git
        [remote "origin"]
        \turl = git@github.com:owner-a/one.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        try config.write(toFile: path + "/.git/config", atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoDiscovery.readOrigin(checkout: path), "git@github.com:owner-a/one.git")

        // A submodule's .git file points at its real git folder.
        try folder("modules/sub")
        try "[remote \"origin\"]\n  url = \"https://github.com/owner-a/sub.git\"\n"
            .write(to: root.appendingPathComponent("modules/sub/config"), atomically: true, encoding: .utf8)
        try folder("sub")
        try "gitdir: ../modules/sub\n".write(to: root.appendingPathComponent("sub/.git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoDiscovery.readOrigin(checkout: root.appendingPathComponent("sub").path), "https://github.com/owner-a/sub.git")
        XCTAssertNil(RepoDiscovery.readOrigin(checkout: root.path))
    }

    func testInspectionGitCallsDisableFsmonitorPagerAndHooks() {
        XCTAssertEqual(GitWorkingCopy.safetyConfig(for: ["status"]),
                       ["-c", "core.fsmonitor=false", "-c", "core.pager=cat", "-c", "core.hooksPath=/dev/null"])
        XCTAssertEqual(GitWorkingCopy.safetyConfig(for: ["commit", "-m", "x"]),
                       ["-c", "core.fsmonitor=false", "-c", "core.pager=cat"], "commit keeps the team's hooks")
        XCTAssertEqual(GitWorkingCopy.withSafeDiffOptions(["diff", "HEAD"]), ["diff", "--no-ext-diff", "--no-textconv", "HEAD"])
        XCTAssertEqual(GitWorkingCopy.withSafeDiffOptions(["log", "-n", "1"]), ["log", "--no-ext-diff", "--no-textconv", "-n", "1"])
        XCTAssertEqual(GitWorkingCopy.withSafeDiffOptions(["grep", "x"]), ["grep", "--no-textconv", "x"])
        XCTAssertEqual(GitWorkingCopy.withSafeDiffOptions(["status"]), ["status"])
    }

    func testCommandConfigKeysOutsideTheAllowlistAreFlagged() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        \tfsmonitor = true
        \tbare = false
        [core]
        \tsshCommand = ssh -i key
        \tpager = less
        \teditor = vim
        \thooksPath = .husky
        \tworktree = ../elsewhere
        [remote "origin"]
        \turl = https://github.com/owner-a/one.git
        \tuploadpack = sh -c evil
        [credential "https://example.com"]
        \thelper = store
        [diff "img"]
        \ttextconv = exiftool
        [filter "lfs"]
        \tprocess = git-lfs filter-process
        [protocol "ext"]
        \tallow = always
        [include]
        \tpath = ../shared.gitconfig
        [includeIf "gitdir:~/work/"]
        \tpath = work.gitconfig
        [extensions]
        \tworktreeConfig = true
        [submodule "lib"]
        \turl = https://github.com/owner-a/lib.git
        \tupdate = !sh -c evil
        [submodule "docs"]
        \tupdate = rebase
        [somethingnew]
        \tvalue = 1
        [branch "main"]
        \tremote = origin
        ; [core] pager = commented out
        """
        XCTAssertEqual(RepoDiscovery.commandConfigKeys(inConfig: config), [
            "core.fsmonitor", "core.sshcommand", "core.pager", "core.editor", "core.hookspath", "core.worktree",
            "remote.origin.uploadpack", "credential.https://example.com.helper", "diff.img.textconv",
            "filter.lfs.process", "protocol.ext.allow", "include.path", "includeif.gitdir:~/work/.path",
            "extensions.worktreeconfig", "submodule.lib.update", "somethingnew.value",
        ])
    }

    func testPlainConfigIsNotFlagged() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        \tbare = false
        \tlogallrefupdates = true
        \tignorecase = true
        \tprecomposeunicode = true
        \tfsmonitor = false
        [remote "origin"]
        \turl = https://github.com/owner-a/one.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        \tmerge = refs/heads/main
        \tvscode-merge-base = origin/main
        [submodule]
        \tactive = .
        [submodule "lib"]
        \turl = https://github.com/owner-a/lib.git
        \tactive = true
        [user]
        \tname = Someone
        [pull]
        \trebase = true
        [lfs]
        \trepositoryformatversion = 0
        [extensions]
        \tobjectformat = sha256
        [init]
        \tdefaultBranch = main
        """
        XCTAssertEqual(RepoDiscovery.commandConfigKeys(inConfig: config), [])
    }

    private func gitDir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative).appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "[core]\n\tbare = false\n".write(to: url.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return url
    }

    func testPlainCloneHasNoReasons() throws {
        let dir = try gitDir("plain")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        let sample = dir.appendingPathComponent("hooks/pre-commit.sample")
        try "#!/bin/sh\n".write(to: sample, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sample.path)
        let notExecutable = dir.appendingPathComponent("hooks/post-merge")
        try "#!/bin/sh\n".write(to: notExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)
        XCTAssertEqual(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent("plain").path), [])
    }

    func testExecutableHooksAreFlagged() throws {
        let dir = try gitDir("hooked")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        let hook = dir.appendingPathComponent("hooks/post-checkout")
        try "#!/bin/sh\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        XCTAssertEqual(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent("hooked").path), ["hooks/post-checkout"])
    }

    func testUnreadableConfigFailsClosed() throws {
        let dir = try gitDir("garbled")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: dir.appendingPathComponent("config"))
        XCTAssertEqual(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent("garbled").path), ["config (unreadable)"])
        let worktreeConfig = try gitDir("garbled-worktree")
        try Data([0xC3, 0x28]).write(to: worktreeConfig.appendingPathComponent("config.worktree"))
        XCTAssertEqual(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent("garbled-worktree").path), ["config.worktree (unreadable)"])
    }

    func testCommondirIsFlaggedAndItsConfigRead() throws {
        let shared = try gitDir("shared")
        try "[core]\n\tpager = less\n".write(to: shared.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let linked = try gitDir("linked")
        try "../../shared/.git\n".write(to: linked.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent("linked").path), ["commondir", "core.pager"])
    }

    func testWorktreeConfigIncludeAndCoreWorktreeAreFlagged() throws {
        for (name, text) in [("wtc", "[extensions]\n\tworktreeConfig = true\n"),
                             ("inc", "[include]\n\tpath = other\n"),
                             ("incif", "[includeIf \"onbranch:main\"]\n\tpath = other\n"),
                             ("cwt", "[core]\n\tworktree = /elsewhere\n")] {
            let dir = try gitDir(name)
            try text.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
            XCTAssertFalse(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent(name).path).isEmpty, name)
        }
        let dir = try gitDir("wtc2")
        try "[extensions]\n\tworktreeConfig = true\n".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "[core]\n\tsshCommand = x\n".write(to: dir.appendingPathComponent("config.worktree"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoDiscovery.commandConfig(checkout: root.appendingPathComponent("wtc2").path), ["extensions.worktreeconfig", "core.sshcommand"])
    }

    func testDiscoveryFlagsAClonesCommandConfig() async throws {
        let path = try checkout("owner/risky")
        try "[remote \"origin\"]\n\turl = https://github.com/owner-a/risky.git\n[core]\n\tfsmonitor = ./x.sh\n"
            .write(toFile: path + "/.git/config", atomically: true, encoding: .utf8)
        var settings = RepoSettings.default
        settings.scanRoots = [root.path]
        let found = await RepoDiscovery.discover(settings: settings)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].commandConfig, ["core.fsmonitor"])
        XCTAssertTrue(found[0].runsCommands)
    }

    func testFsmonitorInAClonesConfigNeverRuns() async throws {
        let path = root.appendingPathComponent("hostile").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let copy = GitWorkingCopy(path: path)
        _ = await copy.git(["init", "-q"])
        let marker = root.appendingPathComponent("ran").path
        let script = root.appendingPathComponent("monitor.sh").path
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        _ = await copy.git(["config", "core.fsmonitor", script])
        _ = try? await copy.statusSnapshot()
        _ = await CloneRemovalCheck.inspect(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testJSONCommentStripping() {
        let text = #"{"a": "x // not a comment", /* c */ "b": [1, 2,], // tail"# + "\n}"
        let data = Data(RepoDiscovery.strippingJSONComments(text).utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["a"] as? String, "x // not a comment")
        XCTAssertEqual((object?["b"] as? [Int])?.count, 2)
    }

    func testAbbreviateWritesHomeAsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(RepoSettings.abbreviate(home + "/Code/"), "~/Code")
        XCTAssertEqual(RepoSettings.abbreviate("~/DevOps"), "~/DevOps")
        XCTAssertEqual(RepoSettings.abbreviate("/opt/src"), "/opt/src")
    }

    func testCommonLocationsIncludeTheUsualPlaces() {
        for place in ["~/Developer", "~/DevOps", "~/Projects", "~/src", "~/code", "~/git", "~/Documents/GitHub"] {
            XCTAssertTrue(RepoDiscovery.commonLocations.contains(place), place)
        }
    }
}

final class RepoRegistrySettingsCompatibilityTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("repo-registry-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: RepoRegistryStore {
        RepoRegistryStore(registryPath: directory.appendingPathComponent("repos.json").path,
                          catalogPath: directory.appendingPathComponent("repos-catalog.json").path)
    }

    func testOlderFileLoadsWithNewDefaults() throws {
        let json = """
        {"version": 1, "settings": {"scanRoots": ["~/Code"]},
         "repos": {"github:owner-a/one": {"key": {"provider": "github", "owner": "owner-a", "name": "one"},
                   "path": "/tmp/one", "tracked": true, "addedAt": "2026-01-01T00:00:00Z"}}}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("repos.json"))
        let loaded = try store.load()
        XCTAssertTrue(loaded.settings.autoTrackNewClones)
        XCTAssertFalse(loaded.settings.rootsChosen)
        XCTAssertFalse(loaded.settings.looksForNewClones, "a file written before roots were chosen never offers clones")
        XCTAssertEqual(loaded.repos["github:owner-a/one"]?.hidden, false)
    }

    func testHiddenIsWrittenOnlyWhenSet() throws {
        let key = RepoKey(provider: .gitHub, owner: "owner-a", name: "one")
        try store.update { $0.repos[key.id] = RepoRegistryEntry(key: key, path: "/tmp/one", tracked: true) }
        var text = try String(contentsOf: directory.appendingPathComponent("repos.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("hidden"))
        try store.update { $0.repos[key.id]?.hidden = true }
        text = try String(contentsOf: directory.appendingPathComponent("repos.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"hidden\" : true"))
        XCTAssertEqual(try store.load().repos[key.id]?.hidden, true)
    }

    func testRegisterTracksOnlyNewClonesWithTrackNew() throws {
        let manager = RepoManager(store: store)
        let known = RepoKey(provider: .gitHub, owner: "owner-a", name: "known")
        let fresh = RepoKey(provider: .azureDevOps, owner: "org", project: "Project", name: "fresh")
        try store.update { $0.repos[known.id] = RepoRegistryEntry(key: known, path: "/tmp/known", tracked: false, hidden: true) }

        let results = try manager.register([
            DiscoveredCheckout(path: "/tmp/known", remoteUrl: "https://github.com/owner-a/known.git", key: known),
            DiscoveredCheckout(path: "/tmp/fresh", remoteUrl: nil, key: fresh),
            DiscoveredCheckout(path: "/tmp/no-remote", remoteUrl: nil, key: nil),
        ], trackNew: true)

        XCTAssertEqual(results.map(\.action), [.alreadyLinked, .linked, .noRemote])
        let doc = try store.load()
        XCTAssertEqual(doc.repos[known.id]?.tracked, false, "a repository the person untracked stays untracked")
        XCTAssertEqual(doc.repos[known.id]?.hidden, true)
        XCTAssertEqual(doc.repos[fresh.id]?.tracked, true)
    }

    func testCloneWhoseConfigRunsCommandsIsNotTrackedUnlessTrusted() throws {
        let manager = RepoManager(store: store)
        let key = RepoKey(provider: .gitHub, owner: "owner-a", name: "risky")
        let risky = DiscoveredCheckout(path: "/tmp/risky", remoteUrl: nil, key: key, commandConfig: ["core.fsmonitor"])
        let results = try manager.register([risky], track: true)
        XCTAssertEqual(results.map(\.action), [.needsReview])
        XCTAssertEqual(try store.load().repos[key.id]?.tracked, false)
        try manager.register([risky], track: true, trustCommandConfig: true)
        XCTAssertEqual(try store.load().repos[key.id]?.tracked, true)
    }

    func testTrackFoldersHoldsRiskyClonesForReview() async throws {
        let manager = RepoManager(store: store)
        let code = directory.appendingPathComponent("code")
        for (name, extra) in [("plain", ""), ("risky", "[filter \"x\"]\n\tclean = run-me\n")] {
            let git = code.appendingPathComponent("\(name)/.git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try "[remote \"origin\"]\n\turl = https://github.com/owner-a/\(name).git\n\(extra)"
                .write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        let (results, review) = try await manager.trackFolders([code.path])
        XCTAssertEqual(results.compactMap(\.displayName), ["owner-a/plain"])
        XCTAssertEqual(review.compactMap { $0.key?.name }, ["risky"])
        let doc = try store.load()
        XCTAssertEqual(doc.trackedEntries.map(\.key.name), ["plain"])
        XCTAssertNil(doc.repos["github:owner-a/risky"], "held clones are not registered")
        XCTAssertTrue(doc.settings.rootsChosen)
        let offered = try await manager.newClones()
        XCTAssertEqual(offered?.compactMap { $0.key?.name }, ["risky"], "and are offered for review")
    }

    func testSetHidden() throws {
        let manager = RepoManager(store: store)
        let key = RepoKey(provider: .gitHub, owner: "owner-a", name: "one")
        try store.update { $0.repos[key.id] = RepoRegistryEntry(key: key, path: "/tmp/one", tracked: true) }
        XCTAssertTrue(try manager.setHidden("owner-a/one", true).isHidden)
        XCTAssertTrue(try manager.records().first!.isTracked)
        XCTAssertFalse(try manager.setHidden("owner-a/one", false).isHidden)
    }

    func testNewClonesAreOfferedNotTracked() async throws {
        let manager = RepoManager(store: store)
        let code = directory.appendingPathComponent("code")
        for (name, url) in [("one", "https://github.com/owner-a/one.git"), ("two", "https://github.com/owner-a/two.git")] {
            let git = code.appendingPathComponent("\(name)/.git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try "[remote \"origin\"]\n\turl = \(url)\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        try manager.updateSettings { $0.scanRoots = [code.path] }
        let before = try await manager.newClones()
        XCTAssertNil(before, "nothing is looked for until the roots are chosen")

        try manager.addScanRoots([code.path])
        let offered = try await manager.newClones()
        XCTAssertEqual(offered?.compactMap { $0.key?.name }.sorted(), ["one", "two"])
        XCTAssertTrue(try store.load().repos.isEmpty, "offering registers nothing")

        try manager.register([offered![0]], track: true)
        try manager.ignore([offered![1]])
        let again = try await manager.newClones()
        XCTAssertEqual(again?.count, 0)
        XCTAssertEqual(try store.load().trackedEntries.count, 1)

        try manager.updateSettings { $0.autoTrackNewClones = false }
        let off = try await manager.newClones()
        XCTAssertNil(off)
    }
}

/// The checks that guard Delete Local Clone, against real repositories with a
/// local bare repository as their remote.
final class CloneRemovalCheckTests: XCTestCase {

    private var base: URL!
    private var clone: GitWorkingCopy!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("clone-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let remote = base.appendingPathComponent("remote.git").path
        let path = base.appendingPathComponent("work/clone").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await run(["init", "-q", "--bare", "-b", "main", remote])
        clone = GitWorkingCopy(path: path)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "dev@example.com"], ["config", "user.name", "Dev"],
                     ["config", "commit.gpgsign", "false"], ["remote", "add", "origin", remote]] {
            try await git(args)
        }
        try write("readme.txt", "one\n")
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "Initial"])
        try await git(["push", "-q", "origin", "main"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func run(_ args: [String]) async throws {
        let result = await GitWorkingCopy.runGit(args)
        XCTAssertTrue(result.succeeded, result.stderr)
    }

    private func git(_ args: [String]) async throws {
        let result = await clone.git(args)
        XCTAssertTrue(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
    }

    private func write(_ name: String, _ text: String) throws {
        try clone.writeFile(name, contents: Data(text.utf8))
    }

    func testPushedCleanCloneIsSafe() async {
        let check = await CloneRemovalCheck.inspect(path: clone.path)
        XCTAssertTrue(check.isSafe, check.lossDescription.joined(separator: "\n"))
        XCTAssertTrue(check.lossDescription.isEmpty)
    }

    func testUncommittedAndUntrackedFilesAreReported() async throws {
        try write("readme.txt", "changed\n")
        try write("notes.txt", "new\n")
        let check = await CloneRemovalCheck.inspect(path: clone.path)
        XCTAssertFalse(check.isSafe)
        XCTAssertEqual(Set(check.uncommitted), ["readme.txt", "notes.txt"])
        XCTAssertTrue(check.lossDescription[0].hasPrefix("2 uncommitted files"))
    }

    func testIgnoredFilesDoNotCount() async throws {
        try write(".gitignore", "*.log\n")
        try await git(["add", ".gitignore"])
        try await git(["commit", "-q", "-m", "Ignore logs"])
        try await git(["push", "-q", "origin", "main"])
        try write("debug.log", "noise\n")
        let check = await CloneRemovalCheck.inspect(path: clone.path)
        XCTAssertTrue(check.isSafe, check.lossDescription.joined(separator: "\n"))
    }

    func testUnpushedCommitsAreReportedWithTheirBranch() async throws {
        try await git(["switch", "-q", "-c", "feature/local"])
        try write("feature.txt", "work\n")
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "Local work"])
        let check = await CloneRemovalCheck.inspect(path: clone.path)
        XCTAssertFalse(check.isSafe)
        XCTAssertEqual(check.unpushedCount, 1)
        XCTAssertEqual(check.unpushedBranches, ["feature/local"])
        XCTAssertEqual(check.unpushedSample.count, 1)
        XCTAssertTrue(check.unpushedSample[0].hasSuffix("Local work"))
        XCTAssertTrue(check.lossDescription.contains("1 commit not pushed to any remote on feature/local"))
    }

    func testStashesAreReported() async throws {
        try write("readme.txt", "stashed\n")
        try await git(["stash", "-q"])
        let check = await CloneRemovalCheck.inspect(path: clone.path)
        XCTAssertTrue(check.uncommitted.isEmpty)
        XCTAssertEqual(check.stashes.count, 1)
        XCTAssertFalse(check.isSafe)
        XCTAssertTrue(check.lossDescription[0].hasPrefix("1 stash"))
    }

    func testOtherWorktreesAreReported() async throws {
        let extra = base.appendingPathComponent("work/clone-feature").path
        try await git(["worktree", "add", "-q", "-b", "feature/wt", extra])
        let check = await CloneRemovalCheck.inspect(path: clone.path)
        XCTAssertEqual(check.worktrees.count, 1)
        XCTAssertTrue(check.worktrees[0].hasSuffix("clone-feature"))
        XCTAssertFalse(check.isSafe)
    }

    func testRemoveCloneRefusesWithoutForceThenTrashesAndUntracks() async throws {
        let store = RepoRegistryStore(registryPath: base.appendingPathComponent("repos.json").path,
                                      catalogPath: base.appendingPathComponent("repos-catalog.json").path)
        let manager = RepoManager(store: store)
        let key = RepoKey(provider: .other, owner: "example.invalid", name: "clone")
        try store.update { $0.repos[key.id] = RepoRegistryEntry(key: key, path: self.clone.path, tracked: true) }
        try write("unsaved.txt", "draft\n")

        do {
            try await manager.removeClone(key.id)
            XCTFail("a clone with uncommitted work must not be removed without force")
        } catch let RepoError.wouldLoseWork(_, losses) {
            XCTAssertTrue(losses[0].contains("unsaved.txt"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))
        XCTAssertNotNil(try store.load().repos[key.id])

        try await manager.removeClone(key.id, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path))
        XCTAssertNil(try store.load().repos[key.id])
    }

    func testUnsafeTargetsAreRefused() throws {
        var settings = RepoSettings.default
        settings.scanRoots = [base.appendingPathComponent("work").path]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertThrowsError(try RepoManager.refuseUnsafeTarget(home, settings: settings))
        XCTAssertThrowsError(try RepoManager.refuseUnsafeTarget("/", settings: settings))
        XCTAssertThrowsError(try RepoManager.refuseUnsafeTarget(base.appendingPathComponent("work").path, settings: settings))
        XCTAssertThrowsError(try RepoManager.refuseUnsafeTarget(base.path, settings: settings), "not a checkout")
        XCTAssertNoThrow(try RepoManager.refuseUnsafeTarget(clone.path, settings: settings))
    }
}
