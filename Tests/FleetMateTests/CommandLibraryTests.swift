import XCTest
@testable import FleetMateCore

final class CommandLibraryTests: XCTestCase {

    static let sample = """
    categories:
      - name: System
        commands:
          - label: Hostname
            command: hostname
            trust: safe
          - label: Hardware info
            command: 'H=$(system_profiler SPHardwareDataType); printf ''%s\\n'' "$H" | grep ''Model Name'''
            trust: safe
          - label: No trust stated
            command: sudo shutdown -r now
      - name: Users & Sessions
        commands:
          - label: Set password
            command: sudo sysadminctl -resetPasswordFor <USERNAME> -newPassword <PASSWORD>
            trust: caution
    """

    func testParseReadsLabelsCommandsAndTrust() throws {
        let categories = try CommandLibrary.parse(Self.sample)
        XCTAssertEqual(categories.map(\.name), ["System", "Users & Sessions"])
        let system = categories[0]
        XCTAssertEqual(system.commands.count, 3)
        XCTAssertEqual(system.commands[0].label, "Hostname")
        XCTAssertEqual(system.commands[0].trustLevel, .safe)
        XCTAssertTrue(system.commands[0].trustWasStated)
        XCTAssertEqual(system.commands[1].command, "H=$(system_profiler SPHardwareDataType); printf '%s\\n' \"$H\" | grep 'Model Name'")
    }

    func testMissingTrustIsInferred() throws {
        let categories = try CommandLibrary.parse(Self.sample)
        let cmd = categories[0].commands[2]
        XCTAssertFalse(cmd.trustWasStated)
        XCTAssertEqual(cmd.trustLevel, .destructive)
    }

    func testSerializeRoundTripsAndStatesEveryTrust() throws {
        let categories = try CommandLibrary.parse(Self.sample)
        let yaml = try CommandLibrary.serialize(categories)
        XCTAssertTrue(yaml.hasPrefix("categories:"), yaml)
        XCTAssertTrue(yaml.contains("trust: destructive"), "inferred trust is written out")
        let again = try CommandLibrary.parse(yaml)
        XCTAssertEqual(again.map(\.name), categories.map(\.name))
        for (a, b) in zip(again.flatMap(\.commands), categories.flatMap(\.commands)) {
            XCTAssertEqual(a.label, b.label)
            XCTAssertEqual(a.command, b.command)
            XCTAssertEqual(a.trustLevel, b.trustLevel)
            XCTAssertTrue(a.trustWasStated)
        }
        // Keys keep their authoring order, so diffs of the operator's file stay readable.
        let nameIndex = try XCTUnwrap(yaml.range(of: "name:")).lowerBound
        let commandsIndex = try XCTUnwrap(yaml.range(of: "commands:")).lowerBound
        XCTAssertLessThan(nameIndex, commandsIndex)
    }

    func testSerializeQuotesAwkwardStrings() throws {
        let tricky = [CommandCategory(name: "Odd: things", commands: [
            ManageCommand(label: "Colon: label", command: "echo 'it''s' \"#not a comment\" | awk '{print $1}'", trustLevel: .safe),
            ManageCommand(label: "Multi", command: "line one\nline two", trustLevel: .safe),
        ])]
        let yaml = try CommandLibrary.serialize(tricky)
        let back = try CommandLibrary.parse(yaml)
        XCTAssertEqual(back[0].name, "Odd: things")
        XCTAssertEqual(back[0].commands[0].command, tricky[0].commands[0].command)
        XCTAssertEqual(back[0].commands[1].command, "line one\nline two")
    }

    func testMergeMissingAddsWithoutTouchingEdits() throws {
        var mine = try CommandLibrary.parse("""
        categories:
          - name: system
            commands:
              - label: hostname
                command: hostname -f
                trust: safe
        """)
        let bundled = [
            CommandCategory(name: "System", commands: [
                ManageCommand(label: "Hostname", command: "hostname", trustLevel: .safe),
                ManageCommand(label: "Uptime", command: "uptime", trustLevel: .safe),
            ]),
            CommandCategory(name: "Power", commands: [
                ManageCommand(label: "Sleep", command: "sudo pmset sleepnow", trustLevel: .destructive),
            ]),
        ]
        XCTAssertTrue(CommandLibrary.mergeMissing(into: &mine, bundled: bundled))
        XCTAssertEqual(mine.map(\.name), ["system", "Power"])
        XCTAssertEqual(mine[0].commands.map(\.label), ["hostname", "Uptime"])
        XCTAssertEqual(mine[0].commands[0].command, "hostname -f", "operator's edit kept")
        XCTAssertFalse(CommandLibrary.mergeMissing(into: &mine, bundled: bundled), "second merge is a no-op")
    }

