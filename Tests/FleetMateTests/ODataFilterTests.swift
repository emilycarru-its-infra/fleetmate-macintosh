import XCTest
@testable import FleetMateCore

final class ODataFilterTests: XCTestCase {

    // MARK: - Escaping

    func testLiteralDoublesSingleQuotes() {
        XCTAssertEqual(ODataFilter.literal("SERIAL1"), "'SERIAL1'")
        XCTAssertEqual(ODataFilter.literal("O'Brien"), "'O''Brien'")
        XCTAssertEqual(ODataFilter.literal("''"), "''''''")
    }

    func testInjectionStaysInsideTheLiteral() {
        let filter = ODataFilter.equals("serialNumber", "x' or true or serialNumber eq '")
        XCTAssertEqual(filter, "serialNumber eq 'x'' or true or serialNumber eq '''")
        // Every quote the input contributed is doubled, so the expression still
        // has exactly one opening and one closing literal quote.
        let body = filter.dropFirst("serialNumber eq '".count).dropLast()
        XCTAssertFalse(body.replacingOccurrences(of: "''", with: "").contains("'"))
    }

    func testEncodeKeepsOnlyUnreservedCharacters() {
        let encoded = ODataFilter.encode("serialNumber eq 'a&$top=999#x+y'")
        for reserved in ["&", "=", "#", "+", "'", " ", "$"] {
            XCTAssertFalse(encoded.contains(reserved), "\(reserved) must be percent-encoded")
        }
        XCTAssertEqual(encoded.removingPercentEncoding, "serialNumber eq 'a&$top=999#x+y'")
    }

    // MARK: - Validation

    func testSerialValidation() throws {
        XCTAssertEqual(try DeviceIdentifier.validateSerial(" SERIAL1 "), "SERIAL1")
        XCTAssertEqual(try DeviceIdentifier.validateSerial("TEST-0001"), "TEST-0001")
        for bad in ["", "ab cd", "x'y", "a&b", "-confirm", "abc-", "a--b", String(repeating: "A", count: 65)] {
            XCTAssertThrowsError(try DeviceIdentifier.validateSerial(bad), "\(bad) should be refused")
        }
    }

    func testGuidValidation() throws {
        XCTAssertEqual(try DeviceIdentifier.validateGuid("A1B2C3D4-0000-1111-2222-333344445555"),
                       "a1b2c3d4-0000-1111-2222-333344445555")
        for bad in ["a1b2c3d4", "a1b2c3d4-0000-1111-2222-33334444555g", "{a1b2c3d4-0000-1111-2222-333344445555}", "' or 1 eq 1"] {
            XCTAssertThrowsError(try DeviceIdentifier.validateGuid(bad), "\(bad) should be refused")
        }
    }

    func testParseDistinguishesGuidFromSerial() throws {
        XCTAssertEqual(try DeviceIdentifier.parse("a1b2c3d4-0000-1111-2222-333344445555"),
                       .guid("a1b2c3d4-0000-1111-2222-333344445555"))
        XCTAssertEqual(try DeviceIdentifier.parse("SERIAL1"), .serial("SERIAL1"))
        XCTAssertThrowsError(try DeviceIdentifier.parse("LAB PC 01'"))
    }

    // MARK: - Exact resolution

    private func device(_ id: String, serial: String?) throws -> IntuneDevice {
        let s = serial.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(IntuneDevice.self, from: Data(#"{"id":"\#(id)","serialNumber":\#(s),"deviceName":"PC-\#(id)"}"#.utf8))
    }

    func testResolveNone() throws {
        let match = ExactMatch.resolve([try device("1", serial: "TEST0001X")], matching: "TEST0001") { $0.serialNumber }
        guard case .none = match else { return XCTFail("a partial match must not count") }
        XCTAssertNil(match.single)
    }

    func testResolveOneIsCaseInsensitive() throws {
        let candidates = [try device("1", serial: "test0001"), try device("2", serial: "TEST0001X"), try device("3", serial: nil)]
        let match = ExactMatch.resolve(candidates, matching: "TEST0001") { $0.serialNumber }
        XCTAssertEqual(match.single?.id, "1")
    }

    func testResolveManyIsRefused() throws {
        let candidates = [try device("1", serial: "TEST0001"), try device("2", serial: "TEST0001")]
        let match = ExactMatch.resolve(candidates, matching: "TEST0001") { $0.serialNumber }
        guard case .many(let all) = match else { return XCTFail("duplicates must be refused") }
        XCTAssertEqual(all.map(\.id).sorted(), ["1", "2"])
        XCTAssertNil(match.single)
    }

    func testRecordStateWithRefusalCannotAct() {
        var state = DeviceRecordState(serial: "TEST0001")
        XCTAssertTrue(state.canAct)
        state.refusal = "2 Intune records have serial TEST0001; refusing to choose one."
        XCTAssertFalse(state.canAct)
        state.refusal = nil
        state.lookupFailed = true
        XCTAssertFalse(state.canAct)
    }
}
