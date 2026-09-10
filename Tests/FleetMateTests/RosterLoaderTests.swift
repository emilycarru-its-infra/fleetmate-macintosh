import XCTest
@testable import FleetMateCore

final class RosterLoaderTests: XCTestCase {

    /// The current roster shape: twelve columns, allocation is the friendly name.
    static let currentShape = """
    serial,catalog,area,location,asset,usage,status,allocation,username,platform,fleet,hostname
    C02AAA,Curriculum,Foundation,B1122,A001,Shared,Active,B1122-01,,Macintosh,Foundation Studio,B1122-01
    C02AAB,Curriculum,Foundation,B1122,A002,Shared,Active,B1122-02,,Macintosh,Foundation Studio,B1122-02
    C02AAC,Curriculum,Illustration,D2210,A003,Shared,Active,D2210-01,,Macintosh,,D2210-01
    C02AAD,Curriculum,Podium,B1122,A004,Shared,Active,B1122-Podium,,Macintosh,Podiums and Smart Rooms,B1122-POD
    C02KIO,Kiosk,Library,L100,A005,Shared,Active,Library Kiosk 1,,Macintosh,Library Public Computers,LIB-KIOSK-1
    C02STF,Staff,IT,,A006,Assigned,Active (Legacy),Ada Byron,abyron,Macintosh,,AdaByron
    C02STG,Staff,Library,,A007,Assigned,Active,Grace Hopper,ghopper,Macintosh,,GraceHopper
    C02FAC,Faculty,Instructor,,A008,Assigned,Active,"Turing, Alan",aturing,Macintosh,Faculty Laptop Program,AlanTuringLaptop
    C02FAD,Faculty,Instructor,,A009,Assigned,Active,Edith Clarke,eclarke,Macintosh,Faculty Laptop Program,
    C02OLD,Staff,IT,,A010,Assigned,Returned Lease End,Old Mac,,Macintosh,,OldMac
    C02PRV,Provisioning,Unallocated,,A011,Assigned,Purchased,Mary Jackson,,Macintosh,,
    """

    /// The older shape ScanLab read: eleven columns, allocation is the hostname.
    static let legacyShape = """
    serial,catalog,area,location,asset,usage,status,allocation,username,platform,fleet
    C02AAA,Curriculum,Foundation,B1122,A001,Shared,Active,B1122-01,,Macintosh,Foundation Studio
    C02STF,Staff,IT,,A006,Assigned,Active,AdaByron,abyron,Macintosh,
    """

    func testCurrentShapePrefersHostnameColumn() throws {
        let roster = try RosterLoader().load(csv: Self.currentShape)
        let staff = roster.staff.flatMap(\.computers)
        let pei = try XCTUnwrap(staff.first { $0.serial == "C02STF" })
        XCTAssertEqual(pei.hostname, "AdaByron")
        XCTAssertEqual(pei.allocation, "Ada Byron")
        XCTAssertEqual(pei.friendlyName, "Ada Byron")
        XCTAssertEqual(pei.displayName, "AdaByron")
        XCTAssertEqual(pei.localHostname, "AdaByron.local")
    }

    func testLegacyShapeFallsBackToAllocation() throws {
        let roster = try RosterLoader().load(csv: Self.legacyShape)
        let pei = try XCTUnwrap(roster.staff.flatMap(\.computers).first { $0.serial == "C02STF" })
        XCTAssertEqual(pei.hostname, "AdaByron")
        XCTAssertEqual(roster.labs.first?.number, "Foundation Studio")
    }

    func testLabsGroupByFleetWithLocationFallbackAndPodiumsExcluded() throws {
        let roster = try RosterLoader().load(csv: Self.currentShape)
        XCTAssertEqual(roster.labs.map(\.number), ["Foundation Studio", "D2210"])
        XCTAssertEqual(roster.labs[0].computers.count, 2)
        XCTAssertEqual(roster.labs[0].displayName, "Foundation")
        XCTAssertEqual(roster.labs[0].name, "Foundation Studio · Foundation")
        XCTAssertFalse(roster.allComputers.contains { $0.serial == "C02AAD" }, "podiums are not lab seats")
    }

