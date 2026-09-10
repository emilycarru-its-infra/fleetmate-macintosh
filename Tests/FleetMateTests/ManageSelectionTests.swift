import XCTest
@testable import FleetMateCore

final class ManageSelectionTests: XCTestCase {
    let roster: FleetRoster = {
        let lab1 = RosterRoom(number: "Foundation Studio", displayName: "Foundation", computers: [
            RosterComputer(serial: "S1", hostname: "FS-01"), RosterComputer(serial: "S2", hostname: "FS-02"),
        ])
        let lab2 = RosterRoom(number: "D2210", computers: [RosterComputer(serial: "S3", hostname: "D2210-01")])
        let staff = RosterRoom(number: "IT", computers: [RosterComputer(serial: "S4", allocation: "Ada Byron", username: "abyron", hostname: "AdaByron")])
        return FleetRoster(labs: [lab1, lab2], staff: [staff], sourceComputers: [])
    }()

    let groups: [CustomGroup] = [
        CustomGroup(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Loaners", devices: [
            AdhocDevice(hostname: "loaner-1", ip: "10.15.9.1"),
            AdhocDevice(hostname: "", ip: "10.15.9.2"),
        ]),
    ]

    func testClickReplacesAndCommandClickExtends() {
        var sel = ManageSelection()
        sel.selectRoom("Foundation Studio", extending: false)
        XCTAssertEqual(sel.currentComputers(roster: roster, groups: groups).map(\.serial), ["S1", "S2"])
        XCTAssertEqual(sel.primaryRoom(in: roster)?.number, "Foundation Studio")
        XCTAssertEqual(sel.label(roster: roster, groups: groups), "Foundation Studio · Foundation")

        sel.selectRoom("D2210", extending: true)
        XCTAssertEqual(sel.currentComputers(roster: roster, groups: groups).map(\.serial), ["S1", "S2", "S3"])
        XCTAssertNil(sel.primaryRoom(in: roster))
        XCTAssertEqual(sel.label(roster: roster, groups: groups), "2 groups")

        sel.selectRoom("D2210", extending: true)
        XCTAssertEqual(sel.roomIDs, ["Foundation Studio"])

        sel.selectRoom("IT", extending: false)
        XCTAssertEqual(sel.roomIDs, ["IT"])
    }

    func testGroupsCombineWithRoomsAndDedupe() {
        var sel = ManageSelection()
        sel.selectGroup(groups[0].id, extending: false)
        let computers = sel.currentComputers(roster: roster, groups: groups)
        XCTAssertEqual(computers.map(\.displayName), ["loaner-1", "10.15.9.2"])
        XCTAssertTrue(computers.allSatisfy(\.isAdhoc))
        XCTAssertEqual(sel.primaryGroup(in: groups)?.name, "Loaners")
        XCTAssertEqual(sel.knownAddresses(groups: groups), ["loaner-1": "10.15.9.1", "10.15.9.2": "10.15.9.2"])

        sel.selectRoom("D2210", extending: true)
        XCTAssertEqual(sel.currentComputers(roster: roster, groups: groups).count, 3)
        XCTAssertNil(sel.primaryGroup(in: groups))

        sel.addAdhoc(RosterComputer.adhoc(hostname: "loaner-1", ip: "10.15.9.1"))
        XCTAssertEqual(sel.currentComputers(roster: roster, groups: groups).count, 3, "same serial is not listed twice")
    }

    func testSearchReplacesEverything() {
        var sel = ManageSelection()
        sel.selectRoom("D2210", extending: false)
        let hits = RosterSearch.matches("fs-", in: roster)
        XCTAssertEqual(hits.map(\.serial), ["S1", "S2"])
        sel.selectSearchResults(hits, label: "fs-")
        XCTAssertTrue(sel.isSearch)
        XCTAssertTrue(sel.roomIDs.isEmpty)
        XCTAssertEqual(sel.label(roster: roster, groups: groups), "Search: fs-")
        XCTAssertEqual(sel.currentComputers(roster: roster, groups: groups).map(\.serial), ["S1", "S2"])

        sel.selectRoom("IT", extending: false)
        XCTAssertFalse(sel.isSearch)
        sel.clear()
        XCTAssertTrue(sel.isEmpty)
    }

    func testSearchMatchesFriendlyNameUsernameAndSerial() {
        XCTAssertEqual(RosterSearch.matches("byron", in: roster).map(\.serial), ["S4"])
        XCTAssertEqual(RosterSearch.matches("ABYRON", in: roster).map(\.serial), ["S4"])
        XCTAssertEqual(RosterSearch.matches("s3", in: roster).map(\.serial), ["S3"])
        XCTAssertEqual(RosterSearch.matches("   ", in: roster), [])
        XCTAssertEqual(RosterSearch.rooms("found", in: roster.labs).map(\.number), ["Foundation Studio"])
        XCTAssertEqual(RosterSearch.rooms("d2210-01", in: roster.labs).map(\.number), ["D2210"])
        XCTAssertEqual(RosterSearch.rooms("", in: roster.labs).count, 2)
    }

    func testRemovingADeletedGroupDropsItFromTheSelection() {
        var sel = ManageSelection()
        sel.selectGroup(groups[0].id, extending: false)
        sel.removeGroup(groups[0].id)
        XCTAssertTrue(sel.isEmpty)
    }
}

