import Foundation
import XCTest
@testable import FleetMateCore

final class IntuneDeviceJailbrokenTests: XCTestCase {
    func testJailBrokenDecodesAsGraphReportsIt() throws {
        let json = #"{"id":"d1","deviceName":"Device","jailBroken":"False"}"#
        let device = try JSONDecoder().decode(IntuneDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.jailBroken, "False")
    }

    func testJailBrokenIsOptional() throws {
        let json = #"{"id":"d2","deviceName":"Device"}"#
        let device = try JSONDecoder().decode(IntuneDevice.self, from: Data(json.utf8))
        XCTAssertNil(device.jailBroken)
    }
}