    func testKiosksStaffAndFacultySections() throws {
        let roster = try RosterLoader().load(csv: Self.currentShape)
        XCTAssertEqual(roster.kiosks.map(\.number), ["L100"])
        XCTAssertEqual(roster.staff.map(\.number), ["IT", "Library"])
        XCTAssertEqual(roster.faculty.map(\.number), ["E", "T"])
        let m = try XCTUnwrap(roster.faculty.first { $0.number == "T" })
        XCTAssertEqual(m.computers.first?.allocation, "Turing, Alan", "quoted field with a comma survives")
    }

    func testRetiredRowsAreDroppedUnlessAsked() throws {
        let roster = try RosterLoader().load(csv: Self.currentShape)
        XCTAssertFalse(roster.allComputers.contains { $0.serial == "C02OLD" })
        XCTAssertFalse(roster.allComputers.contains { $0.serial == "C02PRV" })

        let withRetired = try RosterLoader(includeRetired: true).load(csv: Self.currentShape)
        XCTAssertTrue(withRetired.allComputers.contains { $0.serial == "C02OLD" })

        let withProvisioning = try RosterLoader(includeRetired: true, includeProvisioning: true).load(csv: Self.currentShape)
        XCTAssertTrue(withProvisioning.labs.contains { $0.computers.contains { $0.serial == "C02PRV" } })
    }

    func testActiveVariantsCountAsInService() {
        for status in ["Active", "Active (Legacy)", "Active (Buyouts)", "Active (Lease End)", " active"] {
            XCTAssertTrue(RosterComputer(serial: "x", status: status).isInService, status)
        }
        for status in ["Returned Lease End", "Donated", "Purchased", "Missing", ""] {
            XCTAssertFalse(RosterComputer(serial: "x", status: status).isInService, status)
        }
    }

    func testMachinesWithoutHostnameStayInTheirRoomButNotInSearch() throws {
        let roster = try RosterLoader().load(csv: Self.currentShape)
        let ghislaine = try XCTUnwrap(roster.faculty.flatMap(\.computers).first { $0.serial == "C02FAD" })
        XCTAssertFalse(ghislaine.hasHostname)
        XCTAssertEqual(ghislaine.displayName, "Edith Clarke")
        XCTAssertFalse(roster.sourceComputers.contains { $0.serial == "C02FAD" })
        XCTAssertTrue(roster.sourceComputers.contains { $0.serial == "C02FAC" })
    }

    func testMissingRequiredHeaderThrows() {
        XCTAssertThrowsError(try RosterLoader().load(csv: "foo,bar\n1,2\n"))
    }

    func testCsvReaderHandlesQuotesNewlinesAndCrlf() {
        let text = "a,b\r\n\"x, y\",\"he said \"\"hi\"\"\"\r\n\"multi\nline\",z\n"
        let records = CSVReader.records(text)
        XCTAssertEqual(records, [["a", "b"], ["x, y", "he said \"hi\""], ["multi\nline", "z"]])
    }

    func testAdhocAndInventoryLine() {
        let adhoc = RosterComputer.adhoc(hostname: "", ip: "10.15.1.9")
        XCTAssertTrue(adhoc.isAdhoc)
        XCTAssertEqual(adhoc.displayName, "10.15.1.9")
        XCTAssertEqual(adhoc.inventoryLine(ip: "10.15.1.9"), "10.15.1.9  10.15.1.9")

        let c = RosterComputer(serial: "C02AAA", location: "B1122", asset: "A001", hostname: "B1122-01")
        XCTAssertEqual(c.inventoryLine(ip: "10.15.2.50", osVersion: "15.6"), "B1122-01  10.15.2.50  C02AAA  A001  B1122  15.6")
    }

    /// The real roster, when it is on this machine: every in-service row
    /// with a hostname must land in a section or be explicitly outside them.
    func testRealRosterLoadsWhenPresent() throws {
        let path = NSString(string: "~/Developer/AzDevOps/Devices/Munki/deployment/enroll/computers.csv").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "roster not on this machine")
        let roster = try RosterLoader().load(path: path)
        XCTAssertFalse(roster.labs.isEmpty)
        XCTAssertFalse(roster.staff.isEmpty)
        XCTAssertFalse(roster.faculty.isEmpty)
        for c in roster.allComputers where c.hasHostname {
            XCTAssertFalse(c.hostname.contains(" "), "hostname with a space: \(c.hostname) (\(c.serial))")
        }
    }
}