final class ManageConfigTests: XCTestCase {

    func testDefaultsResolve() {
        let c = ManageConfig()
        XCTAssertEqual(c.resolvedSshUser, "macadmins")
        XCTAssertTrue(c.resolvedSshKeyPath.hasSuffix("/.ssh/id_rsa.macadmins"))
        XCTAssertFalse(c.resolvedSshKeyPath.hasPrefix("~"))
        XCTAssertEqual(c.resolvedScreenSharingUser, "macadmins")
        XCTAssertTrue(c.resolvedCommandsPath.hasSuffix("/FleetMate/manage/commands.yaml"))
        XCTAssertEqual(c.resolvedRosterPath(repoRoot: nil), "")
        XCTAssertEqual(c.resolvedRosterPath(repoRoot: "/repo"), "/repo/deployment/enroll/computers.csv")
        XCTAssertFalse(c.hasRoster(repoRoot: "/nonexistent"))
        let ssh = c.toSecureShellConfig()
        XCTAssertEqual(ssh.defaultUsername, "macadmins")
        XCTAssertEqual(ssh.maxConcurrentConnections, 12)
        XCTAssertNil(ssh.privateKeyEnvVar, "the shared SSH env var must not override the Manage key")
    }

    func testExplicitValuesWin() {
        var c = ManageConfig()
        c.rosterPath = "~/roster.csv"
        c.sshUser = " ops "
        c.screenSharingUser = ""
        c.sshKeyPath = "/keys/lab"
        XCTAssertTrue(c.resolvedRosterPath(repoRoot: "/repo").hasSuffix("/roster.csv"))
        XCTAssertEqual(c.resolvedSshUser, "ops")
        XCTAssertEqual(c.resolvedScreenSharingUser, "ops")
        XCTAssertEqual(c.resolvedSshKeyPath, "/keys/lab")
    }

    func testYamlBlockAcceptsBothKeyStyles() {
        let snake: [String: Any] = ["enabled": true, "roster_path": "/a.csv", "ssh_user": "x", "include_retired": true, "probe_concurrency": 4]
        let c1 = ManageConfig.from(yaml: snake)
        XCTAssertTrue(c1.enabled)
        XCTAssertEqual(c1.rosterPath, "/a.csv")
        XCTAssertEqual(c1.sshUser, "x")
        XCTAssertTrue(c1.includeRetired)
        XCTAssertEqual(c1.probeConcurrency, 4)

        let camel: [String: Any] = ["rosterPath": "/b.csv", "terminalTheme": "Pro", "includeProvisioning": true]
        let c2 = ManageConfig.from(yaml: camel)
        XCTAssertEqual(c2.rosterPath, "/b.csv")
        XCTAssertEqual(c2.terminalTheme, "Pro")
        XCTAssertTrue(c2.includeProvisioning)
        XCTAssertFalse(c2.enabled)
    }

    func testCredentialsRoundTrip() {
        var c = ManageConfig()
        c.enabled = true
        c.rosterPath = "/r.csv"
        c.commandsPath = "/c.yaml"
        c.sshKeyPath = "/k"
        c.sshUser = "u"
        c.terminalTheme = "Ocean"
        c.screenSharingUser = "v"
        c.includeRetired = true
        c.includeProvisioning = true
        c.probeConcurrency = 5
        let values = c.credentialValues()
        XCTAssertEqual(values["manageEnabled"], "true")
        XCTAssertEqual(values["manageProbeConcurrency"], "5")
        let back = ManageConfig.applying(credentials: values, to: nil)
        XCTAssertEqual(back, c)

        XCTAssertNil(ManageConfig.applying(credentials: ["snipeUrl": "x"], to: nil), "unrelated keys do not create a block")
        var yamlBase = ManageConfig()
        yamlBase.rosterPath = "/from-yaml.csv"
        let merged = ManageConfig.applying(credentials: ["manageEnabled": "true"], to: yamlBase)
        XCTAssertEqual(merged?.rosterPath, "/from-yaml.csv", "file keys layer over the YAML block")
        XCTAssertEqual(merged?.enabled, true)
    }

    func testFleetMateConfigFlag() {
        var config = FleetMateConfig()
        XCTAssertFalse(config.isManageConfigured)
        var manage = ManageConfig()
        manage.enabled = true
        manage.rosterPath = "/definitely/missing.csv"
        config.manage = manage
        XCTAssertFalse(config.isManageConfigured, "enabled without a roster file is not configured")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roster-\(UUID().uuidString).csv")
        try? "serial,allocation\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        config.manage?.rosterPath = tmp.path
        XCTAssertTrue(config.isManageConfigured)
        config.manage?.enabled = false
        XCTAssertFalse(config.isManageConfigured)
    }
}
