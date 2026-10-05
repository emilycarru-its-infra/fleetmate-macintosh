import XCTest
@testable import FleetMateCore

final class DeviceRecordStateTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func entra(_ id: String, deviceId: String?, name: String = "LAB-01", trust: String = "AzureAd") throws -> EntraDevice {
        let device = deviceId.map { "\"\($0)\"" } ?? "null"
        return try decode(EntraDevice.self, #"{"id":"\#(id)","deviceId":\#(device),"displayName":"\#(name)","trustType":"\#(trust)"}"#)
    }

    func testOrphanedWhenEntraObjectsRemainWithoutIntune() throws {
        var state = DeviceRecordState(serial: "S1")
        XCTAssertFalse(state.isOrphaned)
        state.entraDevices = [try entra("o1", deviceId: "d1")]
        XCTAssertTrue(state.isOrphaned)
    }

    func testNoTwinsWhenNothingIsBound() throws {
        var state = DeviceRecordState(serial: "S1")
        state.entraDevices = [try entra("o1", deviceId: "d1"), try entra("o2", deviceId: "d2")]
        XCTAssertTrue(state.staleEntraTwins.isEmpty, "with no binding the live object cannot be told apart")
    }

    func testTwinsAreObjectsNotBoundToAutopilot() throws {
        var state = DeviceRecordState(serial: "S1")
        state.autopilot = try decode(WindowsAutopilotDevice.self, #"{"id":"ap1","serialNumber":"S1","azureActiveDirectoryDeviceId":"D1"}"#)
        state.entraDevices = [
            try entra("live", deviceId: "d1"),
            try entra("hybrid", deviceId: "d9", trust: "ServerAd"),
            try entra("nodevice", deviceId: nil),
        ]
        XCTAssertEqual(state.staleEntraTwins.compactMap(\.id).sorted(), ["hybrid", "nodevice"])
    }

    func testDanglingManagedDeviceId() throws {
        var state = DeviceRecordState(serial: "S1")
        state.autopilot = try decode(WindowsAutopilotDevice.self, #"{"id":"ap1","managedDeviceId":"m1"}"#)
        XCTAssertTrue(state.hasDanglingManagedDeviceId)

        state.autopilot = try decode(WindowsAutopilotDevice.self, #"{"id":"ap1","managedDeviceId":"00000000-0000-0000-0000-000000000000"}"#)
        XCTAssertFalse(state.hasDanglingManagedDeviceId, "the all-zero id means no managed device")
    }

    func testRecordStateRoundTripsAsJSON() throws {
        var state = DeviceRecordState(serial: "S1")
        state.lookupFailed = true
        state.lookupError = "denied"
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(DeviceRecordState.self, from: data)
        XCTAssertEqual(back.serial, "S1")
        XCTAssertTrue(back.lookupFailed)
        XCTAssertEqual(back.lookupError, "denied")
    }
}