    func testAuditFindsStructuralAndTrustProblems() throws {
        let categories = [
            CommandCategory(name: "System", commands: [
                ManageCommand(label: "Hostname", command: "hostname", trustLevel: .safe),
                ManageCommand(label: "hostname", command: "hostname", trustLevel: .safe),
                ManageCommand(label: "Empty", command: "  ", trustLevel: .safe),
                ManageCommand(label: "Understated", command: "sudo rm -rf /Library/Caches/foo", trustLevel: .safe),
                ManageCommand(label: "Unstated", command: "uptime"),
                ManageCommand(label: "Bare password", command: "cmd -p <PASSWORD>", trustLevel: .caution),
            ]),
            CommandCategory(name: "system", commands: []),
        ]
        let issues = CommandLibrary.audit(categories)
        let messages = issues.map(\.description)
        XCTAssertTrue(messages.contains { $0.contains("duplicate category name") }, messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains { $0.contains("duplicate label") })
        XCTAssertTrue(messages.contains { $0.contains("empty command") })
        XCTAssertTrue(messages.contains { $0.contains("stated as safe but the command reads as destructive") })
        XCTAssertTrue(messages.contains { $0.contains("trust level not stated") })
        XCTAssertTrue(messages.contains { $0.contains("category has no commands") })
        XCTAssertTrue(messages.contains { $0.contains("<PASSWORD> is bare") })
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 3)
    }

    func testMalformedYamlThrowsAndEmptyIsEmpty() {
        XCTAssertThrowsError(try CommandLibrary.parse("categories: [unclosed"))
        XCTAssertEqual(try CommandLibrary.parse("").count, 0)
        XCTAssertEqual(try CommandLibrary.parse("# nothing here\n").count, 0)
    }

    func testFindByLabelIsCaseInsensitive() throws {
        let categories = try CommandLibrary.parse(Self.sample)
        XCTAssertEqual(CommandLibrary.find(label: "HOSTNAME", in: categories)?.command, "hostname")
        XCTAssertNil(CommandLibrary.find(label: "nope", in: categories))
    }
}

/// The library that ships inside FleetMate must parse, audit clean, and
/// state every trust level, so the app never shows an inferred badge for
/// a bundled command.
final class BundledLibraryTests: XCTestCase {

    func testBundledLibraryParsesWithTheExpectedShape() throws {
        let categories = try CommandLibrary.parse(BundledCommandLibrary.yaml)
        XCTAssertEqual(categories.count, 15, categories.map(\.name).joined(separator: ", "))
        let commandCount = categories.reduce(0) { $0 + $1.commands.count }
        XCTAssertGreaterThanOrEqual(commandCount, 150)
        XCTAssertEqual(categories.map(\.name), [
            "System", "Storage", "Munki Config", "Munki Operations", "macOS Updates",
            "MDM & Enrollment", "Security & Profiles", "Users & Sessions", "Network",
            "Printing", "Diagnostics", "Logs", "Power", "Adobe", "Outset",
        ])
    }

    func testBundledLibraryStatesEveryTrustLevel() throws {
        let categories = try CommandLibrary.parse(BundledCommandLibrary.yaml)
        let unstated = categories.flatMap { cat in cat.commands.filter { !$0.trustWasStated }.map { "\(cat.name) / \($0.label)" } }
        XCTAssertEqual(unstated, [])
    }

    func testBundledLibraryAuditsClean() throws {
        let categories = try CommandLibrary.parse(BundledCommandLibrary.yaml)
        let issues = CommandLibrary.audit(categories).filter { $0.severity >= .warning }
        XCTAssertEqual(issues.map(\.description), [])
    }

    func testBundledLibraryNeverStatesWeakerTrustThanInferred() throws {
        let categories = try CommandLibrary.parse(BundledCommandLibrary.yaml)
        let understated = categories.flatMap { cat in
            cat.commands.filter(\.trustIsUnderstated).map { "\(cat.name) / \($0.label): \($0.trustLevel.rawValue) < \($0.inferredTrust.rawValue)" }
        }
        XCTAssertEqual(understated, [])
    }

    func testLoadBundledFallsBackWhenTheEmbeddedYamlIsBroken() {
        XCTAssertFalse(CommandLibrary.loadBundled().isEmpty)
        XCTAssertFalse(CommandLibrary.defaultCategories().isEmpty)
    }
}
